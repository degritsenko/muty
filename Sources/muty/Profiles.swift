import Foundation
import Darwin

struct MutyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SessionProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var description = ""
    var sshEnabled = true
    var sftpEnabled = false
    var host = ""
    var port = 22
    var user = ""
    var savePassword = false
    var folder: String?
    var favorite = false
    var identityFile: String?
    var credentialID: UUID?
    var keyID: UUID?
    var color: String?
    var terminalTheme: String?
    var connectionType: ConnectionType = .ssh
    var forwards: [PortForward] = []
    var tunnelOnly = false
    var jumpHostID: UUID?
    var authentication: AuthenticationMode = .password
    var endpoint: String { connectionType == .localShell ? "Local Shell" : "\(user)@\(host):\(port)" }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case terminalTheme, id, credentialID, name, description, sshEnabled, sftpEnabled, host, port, user, savePassword, folder, favorite, identityFile, keyID, color, authentication, connectionType, forwards, tunnelOnly, jumpHostID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        sshEnabled = try c.decodeIfPresent(Bool.self, forKey: .sshEnabled) ?? true
        sftpEnabled = try c.decodeIfPresent(Bool.self, forKey: .sftpEnabled) ?? true
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        user = try c.decode(String.self, forKey: .user)
        savePassword = try c.decodeIfPresent(Bool.self, forKey: .savePassword) ?? false
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        credentialID = try c.decodeIfPresent(UUID.self, forKey: .credentialID)
        keyID = try c.decodeIfPresent(UUID.self, forKey: .keyID)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        terminalTheme = try c.decodeIfPresent(String.self, forKey: .terminalTheme)
        forwards = try c.decodeIfPresent([PortForward].self, forKey: .forwards) ?? []
        tunnelOnly = try c.decodeIfPresent(Bool.self, forKey: .tunnelOnly) ?? false
        jumpHostID = try c.decodeIfPresent(UUID.self, forKey: .jumpHostID)
        connectionType = try c.decodeIfPresent(ConnectionType.self, forKey: .connectionType) ?? .ssh
        authentication = try c.decodeIfPresent(AuthenticationMode.self, forKey: .authentication)
            ?? .password
    }

    func validated() throws -> SessionProfile {
        var p = self
        if let theme = p.terminalTheme, TerminalColorScheme(rawValue: theme) == nil {
            p.terminalTheme = nil
        }
        p.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        p.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        p.folder = Self.canonicalFolder(folder)
        if p.authentication == .automatic || p.authentication == .agent {
            p.authentication = (p.keyID != nil || !(p.identityFile ?? "").isEmpty) ? .identityFile : .password
        }
        if p.connectionType == .localShell {
            p.forwards = []; p.tunnelOnly = false; p.jumpHostID = nil
            p.savePassword = false; p.identityFile = nil; p.keyID = nil; p.credentialID = nil
            p.authentication = .password
            if p.name.isEmpty { p.name = "Local Shell" }
            return p
        }
        guard p.sshEnabled || p.sftpEnabled else { throw MutyError("Enable SSH or SFTP for this session.") }
        guard Set(p.forwards.map(\.id)).count == p.forwards.count else { throw MutyError("Duplicate forwarding rule IDs.") }
        guard p.forwards.count <= 32 else { throw MutyError("At most 32 forwarding rules per session.") }
        guard !p.tunnelOnly || !p.forwards.isEmpty else { throw MutyError("Add at least one forwarding rule for tunnel-only mode.") }
        guard p.jumpHostID != p.id else { throw MutyError("A session cannot use itself as jump host.") }
        var listeners = Set<String>()
        for rule in p.forwards where rule.enabled != false {
            _ = try rule.arguments()
            guard listeners.insert(rule.listenerKey).inserted else {
                throw MutyError("Duplicate listening address/port in forwarding rules.")
            }
        }
        if p.authentication != .password { p.credentialID = nil }
        if p.authentication == .identityFile && p.keyID == nil {
            guard let path = p.identityFile, !path.isEmpty, !path.contains("\0") else {
                throw MutyError("Choose an SSH identity file.")
            }
            p.identityFile = NSString(string: path).expandingTildeInPath
        }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !p.host.isEmpty, !p.host.hasPrefix("-"), !p.host.contains("@"),
              !p.host.contains("/"), p.host.rangeOfCharacter(from: forbidden) == nil else {
            throw MutyError("Enter a hostname or IP without spaces or user@.")
        }
        guard !p.user.isEmpty, !p.user.hasPrefix("-"), !p.user.contains("@"),
              p.user.rangeOfCharacter(from: forbidden) == nil else { throw MutyError("Enter an SSH username without spaces.") }
        guard (1...65535).contains(p.port) else { throw MutyError("Port must be between 1 and 65535.") }
        if p.name.isEmpty { p.name = p.host }
        return p
    }

    static func canonicalFolder(_ value: String?) -> String? {
        guard let value else { return nil }
        let path = value.split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "/")
        return path.isEmpty ? nil : path
    }

    func sameDestination(as other: SessionProfile) -> Bool {
        connectionType == other.connectionType && (connectionType == .localShell || (host == other.host && port == other.port && user == other.user && jumpHostID == other.jumpHostID))
    }
}

enum ConnectionType: String, Codable, CaseIterable, Identifiable {
    case ssh, localShell
    var id: String { rawValue }
    var title: String { self == .ssh ? "SSH" : "Local Shell" }
    var icon: String { self == .ssh ? "desktopcomputer" : "terminal" }
}

enum AuthenticationMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    case password
    case agent
    case identityFile
    static var selectable: [AuthenticationMode] { [.password, .identityFile] }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .password: return "Password"
        case .agent: return "SSH agent"
        case .identityFile: return "SSH Key"
        }
    }
}

struct ProfileStore {
    private struct Document: Codable {
        var version: Int
        var profiles: [SessionProfile]
        var folders: [String]?
    }
    let directory: URL
    var file: URL { directory.appendingPathComponent("profiles.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("muty", isDirectory: true)
    }

    func load() throws -> [SessionProfile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            let doc = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard doc.version == 1 else { throw MutyError("Unsupported profiles version.") }
            guard Set(doc.profiles.map(\.id)).count == doc.profiles.count else {
                throw MutyError("Duplicate profile IDs.")
            }
            return try doc.profiles.map { try $0.validated() }
        } catch {
            throw MutyError("Could not read \(file.path). The file was not changed. \(error.localizedDescription)")
        }
    }

    func loadFolders() throws -> [String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: file)).folders ?? []
    }

    func save(_ profiles: [SessionProfile], folders: [String] = []) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, profiles: profiles, folders: folders))
        var template = Array(directory.appendingPathComponent(".profiles-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporary = String(cString: template)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlink(temporary)
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

// Row identity distinguishes folders and separate presentations of the same session.
struct SessionRowID: Hashable {
    enum Location: Hashable { case sessions, favorites, search, folder }
    let profileID: UUID?
    let location: Location
    var folderPath: String? = nil
    static func folder(_ path: String?) -> Self {
        Self(profileID: nil, location: .folder, folderPath: path)
    }
}
