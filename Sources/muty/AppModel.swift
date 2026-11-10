import SwiftUI
import AppKit

struct ProfileDraft: Identifiable {
    let id = UUID()
    var profile: SessionProfile
    let original: SessionProfile?
    init(_ profile: SessionProfile) {
        self.profile = profile
        original = profile
    }
    init(new profile: SessionProfile = SessionProfile()) {
        self.profile = profile
        original = nil
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [SessionProfile] = []
    private var transferQueues: [String: SFTPTransferQueue] = [:]
    func transferQueue(for id: UUID, endpoint: String, jump: SessionProfile?) -> SFTPTransferQueue {
        let route = jump.map { $0.id.uuidString + ":" + $0.endpoint } ?? ""
        let key = id.uuidString + ":" + endpoint + "\0" + route
        if let queue = transferQueues[key] { return queue }
        let queue = SFTPTransferQueue(); transferQueues[key] = queue; return queue
    }
    @Published var sessionClipboard: SessionClipboard?
    @Published var selectedProfile: UUID?
    @Published var selectedFolder: String? = nil
    @Published private var emptyFolders: [String] = []
    @Published var tabs: [SSHConnection] = [] { didSet { persistWorkspace() } }
    @Published var selectedTab: UUID? { didSet { persistWorkspace() } }
    let keyLibrary = SSHKeyLibrary()
    @Published var backupProgress: String?
    @Published var fullBackupExport = false
    @Published var lockedBackup: LockedBackup?
    @Published var configurationImport: ConfigurationBackup?
    @Published var importPreview: SessionImportPreview?
    @Published var mobaXtermImport: MobaXtermImport?
    @Published var splitMode = "none"
    @Published var splitSlots: [UUID?] = []
    private var activeSplitIndex = 0
    func split(_ mode: String, secondary: UUID? = nil) {
        guard mode != "none", !tabs.isEmpty else { splitMode = "none"; splitSlots = []; activeSplitIndex = 0; return }
        let count = mode == "four" ? 4 : mode == "three" ? 3 : 2
        if secondary != nil || splitSlots.isEmpty {
            splitSlots = [selectedTab ?? tabs.first?.id]
        }
        splitSlots = Array(splitSlots.prefix(count))
        while splitSlots.count < count { splitSlots.append(nil) }
        if let secondary, tabs.contains(where: { $0.id == secondary }), secondary != splitSlots[0] { splitSlots[1] = secondary }
        splitMode = mode; activeSplitIndex = min(activeSplitIndex, count - 1)
        syncSplitSelection()
    }
    func assignSplitTab(_ id: UUID, to index: Int) {
        guard splitMode != "none", splitSlots.indices.contains(index), tabs.contains(where: { $0.id == id }) else { return }
        if let old = splitSlots.firstIndex(where: { $0 == id }), old != index { splitSlots[old] = splitSlots[index] }
        splitSlots[index] = id; activeSplitIndex = index; selectedTab = id
    }
    func syncSplitSelection() {
        guard splitMode != "none", let id = selectedTab, tabs.contains(where: { $0.id == id }) else { return }
        if let index = splitSlots.firstIndex(where: { $0 == id }) { activeSplitIndex = index }
        else if splitSlots.indices.contains(activeSplitIndex) { splitSlots[activeSplitIndex] = id }
    }
    func selectTab(_ id: UUID) { selectedTab = id; syncSplitSelection() }
    @Published var terminalFindRequest = UUID()
    @Published var quickConnect = false
    @Published var newFolderPrompt = false
    @Published var bulkEditing: BulkEditRequest?
    @Published var editing: ProfileDraft?
    @Published var editingTab: UUID?
    var editingTabConnection: SSHConnection? { editingTab.flatMap { id in tabs.first { $0.id == id } } }
    var confirmSessionSettingsChange: ((String, String) -> Bool)?
    func confirmSessionSettings(_ title: String, text: String) -> Bool {
        confirmSessionSettingsChange?(title, text) ?? confirm(title, text: text)
    }
    @Published var operationStatus: String? { didSet { scheduleStatusDismissal() } }
    private var statusDismissal: Task<Void, Never>?
    @Published var errorMessage: String?
    @Published private(set) var readOnly = false
    private let store: ProfileStore
    let vault: VaultStore
    private let passwordStore: any CredentialStore
    private let workspaceStore: WorkspaceStore
    private var startupHandled = false
    private var workspaceReady = false
    private var workspaceBlocked = false
    var configurationFolders: [String] { emptyFolders }
    var selectedConnection: SSHConnection? { tabs.first { $0.id == selectedTab } }
    func currentFolder(for connection: SSHConnection) -> String? {
        if !connection.temporary, let profile = profiles.first(where: { $0.id == connection.profile.id }) {
            return profile.folder
        }
        return connection.profile.folder
    }

    private func scheduleStatusDismissal() {
        statusDismissal?.cancel()
        guard operationStatus != nil else { statusDismissal = nil; return }
        statusDismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.operationStatus = nil
        }
    }


    init(store: ProfileStore = ProfileStore(), keychain: (any CredentialStore)? = nil) {
        self.store = store
        let vault = VaultStore(directory: store.directory)
        self.vault = vault; self.passwordStore = keychain ?? vault
        self.workspaceStore = WorkspaceStore(directory: store.directory)
        do { profiles = try store.load(); emptyFolders = try store.loadFolders() }
        catch { readOnly = true; errorMessage = error.localizedDescription }
        if vault.needsSetup && passwordStore is VaultStore {
            for index in profiles.indices { profiles[index].savePassword = false }
        }
        if !readOnly && UserDefaults.standard.bool(forKey: "restoreTabsOnLaunch") {
            do {
                if let document = try workspaceStore.load() {
                    var active: UUID?
                    for (index, saved) in document.tabs.enumerated() {
                        guard let profile = profiles.first(where: { $0.id == saved.profileID }) else { continue }
                        let tab = SSHConnection(profile: profile, manual: false, credentials: passwordStore, deferredStart: true)
                        tab.tabName = saved.name
                        configurePasswordSaving(tab)
                        tabs.append(tab)
                        if index == document.selectedIndex { active = tab.id }
                    }
                    selectedTab = active ?? tabs.first?.id
                }
            } catch {
                workspaceBlocked = true
                errorMessage = "Workspace could not be restored: " + error.localizedDescription
            }
        }
        workspaceReady = true
    }

    func openStartupSession() {
        guard !startupHandled else { return }
        startupHandled = true
        guard !readOnly,
              let value = UserDefaults.standard.string(forKey: "startupSessionID"),
              let id = UUID(uuidString: value),
              let profile = profiles.first(where: { $0.id == id }) else {
            guard !readOnly, tabs.isEmpty else { return }
            switch UserDefaults.standard.string(forKey: "startupEmptyAction") {
            case "localShell":
                var profile = SessionProfile()
                profile.connectionType = .localShell; profile.name = "Local Shell"
                connect(profile, temporary: true)
            case "quickConnect": quickConnect = true
            default: break
            }
            return
        }
        if let tab = tabs.first(where: { $0.profile.id == id }) {
            if tab.running { selectedTab = tab.id }
            else { reconnect(tab) }
        } else { connect(profile) }
    }

    func editSelectedSessions(_ rows: Set<SessionRowID>) {
        let ids = Set(rows.compactMap(\.profileID))
        let folders = rows.filter { $0.location == .folder }
        let affected = profiles.filter { profile in
            return ids.contains(profile.id) || folders.contains { row in
                guard let folder = row.folderPath else { return true }
                return profile.folder == folder || profile.folder?.hasPrefix(folder + "/") == true
            }
        }
        bulkEditing = BulkEditRequest(folder: "Selected items", profiles: affected)
    }

    func editFolderSessions(_ folder: String?) {
        let affected = profiles.filter { profile in
            guard let folder else { return true }
            return profile.folder == folder || profile.folder?.hasPrefix(folder + "/") == true
        }
        bulkEditing = BulkEditRequest(folder: folder, profiles: affected)
    }

    func applyBulkEdit(_ request: BulkEditRequest, user: String?, keyID: UUID?,
                       changeJump: Bool, jumpID: UUID?, credentialID: UUID? = nil,
                       sshEnabled: Bool? = nil, sftpEnabled: Bool? = nil,
                       changeColor: Bool = false, color: String? = nil,
                       changeTheme: Bool = false, terminalTheme: String? = nil) throws {
        guard !readOnly else { throw MutyError("Profiles are read-only.") }
        guard !request.profiles.isEmpty else { throw MutyError("No sessions in this folder.") }
        guard request.profiles.allSatisfy({ original in profiles.contains(original) }) else {
            throw MutyError("Sessions changed. Close and reopen Bulk Edit.")
        }
        guard credentialID == nil || (user == nil && keyID == nil) else { throw MutyError("Assign a shared credential separately from username or SSH key changes.") }
        let shared: SavedCredential?
        if let credentialID { try vault.ensureAvailable(); shared = try vault.credential(credentialID) } else { shared = nil }
        if let keyID { _ = try keyLibrary.path(for: keyID) }
        let ids = Set(request.profiles.map(\.id))
        var updated = profiles
        var authenticationIDs = Set<UUID>()
        for index in updated.indices where ids.contains(updated[index].id) {
            if updated[index].connectionType == .ssh {
                if let sshEnabled { updated[index].sshEnabled = sshEnabled }
                if let sftpEnabled { updated[index].sftpEnabled = sftpEnabled }
                if user != nil || keyID != nil { updated[index].credentialID = nil }
                if let shared {
                    updated[index].credentialID = shared.id; updated[index].user = shared.username
                    updated[index].authentication = .password; updated[index].savePassword = false
                    updated[index].keyID = nil; updated[index].identityFile = nil
                }
                if let user {
                    updated[index].user = user.trimmingCharacters(in: .whitespacesAndNewlines)
                    if updated[index].user != profiles[index].user { updated[index].savePassword = false }
                }
                if let keyID {
                    updated[index].keyID = keyID; updated[index].identityFile = nil
                    updated[index].authentication = .identityFile; updated[index].savePassword = false
                }
                if changeJump { updated[index].jumpHostID = jumpID }
                let original = profiles[index]
                let changed = updated[index]
                if changed.user != original.user || changed.keyID != original.keyID ||
                    changed.identityFile != original.identityFile || changed.credentialID != original.credentialID ||
                    changed.authentication != original.authentication || changed.savePassword != original.savePassword ||
                    changed.jumpHostID != original.jumpHostID || changed.sshEnabled != original.sshEnabled ||
                    changed.sftpEnabled != original.sftpEnabled {
                    authenticationIDs.insert(original.id)
                }
            }
            if changeColor { updated[index].color = color }
            if changeTheme { updated[index].terminalTheme = terminalTheme }
            updated[index] = try updated[index].validated()
        }
        // Validate the final graph, including sessions outside the edited folder.
        for profile in updated {
            if let id = profile.jumpHostID {
                guard let jump = updated.first(where: { $0.id == id }), jump.id != profile.id,
                      jump.connectionType == .ssh, jump.jumpHostID == nil else {
                    throw MutyError("Invalid jump host for " + profile.name + ". Self-reference and nested jump hosts are not supported.")
                }
            }
        }
        try store.save(updated, folders: emptyFolders)
        tabs.filter { authenticationIDs.contains($0.profile.id) || $0.profile.jumpHostID.map(authenticationIDs.contains) == true }
            .forEach { $0.revokeAuthentication() }
        profiles = updated
    }

    func workspacePreferenceChanged(_ enabled: Bool) {
        workspaceBlocked = false
        if enabled { persistWorkspace() }
        else {
            do { try workspaceStore.clear() }
            catch { errorMessage = "Could not clear saved workspace: " + error.localizedDescription }
        }
    }

    func persistWorkspace() {
        guard workspaceReady, !workspaceBlocked, !readOnly,
              UserDefaults.standard.bool(forKey: "restoreTabsOnLaunch") else { return }
        let saved = tabs.filter { !$0.temporary }
        let valid = saved.filter { tab in profiles.contains { $0.id == tab.profile.id } }
        let document = WorkspaceDocument(tabs: valid.map { .init(profileID: $0.profile.id, name: $0.tabName) }, selectedIndex: valid.firstIndex { $0.id == selectedTab })
        do { try workspaceStore.save(document) }
        catch { workspaceBlocked = true; errorMessage = "Could not save workspace: " + error.localizedDescription }
    }

    func renameTab(_ tab: SSHConnection, to name: String?) {
        tab.tabName = name; persistWorkspace()
    }

    func makeFullBackup(includePasswords: Bool = true, progress: ((String) -> Void)? = nil) async throws -> FullBackup {
        progress?("Reading sessions and folders…")
        await Task.yield()
        if !includePasswords {
            let configuration = ConfigurationBackup(sessions: profiles.map { profile in
                let key = keyLibrary.keys.first { $0.id == profile.keyID }
                return PortableSession(profile, keyName: key?.name, keyFingerprint: key?.fingerprint)
            }, folders: configurationFolders, buttonBar: try SendStringButtonStore.shared.snapshot())
            for profile in profiles { progress?("Exporting session: " + profile.name) }
            progress?("Exporting \(configuration.folders.count) folders and Button Bar.")
            return FullBackup(configuration: configuration, passwords: [])
        }
        try preparePasswordStorage()
        let snapshot = profiles
        defer { backupProgress = nil }
        let configuration = try ConfigurationBackup(sessions: snapshot.map { profile in
            let profile = try effectiveProfile(profile)
            let key = keyLibrary.keys.first { $0.id == profile.keyID }
            return PortableSession(profile, keyName: key?.name, keyFingerprint: key?.fingerprint, includeCredentialLink: true)
        }, folders: configurationFolders, buttonBar: try SendStringButtonStore.shared.snapshot())
        for profile in snapshot { progress?("Exporting session: " + profile.name) }
        progress?("Exporting \(configuration.folders.count) folders and Button Bar.")
        await Task.yield()
        var passwords: [BackupPassword] = []
        let saved = snapshot.filter { $0.connectionType == .ssh && $0.authentication == .password && $0.credentialID == nil && $0.savePassword }
        for (index, profile) in saved.enumerated() {
            try Task.checkCancellation()
            backupProgress = "Reading password \(index + 1) of \(saved.count): \(profile.name)"
            progress?("Exporting password \(index + 1)/\(saved.count): " + [profile.folder, profile.name].compactMap { $0 }.joined(separator: "/"))
            await Task.yield()
            guard let secret = try passwordStore.read(id: profile.id) else { throw MutyError("Saved password is missing for " + profile.name) }
            passwords.append(BackupPassword(sessionID: profile.id, password: secret))
        }
        try Task.checkCancellation()
        let credentials = try vault.snapshot().credentials
        for credential in credentials { progress?("Exporting shared credential: " + credential.title) }
        return FullBackup(configuration: configuration, passwords: passwords, credentials: credentials)
    }

    @discardableResult
    func importConfiguration(_ backup: ConfigurationBackup, selected: Set<UUID>, keyBindings: [UUID: UUID], restorePasswords: Bool = false, replacePasswords: Bool = false, linkExistingCredentials: Bool = false, restoreButtonBar: Bool = false, progress: ((String) -> Void)? = nil, previewOnly: Bool = false) throws -> String {
        guard !readOnly else { throw MutyError("Profiles are read-only.") }
        progress?("Validating backup…")
        _ = try backup.validated()
        var credentialResults: [String] = []
        var prepared = backup
        let hasSecrets = restorePasswords && (!backup.restoredPasswords.isEmpty || !backup.restoredCredentials.isEmpty)
        var before: VaultDocument?
        var candidate: VaultDocument?
        var mapping: [UUID: UUID] = [:]
        var processedShared = 0
        var addedPasswords = 0
        var replacedPasswords = 0
        var keptPasswords = 0
        if hasSecrets {
            try vault.ensureAvailable()
            before = try vault.snapshot(); candidate = before
            let referenced = Set(backup.sessions.filter { selected.contains($0.id) }.compactMap(\.credentialID))
            let restoreAll = backup.sessions.allSatisfy { selected.contains($0.id) }
            for incoming in backup.restoredCredentials where restoreAll || referenced.contains(incoming.id) {
                processedShared += 1
                _ = try incoming.validated()
                if let existing = candidate!.credentials.first(where: { $0.id == incoming.id || $0.title.caseInsensitiveCompare(incoming.title) == .orderedSame }) {
                    guard existing.username == incoming.username else { throw MutyError("Shared credential conflict: " + incoming.title + ". Username differs; rename or remove the existing credential first.") }
                    mapping[incoming.id] = existing.id
                    if replacePasswords { replacedPasswords += 1 } else { keptPasswords += 1 }
                    if replacePasswords, let index = candidate!.credentials.firstIndex(where: { $0.id == existing.id }) {
                        var value = incoming; value.id = existing.id; candidate!.credentials[index] = value
                    }
                    credentialResults.append(replacePasswords ? "Updated shared credential: " + incoming.title : "Kept shared credential: " + incoming.title)
                } else {
                    addedPasswords += 1
                    candidate!.credentials.append(incoming); mapping[incoming.id] = incoming.id
                    credentialResults.append("Added shared credential: " + incoming.title)
                }
            }
        }
        for index in prepared.sessions.indices {
            if let id = prepared.sessions[index].credentialID {
                if restorePasswords && selected.contains(prepared.sessions[index].id) {
                    guard let mapped = mapping[id] else { throw MutyError("Shared credential is missing from backup.") }
                    prepared.sessions[index].credentialID = mapped
                } else { prepared.sessions[index].credentialID = nil }
            }
        }
        let keys = Set(keyLibrary.keys.filter { $0.pendingDeletion != true }.map(\.id))
        let plan = ConfigurationImportPlan(backup: prepared, existing: profiles, selected: selected, keyBindings: keyBindings, availableKeys: keys)
        guard selected.count == plan.profiles.count + plan.existingIDs.count else {
            throw MutyError("Resolve the highlighted conflicts and missing keys, or exclude those sessions before importing.")
        }
        var updated = profiles + plan.profiles
        var restored = 0
        if hasSecrets {
            for entry in prepared.sessions where selected.contains(entry.id) {
                if let linked = entry.credentialID {
                    if let match = updated.firstIndex(where: { $0.id == entry.id }) ?? updated.firstIndex(where: { $0.name == entry.name && $0.folder == SessionProfile.canonicalFolder(entry.folder) }) {
                        let isNew = !profiles.contains(where: { $0.id == updated[match].id })
                        let ownPassword = candidate!.sessionPasswords[updated[match].id.uuidString]
                        if isNew || (linkExistingCredentials && updated[match].authentication == .password &&
                                     (replacePasswords || (updated[match].credentialID == nil && ownPassword == nil))) {
                            updated[match].credentialID = linked
                            updated[match].savePassword = false
                            candidate!.sessionPasswords.removeValue(forKey: updated[match].id.uuidString)
                        }
                    }
                    continue
                }
                guard let secret = backup.restoredPasswords[entry.id] else { continue }
                try VaultStore.validatePassword(secret)
                guard let index = updated.firstIndex(where: { $0.id == entry.id }) ?? updated.firstIndex(where: { $0.name == entry.name && $0.folder == SessionProfile.canonicalFolder(entry.folder) }),
                      updated[index].connectionType == .ssh, updated[index].authentication == .password,
                      (updated[index].credentialID == nil || (linkExistingCredentials && replacePasswords)), updated[index].host == entry.host,
                      updated[index].user == entry.user, updated[index].port == entry.port else {
                    throw MutyError("Cannot restore password for " + entry.name + ": destination or authentication differs.")
                }
                let id = updated[index].id.uuidString
                if linkExistingCredentials && replacePasswords { updated[index].credentialID = nil }
                if candidate!.sessionPasswords[id] == nil || replacePasswords {
                    if candidate!.sessionPasswords[id] == nil { addedPasswords += 1 }
                    else { replacedPasswords += 1 }
                    candidate!.sessionPasswords[id] = secret; restored += 1
                } else { keptPasswords += 1 }
                updated[index].savePassword = true
            }
        }
        let passwordSummary = "\(addedPasswords) missing passwords will be restored. \(replacedPasswords) existing passwords will be replaced. \(keptPasswords) existing passwords will be kept. Counts include session passwords and shared credentials."
        let folders = Array(Set(emptyFolders + backup.folders.compactMap(SessionProfile.canonicalFolder))).sorted()
        let addedFolderCount = Set(folders).subtracting(Set(configurationFolders)).count
        let incomingButtonBar = restoreButtonBar ? backup.buttonBar : nil
        var summaryLines = [
            "Sessions: \(plan.profiles.count) will be added; \(plan.existingIDs.count) existing sessions will be kept.",
            "Folders: \(addedFolderCount) will be added."
        ]
        if hasSecrets {
            summaryLines.append("Passwords: \(addedPasswords) will be added; \(replacedPasswords) replaced; \(keptPasswords) kept.")
            summaryLines.append("Password counts include session passwords and shared credentials.")
        }
        if incomingButtonBar != nil {
            summaryLines.append("Button Bar: current sets, commands and folder assignments will be replaced.")
        }
        if previewOnly { return summaryLines.joined(separator: "\n\n") }
        let previousButtonBar = incomingButtonBar.map { _ in SendStringButtonStore.shared.checkpoint() }
        progress?("Saving restored configuration and selected credentials…")
        if let candidate { try vault.replace(candidate) }
        do {
            if let incomingButtonBar { try SendStringButtonStore.shared.restore(incomingButtonBar) }
            try store.save(updated, folders: folders)
        }
        catch {
            progress?("Save failed. Rolling back changes…")
            if let previousButtonBar { SendStringButtonStore.shared.rollback(previousButtonBar) }
            if let before {
                do { try vault.replace(before) }
                catch { throw MutyError("Import and password-vault rollback failed. Check password storage before retrying.") }
            }
            throw error
        }
        if hasSecrets { tabs.forEach { $0.revokeAuthentication() } }
        profiles = updated; emptyFolders = folders
        for profile in plan.profiles { progress?("Added session: " + profile.name) }
        for entry in backup.sessions where selected.contains(entry.id) && plan.existingIDs.contains(entry.id) {
            progress?("Kept existing session: " + entry.name)
        }
        for result in credentialResults { progress?(result) }
        progress?("Restored \(restored) session passwords; existing passwords \(replacePasswords ? "may be replaced" : "kept").")
        progress?("Added \(addedFolderCount) folders.")
        if incomingButtonBar != nil { progress?("Replaced Button Bar.") }
        let summary = "Import complete: \(plan.profiles.count) sessions added, \(restored) session passwords and \(processedShared) shared credentials processed."
        if let progress { progress(summary) }
        else { operationStatus = summary }
        return passwordSummary
    }

    func importSessions(_ imported: [SessionProfile], folders: [String]) throws {
        guard !readOnly else { throw MutyError("Profiles are read-only.") }
        var updated = profiles
        for profile in imported {
            guard !updated.contains(where: { $0.name == profile.name && $0.folder == profile.folder }) else { continue }
            updated.append(try profile.validated())
        }
        let updatedFolders = Array(Set(emptyFolders + folders)).sorted()
        try store.save(updated, folders: updatedFolders)
        let added = updated.count - profiles.count
        profiles = updated; emptyFolders = updatedFolders
        operationStatus = "Import complete: \(added) sessions added, \(imported.count - added) duplicates skipped."
    }

    private func validateJumpHost(_ p: SessionProfile) throws {
        if let jumpID = p.jumpHostID {
            guard let jump = profiles.first(where: { $0.id == jumpID }), jump.connectionType == .ssh,
                  jump.jumpHostID == nil, jump.id != p.id else { throw MutyError("Select one existing SSH jump host without another jump host.") }
        }
        if (p.jumpHostID != nil || p.connectionType != .ssh) && profiles.contains(where: { $0.jumpHostID == p.id }) {
            throw MutyError("This session is used as a jump host; nested jump hosts are not supported.")
        }
    }

    func save(_ value: SessionProfile, password: String, reuse: Bool, revokeActiveAuthentication: Bool = true) throws {
        guard !readOnly else { throw MutyError("Profiles are read-only because loading failed. Fix the file and restart muty.") }
        var input = value
        if input.authentication == .password, let id = input.credentialID {
            try vault.ensureAvailable()
            input.user = try vault.credential(id).username; input.savePassword = false
        }
        var p = try input.validated()
        if p.authentication == .identityFile || p.authentication == .agent {
            p.savePassword = false
        }
        try validateJumpHost(p)
        let old = profiles.first { $0.id == p.id }
        let changed = old.map { !p.sameDestination(as: $0) } ?? false
        let authenticationChanged = old.map {
            $0.authentication != p.authentication || $0.keyID != p.keyID || $0.identityFile != p.identityFile || $0.credentialID != p.credentialID
        } ?? false
        guard !p.savePassword || !password.isEmpty || old?.savePassword == true else {
            throw MutyError("Enter a password or disable password saving.")
        }
        if changed && p.savePassword && password.isEmpty && !reuse {
            throw MutyError("For a new destination, enter a password or explicitly allow reusing the current password.")
        }
        guard password.utf8.count <= 1023, !password.contains("\n"), !password.contains("\r"), !password.contains("\0") else {
            throw MutyError("Password must be at most 1023 UTF-8 bytes and contain no newline or NUL.")
        }
        // Revoke pending authentication before mutating a credential or its destination.
        if revokeActiveAuthentication && (changed || authenticationChanged || !password.isEmpty || old?.savePassword != p.savePassword) {
            tabs.filter { $0.profile.id == p.id || $0.profile.jumpHostID == p.id }.forEach { $0.revokeAuthentication() }
        }
        let writesPassword = p.savePassword && !password.isEmpty
        if writesPassword { try preparePasswordStorage() }
        let previousSecret = writesPassword ? try passwordStore.read(id: p.id) : nil
        if writesPassword {
            try passwordStore.write(id: p.id, password: password, name: p.name, endpoint: p.endpoint)
        }
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == p.id }) { updated[index] = p }
        else { updated.append(p) }
        do { try store.save(updated, folders: emptyFolders) }
        catch {
            guard writesPassword else { throw error }
            do {
                if let previousSecret { try passwordStore.write(id: p.id, password: previousSecret, name: old?.name ?? p.name, endpoint: old?.endpoint ?? p.endpoint) }
                else { try passwordStore.delete(id: p.id) }
            } catch { throw MutyError("Profile save and password storage rollback failed. Check profiles.json and item \(p.id).") }
            throw error
        }
        profiles = updated; selectedProfile = p.id; selectedFolder = p.folder
    }

    var folders: [String] {
        let paths = emptyFolders + profiles.compactMap { normalizedFolder($0.folder) }
        var all = Set<String>()
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            for index in components.indices { all.insert(components[...index].joined(separator: "/")) }
        }
        return all.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    func profiles(in folder: String?) -> [SessionProfile] {
        profiles.filter { normalizedFolder($0.folder) == folder }
    }

    func copySessionItems(_ rows: Set<SessionRowID>, cut: Bool) {
        guard !readOnly else { return }
        let roots = rows.compactMap { $0.location == .folder ? $0.folderPath : nil }.sorted()
        let rootFolders = roots.filter { path in !roots.contains { $0 != path && path.hasPrefix($0 + "/") } }
        let ids = Set(rows.compactMap(\.profileID))
        let selected = profiles.filter { profile in
            ids.contains(profile.id) || rootFolders.contains { folder in
                profile.folder == folder || profile.folder?.hasPrefix(folder + "/") == true
            }
        }
        guard !selected.isEmpty || !rootFolders.isEmpty else { return }
        sessionClipboard = SessionClipboard(profiles: selected, roots: rootFolders,
            folders: folders.filter { path in rootFolders.contains { path == $0 || path.hasPrefix($0 + "/") } }, cut: cut)
    }
    func pasteSessionItems(into destination: String?) {
        guard !readOnly, let clipboard = sessionClipboard else { return }
        do {
            guard destination == nil || folders.contains(destination!) else { throw MutyError("The destination folder no longer exists.") }
            let plan = try clipboard.plan(profiles: profiles, folders: folders, destination: destination)
            guard !plan.added.isEmpty || plan.folders != folders || plan.profiles != profiles else { return }
            var written: [UUID] = []
            do {
                for pair in plan.added where pair.copy.savePassword && pair.copy.credentialID == nil {
                    try preparePasswordStorage()
                    guard let secret = try passwordStore.read(id: pair.source) else { throw MutyError("A saved password is missing. Nothing was pasted.") }
                    try passwordStore.write(id: pair.copy.id, password: secret, name: pair.copy.name, endpoint: pair.copy.endpoint)
                    written.append(pair.copy.id)
                }
                try saveFolderChanges(plan.profiles, folders: plan.folders, mapping: plan.movedFolders)
            } catch {
                var rollbackFailed = false
                for id in written { do { try passwordStore.delete(id: id) } catch { rollbackFailed = true } }
                if rollbackFailed { throw MutyError("Paste failed and copied-password cleanup failed. Original sessions were not changed.") }
                throw error
            }
            profiles = plan.profiles; emptyFolders = plan.folders; selectedFolder = destination
            if clipboard.cut { sessionClipboard = nil }
            operationStatus = clipboard.cut ? "Selected items moved." : "Selected items copied."
        } catch { errorMessage = error.localizedDescription }
    }
    func createFolder(_ name: String) {
        let value = SessionProfile.canonicalFolder(name) ?? ""
        guard !value.isEmpty, value != "__favorites", !readOnly else { return }
        guard !folders.contains(where: { $0.localizedCaseInsensitiveCompare(value) == .orderedSame }) else {
            errorMessage = "A folder with that name already exists."
            return
        }
        do {
            let names = emptyFolders + [value]
            try store.save(profiles, folders: names)
            emptyFolders = names
            selectedFolder = value
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveFolderChanges(_ profiles: [SessionProfile], folders: [String], mapping: [String: String]) throws {
        guard !mapping.isEmpty else { try store.save(profiles, folders: folders); return }
        let buttons = SendStringButtonStore.shared
        let updated = try buttons.movingFolders(mapping)
        let checkpoint = buttons.checkpoint()
        try buttons.replace(updated)
        do { try store.save(profiles, folders: folders) }
        catch { buttons.rollback(checkpoint); throw error }
    }

    func renameFolder(_ folder: String, to name: String) {
        let value = SessionProfile.canonicalFolder(name) ?? ""
        guard !value.isEmpty, value != "__favorites", !value.hasPrefix(folder + "/"), !readOnly else { return }
        guard !folders.contains(where: {
            $0 != folder && $0.localizedCaseInsensitiveCompare(value) == .orderedSame
        }) else {
            errorMessage = "A folder with that name already exists."
            return
        }
        var updated = profiles
        func renamed(_ path: String) -> String {
            path == folder ? value : value + path.dropFirst(folder.count)
        }
        for index in updated.indices {
            if let path = updated[index].folder, path == folder || path.hasPrefix(folder + "/") {
                updated[index].folder = renamed(path)
            }
        }
        do {
            let names = Array(Set(folders.map { ($0 == folder || $0.hasPrefix(folder + "/")) ? renamed($0) : $0 } + [value]))
            try saveFolderChanges(updated, folders: names, mapping: [folder: value])
            profiles = updated; emptyFolders = names; selectedFolder = value
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteFolder(_ folder: String) {
        guard !readOnly, confirm("Delete Folder?", text: "All sessions in this folder and its subfolders will be moved to Unfiled. No sessions or passwords will be deleted.") else { return }
        var updated = profiles
        for index in updated.indices where updated[index].folder == folder || updated[index].folder?.hasPrefix(folder + "/") == true {
            updated[index].folder = nil
        }
        do {
            let names = folders.filter { $0 != folder && !$0.hasPrefix(folder + "/") }
            try store.save(updated, folders: names)
            profiles = updated; emptyFolders = names; selectedFolder = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func move(_ profile: SessionProfile, to folder: String?) {
        guard !readOnly, let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profiles
        updated[index].folder = SessionProfile.canonicalFolder(folder)
        persist(updated)
    }

    @discardableResult
    func dropSessions(_ values: [String], into folder: String?) -> Bool {
        guard !readOnly else { return false }
        let ids = values.compactMap { value -> UUID? in
            guard value.hasPrefix("muty-session:") else { return nil }
            return UUID(uuidString: String(value.dropFirst("muty-session:".count)))
        }
        let draggedFolders = values.compactMap { value -> String? in
            guard value.hasPrefix("muty-folder:") else { return nil }
            return String(value.dropFirst("muty-folder:".count))
        }
        guard ids.count + draggedFolders.count == values.count else { return false }
        if !draggedFolders.isEmpty {
            return moveDraggedFolders(Set(draggedFolders), sessions: Set(ids), into: folder)
        }
        guard !ids.isEmpty, ids.allSatisfy({ id in profiles.contains { $0.id == id } }) else { return false }
        var updated = profiles
        for index in updated.indices where ids.contains(updated[index].id) {
            updated[index].folder = SessionProfile.canonicalFolder(folder)
        }
        return persist(updated)
    }

    private func moveDraggedFolders(_ paths: Set<String>, sessions: Set<UUID>, into destination: String?) -> Bool {
        let currentFolders = folders
        guard paths.allSatisfy(currentFolders.contains),
              sessions.isSubset(of: Set(profiles.map(\.id))),
              destination.map(currentFolders.contains) ?? true else { return false }
        let roots = paths.filter { path in
            !paths.contains { path.hasPrefix($0 + "/") }
        }
        if let destination, roots.contains(where: { destination == $0 || destination.hasPrefix($0 + "/") }) {
            return false
        }
        let movingRoots = roots.filter { path in
            let parent = path.split(separator: "/").dropLast().joined(separator: "/")
            return parent != (destination ?? "")
        }
        let movingSessions = profiles.filter { sessions.contains($0.id) && $0.folder != destination }
        guard !movingRoots.isEmpty || !movingSessions.isEmpty else { return false }
        let move = SessionClipboard(profiles: movingSessions, roots: movingRoots.sorted(), folders: [], cut: true)
        do {
            let plan = try move.plan(profiles: profiles, folders: currentFolders, destination: destination)
            try saveFolderChanges(plan.profiles, folders: plan.folders, mapping: plan.movedFolders)
            profiles = plan.profiles
            emptyFolders = plan.folders
            selectedFolder = destination
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func toggleFavorite(_ profile: SessionProfile) {
        guard !readOnly, let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profiles
        updated[index].favorite.toggle()
        persist(updated)
    }

    func duplicate(_ profile: SessionProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name += " Copy"
        copy.favorite = false
        copy.savePassword = false
        guard !readOnly else { return }
        guard persist(profiles + [copy]) else { return }
        selectedProfile = copy.id
        editing = ProfileDraft(copy)
    }

    func duplicateTab(_ connection: SSHConnection) {
        if connection.temporary {
            connect(connection.profile, manual: connection.manual, temporary: true)
        } else if let current = profiles.first(where: { $0.id == connection.profile.id }) {
            if !current.sameDestination(as: connection.profile) {
                guard confirm("Destination Changed", text: "Duplicate will connect to \(current.endpoint).") else { return }
            }
            connect(current, manual: connection.manual)
        } else { errorMessage = "The session profile was deleted." }
    }

    func reorderTabs(from source: UUID, to destination: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == source }),
              let to = tabs.firstIndex(where: { $0.id == destination }), from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    func saveTemporaryProfile(_ connection: SSHConnection) {
        guard connection.temporary else { return }
        var draft = connection.profile
        draft.id = UUID()
        draft.savePassword = false
        editing = ProfileDraft(new: draft)
    }

    func updateTemporaryTab(_ connection: SSHConnection, profile value: SessionProfile) throws {
        guard connection.temporary, let index = tabs.firstIndex(where: { $0.id == connection.id }) else {
            throw MutyError("Temporary session is no longer open.")
        }
        var updated = value
        updated.id = connection.profile.id
        updated.savePassword = false
        updated.credentialID = nil
        updated = try updated.validated()
        let original = connection.profile
        let transportChanged = updated.connectionType != original.connectionType ||
            updated.host != original.host || updated.port != original.port || updated.user != original.user ||
            updated.jumpHostID != original.jumpHostID || updated.authentication != original.authentication ||
            updated.keyID != original.keyID || updated.identityFile != original.identityFile ||
            updated.sshEnabled != original.sshEnabled || updated.sftpEnabled != original.sftpEnabled
        if transportChanged {
            guard confirmSessionSettings("Apply Session Settings?", text: "The current connection will restart with the updated settings.") else { return }
            connection.disconnect()
            let replacement = SSHConnection(profile: updated, manual: connection.manual, temporary: true,
                                            credentials: passwordStore, transferQueueID: connection.transferQueueID)
            replacement.tabName = connection.tabName
            tabs[index] = replacement
            selectedTab = replacement.id
        } else {
            connection.profile = updated
            connection.setTheme(updated.terminalTheme ?? UserDefaults.standard.string(forKey: "terminalTheme") ?? TerminalColorScheme.mutyDark.rawValue)
        }
    }

    @discardableResult
    private func persist(_ updated: [SessionProfile]) -> Bool {
        guard !readOnly else { return false }
        do {
            try store.save(updated, folders: emptyFolders)
            profiles = updated
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func normalizedFolder(_ value: String?) -> String? {
        SessionProfile.canonicalFolder(value)
    }

    func lockPasswordStorage() {
        tabs.forEach { $0.revokeAuthentication() }
        vault.lock()
    }

    private func preparePasswordStorage() throws {
        if passwordStore is VaultStore { try vault.ensureAvailable() }
    }

    func effectiveProfile(_ value: SessionProfile) throws -> SessionProfile {
        var profile = value
        if profile.connectionType == .ssh && profile.authentication == .password {
            if let id = profile.credentialID {
                try vault.ensureAvailable()
                let credential = try vault.credential(id)
                profile.user = credential.username; profile.savePassword = true
            } else if profile.savePassword && !vault.needsSetup { try preparePasswordStorage() }
        }
        return profile
    }

    func saveSharedCredential(_ credential: SavedCredential, excludingConnection: UUID? = nil) throws {
        guard !readOnly else { throw MutyError("Profiles are read-only.") }
        try vault.ensureAvailable()
        let credential = try credential.validated()
        let before = try vault.snapshot()
        let affected = Set(profiles.filter { $0.credentialID == credential.id }.map(\.id))
        var updated = profiles
        for index in updated.indices where affected.contains(updated[index].id) { updated[index].user = credential.username }
        try vault.saveCredential(credential)
        do { try store.save(updated, folders: emptyFolders) }
        catch {
            do { try vault.replace(before) }
            catch { throw MutyError("Session update and credential rollback failed. Check password storage before retrying.") }
            throw error
        }
        tabs.filter { $0.id != excludingConnection && (affected.contains($0.profile.id) || $0.profile.jumpHostID.map(affected.contains) == true) }.forEach { $0.revokeAuthentication() }
        profiles = updated
    }

    func deleteSharedCredential(_ id: UUID) {
        guard !readOnly else { errorMessage = "Profiles are read-only; credential references cannot be verified."; return }
        let dependents = profiles.filter { $0.credentialID == id }
        guard dependents.isEmpty else {
            errorMessage = "Credential is used by: " + dependents.map(\.name).joined(separator: ", ") + ". Unlink these sessions first."
            return
        }
        guard confirm("Delete Shared Credential?", text: "The saved username and password will be removed.", action: "Delete") else { return }
        do { try vault.ensureAvailable(); try vault.deleteCredential(id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func saveAuthenticatedPassword(for original: SessionProfile, secret: String, connectionID: UUID) throws {
        guard var current = profiles.first(where: { $0.id == original.id }),
              current.credentialID == original.credentialID,
              try effectiveProfile(current).sameDestination(as: original) else { throw MutyError("Session settings changed.") }
        if let id = current.credentialID {
            var credential = try vault.credential(id)
            let count = profiles.filter { $0.credentialID == id }.count
            guard confirm("Update Shared Password?", text: "This changes \(credential.title) for \(count) linked sessions.", action: "Update") else { return }
            credential.password = secret
            try saveSharedCredential(credential, excludingConnection: connectionID)
        } else {
            current.authentication = .password; current.savePassword = true
            try save(current, password: secret, reuse: false, revokeActiveAuthentication: false)
        }
    }

    private func configurePasswordSaving(_ connection: SSHConnection) {
        let connectionID = connection.id
        connection.resolveJumpProfile = { [weak self] id in
            guard let self, let node = self.profiles.first(where: { $0.id == id }) else { throw MutyError("Jump host was deleted. Select another session.") }
            return try self.effectiveProfile(node)
        }
        connection.onSaveJumpPassword = { [weak self] original, secret in
            try self?.saveAuthenticatedPassword(for: original, secret: secret, connectionID: connectionID)
        }
        guard !connection.temporary else { return }
        let original = connection.profile
        connection.onSavePassword = { [weak self] secret in
            try self?.saveAuthenticatedPassword(for: original, secret: secret, connectionID: connectionID)
        }
    }

    func connect(_ value: SessionProfile, manual: Bool = false, temporary: Bool = false, promptForPassword: Bool = false) {
        let profile: SessionProfile
        do { profile = try effectiveProfile(value) }
        catch { errorMessage = error.localizedDescription; return }
        let connection = SSHConnection(profile: profile, manual: manual, temporary: temporary, credentials: passwordStore, ignoreSavedPassword: promptForPassword)
        configurePasswordSaving(connection)
        tabs.append(connection); selectTab(connection.id)
    }

    func close(_ connection: SSHConnection) {
        guard !connection.running || confirm("Close Connection?", text: connection.profile.endpoint) else { return }
        connection.disconnect()
        let index = tabs.firstIndex { $0.id == connection.id } ?? 0
        tabs.removeAll { $0.id == connection.id }
        splitSlots = splitSlots.map { $0 == connection.id ? nil : $0 }
        if splitMode != "none", !splitSlots.contains(where: { $0 != nil }) { split("none") }
        if selectedTab == connection.id { selectedTab = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }

    func reconnect(_ connection: SSHConnection, manual: Bool = false, promptForPassword: Bool = false) {
        guard let saved = connection.temporary ? connection.profile : profiles.first(where: { $0.id == connection.profile.id }) else {
            errorMessage = "The session profile was deleted. Create a new connection."; return
        }
        let latest: SessionProfile
        let jump: SessionProfile?
        do {
            latest = try effectiveProfile(saved)
            jump = try latest.jumpHostID.map { id in
                guard let profile = profiles.first(where: { $0.id == id }) else {
                    throw MutyError("Jump host was deleted. Select another session.")
                }
                return try effectiveProfile(profile)
            }
        }
        catch { errorMessage = error.localizedDescription; return }
        let jumpChanged = jump.map { current in
            connection.connectedJumpProfile.map { !current.sameDestination(as: $0) } ?? false
        } ?? false
        let destinationChanged = !latest.sameDestination(as: connection.profile) || jumpChanged
        if destinationChanged {
            let route = jump.map { " via " + $0.endpoint } ?? ""
            guard confirm("Destination Changed", text: "New destination: \(latest.endpoint)\(route). Pending transfers from the previous connection will not resume.") else { return }
        } else if connection.running {
            guard confirm("Reconnect?", text: "The current connection will be closed.") else { return }
        }
        guard let index = tabs.firstIndex(where: { $0.id == connection.id }) else { return }
        connection.disconnect()
        let replacement = SSHConnection(profile: latest, manual: manual || connection.manual, temporary: connection.temporary, credentials: passwordStore, ignoreSavedPassword: promptForPassword || connection.ignoreSavedPassword, transferQueueID: destinationChanged ? UUID() : connection.transferQueueID)
        configurePasswordSaving(replacement)
        replacement.tabName = connection.tabName
        splitSlots = splitSlots.map { $0 == connection.id ? replacement.id : $0 }
        tabs[index] = replacement; selectedTab = replacement.id
    }

    func forgetBulkSavedPasswords(_ request: BulkEditRequest) throws {
        guard !readOnly else { throw MutyError("Profiles are read-only.") }
        guard !request.profiles.isEmpty,
              request.profiles.allSatisfy({ profiles.contains($0) }) else {
            throw MutyError("Sessions changed. Close and reopen Bulk Edit.")
        }
        let affected = request.profiles.filter { $0.connectionType == .ssh }
        guard !affected.isEmpty else { throw MutyError("No SSH sessions selected.") }
        let ids = Set(affected.map(\.id))
        let passwordProfiles = affected.filter { $0.savePassword }
        var secrets: [UUID: String] = [:]
        if !passwordProfiles.isEmpty {
            try preparePasswordStorage()
            for profile in passwordProfiles {
                secrets[profile.id] = try passwordStore.read(id: profile.id)
            }
        }
        var updated = profiles
        for index in updated.indices where ids.contains(updated[index].id) {
            updated[index].savePassword = false
            updated[index].credentialID = nil
        }
        tabs.filter { ids.contains($0.profile.id) || $0.profile.jumpHostID.map(ids.contains) == true }
            .forEach { $0.revokeAuthentication() }
        var deleted: [SessionProfile] = []
        do {
            for profile in passwordProfiles {
                try passwordStore.delete(id: profile.id)
                deleted.append(profile)
            }
            try store.save(updated, folders: emptyFolders)
        } catch {
            let originalError = error
            var rollbackFailed = false
            for profile in deleted {
                guard let secret = secrets[profile.id] else { continue }
                do { try passwordStore.write(id: profile.id, password: secret, name: profile.name, endpoint: profile.endpoint) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed { throw MutyError("Password deletion rollback failed. Check saved passwords for the selected sessions.") }
            throw originalError
        }
        profiles = updated
    }

    @discardableResult
    func forgetSavedPassword(_ value: SessionProfile) -> Bool {
        guard !readOnly, let index = profiles.firstIndex(where: { $0.id == value.id }) else { return false }
        let profile = profiles[index]
        if profile.credentialID != nil {
            guard confirm("Unlink Shared Credential?", text: "The shared credential will be kept. This session will ask for its own password.", action: "Unlink") else { return false }
            var updated = profiles; updated[index].credentialID = nil; updated[index].savePassword = false
            do {
                try store.save(updated, folders: emptyFolders)
                tabs.filter { $0.profile.id == profile.id }.forEach { $0.revokeAuthentication() }
                profiles = updated; return true
            } catch { errorMessage = error.localizedDescription; return false }
        }
        guard confirm("Forget Saved Password?", text: profile.name + "\n" + profile.endpoint + "\n\nThe next connection will ask for a password.", action: "Forget Password") else { return false }
        do {
            try preparePasswordStorage()
            let secret = try passwordStore.read(id: profile.id)
            tabs.filter { $0.profile.id == profile.id || $0.profile.jumpHostID == profile.id }.forEach { $0.revokeAuthentication() }
            try passwordStore.delete(id: profile.id)
            var updated = profiles; updated[index].savePassword = false
            do { try store.save(updated, folders: emptyFolders) }
            catch {
                do {
                    if let secret { try passwordStore.write(id: profile.id, password: secret, name: profile.name, endpoint: profile.endpoint) }
                } catch { throw MutyError("Password deletion and rollback failed. Re-enter the password for " + profile.endpoint) }
                throw error
            }
            profiles = updated
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private(set) var deletingSessionItems = false

    func deleteSelectedItems(_ rows: Set<SessionRowID>) {
        guard !readOnly else { return }
        deletingSessionItems = true
        defer { deletingSessionItems = false }
        let selectedIDs = Set(rows.compactMap(\.profileID))
        let folderRows = rows.filter { $0.location == .folder }
        let includesRoot = folderRows.contains { $0.folderPath == nil }
        let paths = folderRows.compactMap(\.folderPath)
        func inSelectedFolder(_ path: String?) -> Bool {
            if includesRoot { return true }
            guard let path else { return false }
            return paths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        let affected = profiles.filter { selectedIDs.contains($0.id) || inSelectedFolder($0.folder) }
        let ids = Set(affected.map(\.id))
        let removedFolders = folders.filter { inSelectedFolder($0) }
        guard !affected.isEmpty || !removedFolders.isEmpty else { return }
        let dependents = profiles.filter { !ids.contains($0.id) && $0.jumpHostID.map(ids.contains) == true }
        guard dependents.isEmpty else {
            errorMessage = "Selected jump hosts are used by sessions outside the selection: "
                + dependents.map(\.name).joined(separator: ", ") + ". Change their Jump Host first."
            return
        }
        let names = affected.prefix(10).map { profile in
            (profile.folder.map { $0 + "/" } ?? "") + profile.name
        }.joined(separator: "\n")
        guard confirm("Delete Selected Items?",
            text: "\(affected.count) sessions and \(removedFolders.count) folders will be deleted, including saved passwords.\n\n"
                + names + (affected.count > 10 ? "\n…" : "")
                + "\n\nActive connections stay open. This cannot be undone.", action: "Delete") else { return }
        let keptFolders = folders.filter { !inSelectedFolder($0) }
        let updated = profiles.filter { !ids.contains($0.id) }
        var originals: [(SessionProfile, String?)] = []
        var changed: [(SessionProfile, String?)] = []
        do {
            if !vault.needsSetup { try preparePasswordStorage() }
            // Read all originals before any deletion so a denied password storage request changes nothing.
            for profile in affected where profile.connectionType == .ssh {
                originals.append((profile, try passwordStore.read(id: profile.id)))
            }
            tabs.filter { ids.contains($0.profile.id) || $0.profile.jumpHostID.map(ids.contains) == true }
                .forEach { $0.revokeAuthentication() }
            do {
                for original in originals {
                    changed.append(original)
                    try passwordStore.delete(id: original.0.id)
                }
                try store.save(updated, folders: keptFolders)
            } catch {
                let failure = error
                var failed: [String] = []
                for (profile, secret) in changed.reversed() {
                    guard let secret else { continue }
                    do { try passwordStore.write(id: profile.id, password: secret, name: profile.name, endpoint: profile.endpoint) }
                    catch { failed.append(profile.endpoint) }
                }
                if !failed.isEmpty {
                    throw MutyError("Deletion failed; profiles were kept. Could not restore passwords for: " + failed.joined(separator: ", "))
                }
                throw failure
            }
            profiles = updated; emptyFolders = keptFolders
            if selectedProfile.map(ids.contains) == true { selectedProfile = nil }
            if inSelectedFolder(selectedFolder) { selectedFolder = nil }
            persistWorkspace()
            operationStatus = "Deleted \(affected.count) sessions and \(removedFolders.count) folders."
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ p: SessionProfile) {
        deletingSessionItems = true
        defer { deletingSessionItems = false }
        let dependent = profiles.filter { $0.jumpHostID == p.id }
        guard dependent.isEmpty else {
            errorMessage = "This jump host is used by: " + dependent.map(\.name).joined(separator: ", ") + ". Change Connect via in these sessions first."
            return
        }
        guard !readOnly, confirm("Delete “\(p.name)”?", text: "The profile and its saved password will be deleted.") else { return }
        let active = tabs.filter { $0.profile.id == p.id && $0.running }
        let closeActive = !active.isEmpty && confirm("Close Active Connections?", text: "You can leave active connections open after deleting the profile.", action: "Close", cancel: "Keep Open")
        do {
            if !vault.needsSetup { try preparePasswordStorage() }
            let secret = try passwordStore.read(id: p.id)
            tabs.filter { $0.profile.id == p.id || $0.profile.jumpHostID == p.id }.forEach { $0.revokeAuthentication() }
            try passwordStore.delete(id: p.id)
            let updated = profiles.filter { $0.id != p.id }
            do { try store.save(updated, folders: emptyFolders) }
            catch {
                do {
                    if let secret { try passwordStore.write(id: p.id, password: secret, name: p.name, endpoint: p.endpoint) }
                } catch {
                    throw MutyError("Profile deletion and password storage rollback failed. The profile was kept; restore the password for item \(p.id).")
                }
                throw error
            }
            profiles = updated
            if selectedProfile == p.id { selectedProfile = nil }
            if closeActive { active.forEach { $0.disconnect() } }
        } catch { errorMessage = error.localizedDescription }
    }

    func shutdown(completion: @escaping () -> Void) {
        persistWorkspace()
        tabs.forEach { $0.disconnect() }
        vault.lock()
        SSHConnection.cleanup.notify(queue: .main, execute: completion)
    }

    func confirm(_ title: String, text: String, action: String = "Continue", cancel: String = "Cancel") -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text
        alert.addButton(withTitle: action); alert.addButton(withTitle: cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
