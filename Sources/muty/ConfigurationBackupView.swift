import SwiftUI
import AppKit

extension AppModel {
    func chooseConfigurationImport(restoringBackup: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = restoringBackup ? L("Restore Backup") : L("Import Configuration")
        panel.prompt = restoringBackup ? L("Open Backup") : L("Import")
        panel.message = restoringBackup ? L("Choose a muty backup. You can review sessions and passwords before restoring.") : L("Choose a muty configuration file.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try await Task.detached { try BackupArchive.load(url) }.value
                let isEncrypted = try await Task.detached { try BackupArchive.encrypted(data) }.value
                NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.makeKeyAndOrderFront(nil)
                if isEncrypted { lockedBackup = LockedBackup(data: data) }
                else { configurationImport = try await Task.detached { try BackupArchive.decode(data) }.value }
            }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

struct ConfigurationImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let backup: ConfigurationBackup
    @ViewState private var selected: Set<UUID>
    @ViewState private var bindings: [UUID: UUID]
    @ViewState private var restoreButtonBar = false
    @ViewState private var restorePasswords = true
    @ViewState private var replacePasswords = false
    @ViewState private var bulkKey: UUID?
    @ViewState private var error: String?
    private var keys: [SSHKeyRecord] { model.keyLibrary.keys.filter { $0.pendingDeletion != true } }
    private var plan: ConfigurationImportPlan {
        ConfigurationImportPlan(backup: backup, existing: model.profiles, selected: selected, keyBindings: bindings, availableKeys: Set(keys.map(\.id)))
    }
    init(model: AppModel, backup: ConfigurationBackup) {
        self.model = model; self.backup = backup
        _selected = State(initialValue: Set(backup.sessions.map(\.id)))
        var matches: [UUID: UUID] = [:]
        for entry in backup.sessions {
            if let fingerprint = entry.keyFingerprint, fingerprint.hasPrefix("SHA256:"),
               let key = model.keyLibrary.keys.first(where: { $0.fingerprint == fingerprint && $0.pendingDeletion != true }) {
                matches[entry.id] = key.id
            }
        }
        _bindings = State(initialValue: matches)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text((backup.restoredPasswords.isEmpty && backup.restoredCredentials.isEmpty) ? L("Import muty Configuration") : L("Restore muty Backup")).font(.title2.bold())
            Text(LF("%ld ready · %ld already exist · %ld need attention", plan.profiles.count, plan.existingIDs.count, selected.count - plan.profiles.count - plan.existingIDs.count))
            Text("Existing session settings stay unchanged. Private keys are not imported. No connections will start.").font(.caption).foregroundStyle(.secondary)
            if !backup.restoredPasswords.isEmpty || !backup.restoredCredentials.isEmpty {
                Toggle(LF("Restore passwords (%ld session passwords, %ld shared credentials)", backup.restoredPasswords.count, backup.restoredCredentials.count), isOn: $restorePasswords)
                if restorePasswords {
                    Toggle("Replace existing passwords", isOn: $replacePasswords)
                    Text("By default, existing password storage passwords are kept. Partial selection restores only shared credentials referenced by selected sessions. All credentials, including unused ones, are restored when all sessions are selected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let buttonBar = backup.buttonBar {
                Toggle(LF("Restore Button Bar (%ld sets, %ld buttons)", buttonBar.sets.count, buttonBar.buttons.count), isOn: $restoreButtonBar)
                Text("Replaces current button sets, commands and folder assignments.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Picker("Key for unmapped sessions", selection: $bulkKey) {
                    Text("Select a key").tag(nil as UUID?)
                    ForEach(keys) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("Apply") {
                    guard let bulkKey else { return }
                    for entry in backup.sessions where entry.authentication == .identityFile && bindings[entry.id] == nil { bindings[entry.id] = bulkKey }
                }.disabled(bulkKey == nil)
            }
            List(backup.sessions) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { selected.contains(entry.id) }, set: { if $0 { selected.insert(entry.id) } else { selected.remove(entry.id) } })) {
                        Text([entry.folder, entry.name].compactMap { $0 }.joined(separator: "/"))
                    }
                    if selected.contains(entry.id) {
                        if entry.authentication == .identityFile && !plan.existingIDs.contains(entry.id) {
                            Picker(entry.keyName ?? "SSH Key", selection: Binding<UUID?>(get: { bindings[entry.id] }, set: { bindings[entry.id] = $0 })) {
                                Text("Select a registered key").tag(nil as UUID?)
                                ForEach(keys) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                        if let note = plan.notes[entry.id] { Text(L(note)).font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(.vertical, 3)
            }.frame(height: 300)
            if let error { Text(L(error)).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    do {
                        if restorePasswords && (!backup.restoredPasswords.isEmpty || !backup.restoredCredentials.isEmpty) {
                            let count = backup.restoredPasswords.keys.filter { selected.contains($0) }.count + backup.restoredCredentials.count
                            guard model.confirm("Restore Saved Passwords?", text: "Up to \(count) passwords will be written to password storage. " + (replacePasswords ? "Existing passwords may be replaced." : "Existing passwords will be kept."), action: "Restore") else { return }
                        }
                        if restoreButtonBar {
                            guard model.confirm("Replace Button Bar?", text: "Current button sets, commands and folder assignments will be replaced by this backup.", action: "Replace") else { return }
                        }
                        try model.importConfiguration(backup, selected: selected, keyBindings: bindings,
                            restorePasswords: restorePasswords, replacePasswords: replacePasswords, restoreButtonBar: restoreButtonBar)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.disabled(model.readOnly || selected.count > plan.profiles.count + plan.existingIDs.count || (plan.profiles.isEmpty && backup.folders.isEmpty && !restoreButtonBar && (!restorePasswords || (backup.restoredPasswords.isEmpty && backup.restoredCredentials.isEmpty))))
            }
        }.padding(22).frame(width: 680)
    }
}
