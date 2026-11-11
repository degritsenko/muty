import Foundation

struct ConfigurationBackup: Codable, Identifiable {
    let id = UUID()
    var format = "muty.sessions"
    var version = 1
    var sessions: [PortableSession]
    var folders: [String]
    var folderColors: [String: String] = [:]
    var buttonBar: ButtonBarDocument? = nil
    // Transient credentials: never encoded by configuration-only export.
    var sourcePath: String? = nil
    var restoredPasswords: [UUID: String] = [:]
    var restoredCredentials: [SavedCredential] = []
    private enum CodingKeys: String, CodingKey { case format, version, sessions, folders, folderColors, buttonBar }
    init(sessions: [PortableSession], folders: [String], folderColors: [String: String] = [:], buttonBar: ButtonBarDocument? = nil) {
        self.sessions = sessions
        self.folders = folders
        self.folderColors = folderColors
        self.buttonBar = buttonBar
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decodeIfPresent(String.self, forKey: .format) ?? "muty.sessions"
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sessions = try values.decode([PortableSession].self, forKey: .sessions)
        folders = try values.decodeIfPresent([String].self, forKey: .folders) ?? []
        folderColors = try values.decodeIfPresent([String: String].self, forKey: .folderColors) ?? [:]
        buttonBar = try values.decodeIfPresent(ButtonBarDocument.self, forKey: .buttonBar)
    }
    func validated() throws -> Self {
        guard format == "muty.sessions", version == 1, sessions.count <= 10000,
              Set(sessions.map(\.id)).count == sessions.count else {
            throw MutyError("Invalid or unsupported muty backup.")
        }
        if let buttonBar { _ = try buttonBar.validated() }
        return self
    }
    static func read(_ url: URL) throws -> Self {
        try BackupArchive.decode(BackupArchive.load(url))
    }
}

// Explicit allowlist: never encode SessionProfile's password flags, key UUID or identity path.
struct PortableSession: Codable, Identifiable {
    var id: UUID
    var name: String
    var description: String?
    var sshEnabled: Bool?
    var sftpEnabled: Bool?
    var host: String
    var port: Int
    var user: String
    var folder: String?
    var favorite: Bool
    var color: String?
    var terminalTheme: String?
    var connectionType: ConnectionType
    var authentication: AuthenticationMode
    var forwards: [PortForward]
    var tunnelOnly: Bool
    var jumpHostID: UUID?
    var keyName: String?
    var keyFingerprint: String?
    var credentialID: UUID? = nil

    init(_ p: SessionProfile, keyName: String?, keyFingerprint: String?, includeCredentialLink: Bool = false) {
        terminalTheme = p.terminalTheme
        credentialID = includeCredentialLink ? p.credentialID : nil
        description = p.description.isEmpty ? nil : p.description
        sshEnabled = p.sshEnabled; sftpEnabled = p.sftpEnabled
        id = p.id; name = p.name; host = p.host; port = p.port; user = p.user
        folder = p.folder; favorite = p.favorite; color = p.color; connectionType = p.connectionType
        authentication = p.authentication; forwards = p.forwards; tunnelOnly = p.tunnelOnly
        jumpHostID = p.jumpHostID; self.keyName = keyName; self.keyFingerprint = keyFingerprint
    }
    func profile(keyID: UUID?) throws -> SessionProfile {
        guard AuthenticationMode.selectable.contains(authentication) else { throw MutyError("Unsupported authentication method.") }
        if connectionType == .ssh && authentication == .identityFile && keyID == nil {
            throw MutyError("Select an SSH key or exclude this session.")
        }
        var p = SessionProfile()
        p.terminalTheme = terminalTheme
        p.description = description ?? ""
        p.sshEnabled = sshEnabled ?? true; p.sftpEnabled = sftpEnabled ?? true
        p.id = id; p.name = name; p.host = host; p.port = port; p.user = user
        p.folder = folder; p.favorite = favorite; p.color = color; p.connectionType = connectionType
        p.authentication = authentication; p.forwards = forwards; p.tunnelOnly = tunnelOnly
        p.credentialID = credentialID
        p.jumpHostID = jumpHostID; p.keyID = keyID; p.savePassword = false
        return try p.validated()
    }
}

struct ConfigurationImportPlan {
    var profiles: [SessionProfile] = []
    var notes: [UUID: String] = [:]
    var existingIDs = Set<UUID>()

    init(backup: ConfigurationBackup, existing: [SessionProfile], selected: Set<UUID>, keyBindings: [UUID: UUID], availableKeys: Set<UUID>) {
        var mapping: [UUID: UUID] = [:]
        var candidates: [UUID: SessionProfile] = [:]
        for entry in backup.sessions where selected.contains(entry.id) {
            let match = existing.first { $0.id == entry.id } ?? existing.first {
                $0.name == entry.name && $0.folder == SessionProfile.canonicalFolder(entry.folder)
            }
            if let match {
                if match.host == entry.host && match.user == entry.user && match.port == entry.port && match.connectionType == entry.connectionType {
                    mapping[entry.id] = match.id; existingIDs.insert(entry.id)
                    notes[entry.id] = "Already exists — kept unchanged"
                } else { notes[entry.id] = "Conflict with existing session — skipped" }
                continue
            }
            do {
                let key = keyBindings[entry.id].flatMap { availableKeys.contains($0) ? $0 : nil }
                let p = try entry.profile(keyID: key)
                candidates[entry.id] = p; mapping[entry.id] = p.id
            } catch { notes[entry.id] = error.localizedDescription }
        }
        // Remove invalid dependencies transitively; never point a dependent at the wrong host.
        var changed = true
        while changed {
            changed = false
            for (id, p) in Array(candidates) {
                guard let originalJump = p.jumpHostID else { continue }
                guard let mapped = mapping[originalJump],
                      let jump = existing.first(where: { $0.id == mapped }) ?? candidates[originalJump],
                      jump.connectionType == .ssh, jump.jumpHostID == nil, jump.id != id else {
                    candidates.removeValue(forKey: id); mapping.removeValue(forKey: id)
                    notes[id] = "Jump host unavailable or nested — include/fix the jump host first"
                    changed = true; continue
                }
            }
        }
        profiles = backup.sessions.compactMap { entry in
            guard var p = candidates[entry.id] else { return nil }
            if let jump = p.jumpHostID { p.jumpHostID = mapping[jump] }
            return p
        }
    }
}
