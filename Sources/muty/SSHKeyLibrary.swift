import Foundation
import AppKit
import Darwin

struct SSHKeyRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var path: String
    var imported: Bool
    var fingerprint: String
    var pendingDeletion: Bool?
}

@MainActor
final class SSHKeyLibrary: ObservableObject {
    @Published private(set) var keys: [SSHKeyRecord] = []
    @Published private(set) var busy = false
    @Published private(set) var loadError: String?
    let directory: URL
    private var catalog: URL { directory.appendingPathComponent("keys.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? ProfileStore().directory.appendingPathComponent("SSHKeys", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: catalog.path) {
                keys = try JSONDecoder().decode([SSHKeyRecord].self, from: Data(contentsOf: catalog))
                guard Set(keys.map(\.id)).count == keys.count else { throw MutyError("Duplicate SSH key IDs.") }
            }
        } catch { loadError = "Cannot read key library. No changes will be saved. \(error.localizedDescription)" }
    }

    func path(for id: UUID) throws -> String {
        guard let key = keys.first(where: { $0.id == id }) else { throw MutyError("SSH key was removed. Select another key in Session Settings.") }
        guard key.pendingDeletion != true else { throw MutyError("Key deletion is pending. Retry Remove in Settings.") }
        let path = key.imported ? directory.appendingPathComponent(key.id.uuidString).path : key.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: path) else { throw MutyError("SSH key file is unavailable. Download cloud files locally or select another file.") }
        return path
    }

    @discardableResult
    func add(file: URL, copy: Bool) throws -> SSHKeyRecord {
        guard loadError == nil else { throw MutyError(loadError!) }
        guard !busy else { throw MutyError("Key import is in progress.") }
        return try register(Self.prepareKey(file: file, copy: copy, directory: directory))
    }

    func addAsync(file: URL, copy: Bool) async throws -> SSHKeyRecord {
        guard loadError == nil else { throw MutyError(loadError!) }
        guard !busy else { throw MutyError("Key import is in progress.") }
        busy = true
        defer { busy = false }
        let directory = self.directory
        let key = try await Task.detached(priority: .userInitiated) {
            try Self.prepareKey(file: file, copy: copy, directory: directory)
        }.value
        return try register(key)
    }

    private func register(_ key: SSHKeyRecord) throws -> SSHKeyRecord {
        do { try save(keys + [key]) }
        catch {
            if key.imported { try? FileManager.default.removeItem(at: directory.appendingPathComponent(key.id.uuidString)) }
            throw error
        }
        return key
    }

    nonisolated private static func prepareKey(file: URL, copy: Bool, directory: URL) throws -> SSHKeyRecord {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MutyError("Select a regular private-key file smaller than 1 MB.")
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") ||
              text.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") ||
              text.hasPrefix("-----BEGIN EC PRIVATE KEY-----") ||
              text.hasPrefix("-----BEGIN DSA PRIVATE KEY-----") ||
              text.hasPrefix("-----BEGIN PRIVATE KEY-----") ||
              text.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----") else {
            throw MutyError("Select an OpenSSH/PEM private key, not a .pub or PuTTY .ppk file. Convert .ppk with PuTTYgen first.")
        }
        let fingerprint: String
        do { fingerprint = try Self.fingerprint(file) }
        catch {
            let encryptedPEM = text.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----") ||
                (text.contains("Proc-Type: 4,ENCRYPTED") && text.contains("DEK-Info:"))
            guard encryptedPEM else { throw error }
            fingerprint = "Fingerprint unavailable for encrypted PEM (validated by SSH on connect)"
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let key = SSHKeyRecord(id: UUID(), name: file.lastPathComponent, path: copy ? "" : file.path,
                               imported: copy, fingerprint: fingerprint)
        let destination = directory.appendingPathComponent(key.id.uuidString)
        if copy {
            // Copy unchanged bytes, retaining the original key's passphrase protection.
            try data.write(to: destination, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        return key
    }

    func rename(_ key: SSHKeyRecord, to name: String) throws {
        guard !busy else { throw MutyError("Key import is in progress.") }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw MutyError("Enter a key name.") }
        var updated = keys
        guard let index = updated.firstIndex(where: { $0.id == key.id }) else { return }
        updated[index].name = value
        try save(updated)
    }

    func remove(_ key: SSHKeyRecord) throws {
        guard !busy else { throw MutyError("Key import is in progress.") }
        guard let current = keys.first(where: { $0.id == key.id }) else { return }
        // Keep a durable catalog entry until its managed file is actually removed.
        // Failure or interruption leaves a visible entry that Remove can retry.
        if current.imported {
            var pending = keys
            if let index = pending.firstIndex(where: { $0.id == current.id }) {
                pending[index].pendingDeletion = true
            }
            try save(pending)
            let file = directory.appendingPathComponent(current.id.uuidString)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        try save(keys.filter { $0.id != current.id })
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func save(_ updated: [SSHKeyRecord]) throws {
        guard loadError == nil else { throw MutyError(loadError!) }
        try prepareDirectory()
        try JSONEncoder().encode(updated).write(to: catalog, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: catalog.path)
        keys = updated
    }

    nonisolated private static func fingerprint(_ file: URL) throws -> String {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-l", "-E", "sha256", "-f", file.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else {
            _ = kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw MutyError("Key inspection timed out. Ensure cloud files are downloaded locally.")
        }
        guard process.terminationStatus == 0 else {
            throw MutyError("Cannot inspect this key. Select an OpenSSH key; encrypted PEM may need conversion to OpenSSH first.")
        }
        let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let sha = value.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("SHA256:") }) else {
            throw MutyError("Cannot read key fingerprint.")
        }
        return String(sha)
    }
}
