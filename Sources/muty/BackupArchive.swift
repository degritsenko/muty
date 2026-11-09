import Foundation
import CryptoKit
import CommonCrypto
import Security
import Darwin

struct BackupPassword: Codable {
    let sessionID: UUID
    let password: String
}

struct FullBackup: Codable {
    var format = "muty.backup"
    var version = 2
    let configuration: ConfigurationBackup
    let passwords: [BackupPassword]
    var credentials: [SavedCredential]? = nil
}

private struct EncryptedBackup: Codable {
    var format = "muty.backup.encrypted"
    var version = 1
    var kdf = "PBKDF2-HMAC-SHA256"
    var iterations = 600_000
    let salt: Data
    let ciphertext: Data
}

struct LockedBackup: Identifiable {
    let id = UUID()
    let data: Data
    var sourcePath: String? = nil
}

enum BackupArchive {
    static let limit = 64_000_000
    private static let aad = Data("muty.backup.encrypted:1:PBKDF2-HMAC-SHA256:600000".utf8)

    static func load(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw MutyError("Backup exceeds 64 MB.") }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw MutyError("Backup exceeds 64 MB.") }
        return data
    }

    static func encrypted(_ data: Data) throws -> Bool {
        struct Header: Decodable { let format: String }
        return try JSONDecoder().decode(Header.self, from: data).format == "muty.backup.encrypted"
    }

    static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        guard !password.isEmpty, password.utf8.count <= 1024, salt.count == 16 else {
            throw MutyError("Invalid master password or backup salt.")
        }
        var output = Data(count: 32)
        let input = Data(password.utf8)
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { pass in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.bindMemory(to: Int8.self).baseAddress,
                        input.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000,
                        out.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard status == kCCSuccess else { throw MutyError("Could not derive backup encryption key.") }
        return SymmetricKey(data: output)
    }

    static func encode(_ backup: FullBackup, masterPassword: String?) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let plain = try encoder.encode(backup)
        guard plain.count <= limit else { throw MutyError("Backup exceeds 64 MB.") }
        guard let masterPassword else { return plain }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw MutyError("Could not generate backup salt.") }
        let sealed = try AES.GCM.seal(plain, using: deriveKey(password: masterPassword, salt: salt), authenticating: aad)
        guard let combined = sealed.combined else { throw MutyError("Could not encrypt backup.") }
        let data = try encoder.encode(EncryptedBackup(salt: salt, ciphertext: combined))
        guard data.count <= limit else { throw MutyError("Encrypted backup exceeds 64 MB.") }
        return data
    }

    static func decode(_ data: Data, masterPassword: String? = nil) throws -> ConfigurationBackup {
        guard data.count <= limit else { throw MutyError("Backup exceeds 64 MB.") }
        let decoder = JSONDecoder()
        struct Header: Decodable { let format: String }
        switch try decoder.decode(Header.self, from: data).format {
        case "muty.sessions":
            let configuration = try decoder.decode(ConfigurationBackup.self, from: data).validated()
            guard configuration.sessions.allSatisfy({ $0.credentialID == nil }) else { throw MutyError("Configuration-only import cannot contain shared password references.") }
            return configuration
        case "muty.backup.encrypted":
            let envelope = try decoder.decode(EncryptedBackup.self, from: data)
            guard envelope.version == 1, envelope.kdf == "PBKDF2-HMAC-SHA256", envelope.iterations == 600_000,
                  envelope.salt.count == 16, let masterPassword else {
                throw MutyError("Unsupported encrypted backup or missing master password.")
            }
            let plain: Data
            do {
                plain = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext),
                    using: deriveKey(password: masterPassword, salt: envelope.salt), authenticating: aad)
            } catch { throw MutyError("Wrong master password or damaged backup.") }
            // Encrypted payload must be a full backup, never another envelope.
            guard try decoder.decode(Header.self, from: plain).format == "muty.backup" else {
                throw MutyError("Invalid encrypted backup payload.")
            }
            return try decodeFull(plain)
        case "muty.backup": return try decodeFull(data)
        default: throw MutyError("Invalid or unsupported muty backup.")
        }
    }

    private static func decodeFull(_ data: Data) throws -> ConfigurationBackup {
        let backup = try JSONDecoder().decode(FullBackup.self, from: data)
        var configuration = try backup.configuration.validated()
        guard (backup.version == 1 || backup.version == 2), backup.passwords.count <= configuration.sessions.count,
              Set(backup.passwords.map(\.sessionID)).count == backup.passwords.count else {
            throw MutyError("Invalid backup password records.")
        }
        let credentials = backup.credentials ?? []
        guard credentials.count <= 10000, Set(credentials.map(\.id)).count == credentials.count,
              Set(credentials.map { $0.title.lowercased() }).count == credentials.count else { throw MutyError("Invalid shared credentials in backup.") }
        for credential in credentials { _ = try credential.validated() }
        for session in configuration.sessions {
            if let id = session.credentialID {
                guard let credential = credentials.first(where: { $0.id == id }),
                      session.authentication == .password, session.connectionType == .ssh,
                      session.user == credential.username else { throw MutyError("Missing or incompatible shared credential in backup.") }
            }
        }
        configuration.restoredCredentials = credentials
        for entry in backup.passwords {
            guard let session = configuration.sessions.first(where: { $0.id == entry.sessionID }),
                  session.connectionType == .ssh, session.authentication == .password, session.credentialID == nil,
                  !entry.password.isEmpty, entry.password.utf8.count <= 1023,
                  !entry.password.contains("\n"), !entry.password.contains("\r"), !entry.password.contains("\0") else {
                throw MutyError("Invalid backup password record.")
            }
            configuration.restoredPasswords[entry.sessionID] = entry.password
        }
        return configuration
    }

    static func write(_ data: Data, to url: URL) throws {
        // Create a private temporary file before writing any secret bytes.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".muty-backup-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MutyError("Could not create backup file.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
