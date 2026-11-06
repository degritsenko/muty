import Foundation
import CryptoKit
import Combine

struct SavedCredential: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var username: String
    var password: String
    func validated() throws -> Self {
        var result = self
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.title.isEmpty, result.title.count <= 200 else { throw MutyError("Enter a credential name (up to 200 characters).") }
        var profile = SessionProfile(); profile.host = "validation.invalid"; profile.user = result.username
        _ = try profile.validated()
        try VaultStore.validatePassword(password)
        return result
    }
}
struct CredentialSummary: Identifiable {
    let id: UUID
    let title: String
    let username: String
}
struct VaultDocument: Codable, Equatable {
    var sessionPasswords: [String: String] = [:]
    var credentials: [SavedCredential] = []
    func validated() throws -> Self {
        guard sessionPasswords.count <= 10000, credentials.count <= 10000,
              Set(credentials.map(\.id)).count == credentials.count,
              Set(credentials.map { $0.title.lowercased() }).count == credentials.count else {
            throw MutyError("Invalid or duplicate password-vault records.")
        }
        guard Set(sessionPasswords.keys).isDisjoint(with: Set(credentials.map { $0.id.uuidString })) else { throw MutyError("Overlapping session and shared credential IDs.") }
        for (id, secret) in sessionPasswords {
            guard let uuid = UUID(uuidString: id), uuid.uuidString == id else { throw MutyError("Invalid session password ID.") }
            try VaultStore.validatePassword(secret)
        }
        for credential in credentials {
            guard try credential.validated() == credential else { throw MutyError("Non-canonical shared credential metadata.") }
        }
        return self
    }
}
private struct VaultEnvelope: Codable {
    var format = "muty.credentials"
    var version = 1
    var protected: Bool
    var salt: Data?
    var localKey: Data?
    var ciphertext: Data
}

// UI and SSH callbacks access this store on the main thread. No Keychain APIs are used.
final class VaultStore: ObservableObject, CredentialStore {
    static let shared = VaultStore()
    @Published private(set) var needsSetup = true
    @Published private(set) var isLocked = false
    @Published private(set) var isProtected = false
    @Published private(set) var loadError: String?
    @Published private(set) var credentials: [CredentialSummary] = []
    @Published private(set) var sessionPasswordCount = 0
    let file: URL
    private var envelope: VaultEnvelope?
    private var key: SymmetricKey?
    private var document: VaultDocument?
    private static func aad(_ protected: Bool) -> Data {
        Data("muty.credentials:1:\(protected ? "protected" : "automatic")".utf8)
    }
    init(directory: URL? = nil) {
        file = (directory ?? ProfileStore().directory).appendingPathComponent("password-vault.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let value = try JSONDecoder().decode(VaultEnvelope.self, from: BackupArchive.load(file))
            guard value.format == "muty.credentials", value.version == 1,
                  value.protected ? (value.localKey == nil && value.salt?.count == 16) : (value.localKey?.count == 32 && value.salt == nil) else {
                throw MutyError("Invalid password vault.")
            }
            envelope = value; needsSetup = false; isProtected = value.protected; isLocked = value.protected
            if !value.protected { try unlock(masterPassword: "") }
        } catch { loadError = error.localizedDescription; isLocked = true; needsSetup = false }
    }
    static func validatePassword(_ password: String) throws {
        guard !password.isEmpty, password.utf8.count <= 1023,
              !password.contains("\n"), !password.contains("\r"), !password.contains("\0") else {
            throw MutyError("Password must contain 1–1023 UTF-8 bytes without newline or NUL.")
        }
    }
    private func ready() throws -> VaultDocument {
        if let loadError { throw MutyError("Password vault is unavailable: " + loadError) }
        guard let document, key != nil else { throw MutyError(needsSetup ? "Set up password storage in Settings → Credentials." : "Unlock password storage first.") }
        return document
    }
    private func publish(_ value: VaultDocument) {
        document = value
        credentials = value.credentials.map { CredentialSummary(id: $0.id, title: $0.title, username: $0.username) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        sessionPasswordCount = value.sessionPasswords.count
    }
    func initialize(masterPassword: String?) throws {
        guard needsSetup, loadError == nil else { throw MutyError("Password storage is already configured or unavailable.") }
        try persist(VaultDocument(), masterPassword: masterPassword)
    }
    func unlock(masterPassword: String) throws {
        guard loadError == nil, let envelope else { throw MutyError("Password vault is unavailable.") }
        let candidate: SymmetricKey
        if envelope.protected {
            guard let salt = envelope.salt else { throw MutyError("Invalid vault salt.") }
            candidate = try BackupArchive.deriveKey(password: masterPassword, salt: salt)
        } else {
            guard let data = envelope.localKey else { throw MutyError("Invalid local vault key.") }
            candidate = SymmetricKey(data: data)
        }
        let plain: Data
        do { plain = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext), using: candidate, authenticating: Self.aad(envelope.protected)) }
        catch { throw MutyError("Wrong master password or damaged password vault.") }
        let value = try JSONDecoder().decode(VaultDocument.self, from: plain).validated()
        key = candidate; isLocked = false; publish(value)
    }
    func lock() {
        guard isProtected else { return }
        document = nil; key = nil; credentials = []; sessionPasswordCount = 0; isLocked = true
    }
    func changeProtection(masterPassword: String?) throws { try persist(ready(), masterPassword: masterPassword) }
    private func persist(_ value: VaultDocument, masterPassword: String?) throws {
        _ = try value.validated()
        let protected = masterPassword != nil
        let candidate: SymmetricKey
        let salt: Data?
        let localKey: Data?
        if let masterPassword {
            salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
            candidate = try BackupArchive.deriveKey(password: masterPassword, salt: salt!)
            localKey = nil
        } else {
            candidate = SymmetricKey(size: .bits256); salt = nil
            localKey = candidate.withUnsafeBytes { Data($0) }
        }
        let plain = try JSONEncoder().encode(value)
        let sealed = try AES.GCM.seal(plain, using: candidate, authenticating: Self.aad(protected))
        guard let ciphertext = sealed.combined else { throw MutyError("Could not encrypt password vault.") }
        let result = VaultEnvelope(protected: protected, salt: salt, localKey: localKey, ciphertext: ciphertext)
        try writeEnvelope(result)
        envelope = result; key = candidate; isProtected = protected; isLocked = false; needsSetup = false
        publish(value)
    }
    private func writeEnvelope(_ value: VaultEnvelope) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try BackupArchive.write(JSONEncoder().encode(value), to: file)
    }
    func snapshot() throws -> VaultDocument { try ready() }
    func replace(_ value: VaultDocument) throws {
        _ = try ready(); _ = try value.validated()
        guard let key, var updated = envelope else { throw MutyError("Unlock password storage first.") }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(value), using: key, authenticating: Self.aad(updated.protected))
        guard let data = sealed.combined else { throw MutyError("Could not encrypt password vault.") }
        updated.ciphertext = data
        try writeEnvelope(updated)
        envelope = updated; publish(value)
    }
    func credential(_ id: UUID) throws -> SavedCredential {
        guard let result = try ready().credentials.first(where: { $0.id == id }) else { throw MutyError("Shared credential was removed. Select another credential in Session Settings.") }
        return result
    }
    func saveCredential(_ value: SavedCredential) throws {
        let value = try value.validated(); var updated = try ready()
        updated.credentials.removeAll { $0.id == value.id }
        updated.credentials.append(value)
        try replace(updated)
    }
    func deleteCredential(_ id: UUID) throws {
        var updated = try ready(); updated.credentials.removeAll { $0.id == id }; try replace(updated)
    }
    func read(id: UUID) throws -> String? {
        if needsSetup { return nil }
        let value = try ready()
        return value.credentials.first { $0.id == id }?.password ?? value.sessionPasswords[id.uuidString]
    }
    func write(id: UUID, password: String) throws {
        try Self.validatePassword(password)
        var updated = try ready(); updated.sessionPasswords[id.uuidString] = password; try replace(updated)
    }
    func delete(id: UUID) throws {
        if needsSetup { return }
        var updated = try ready(); updated.sessionPasswords.removeValue(forKey: id.uuidString); try replace(updated)
    }
}
