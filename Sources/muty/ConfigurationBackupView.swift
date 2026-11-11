import SwiftUI
import AppKit

extension AppModel {
    func chooseConfigurationImport(restoringBackup: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = restoringBackup ? "Restore Backup" : "Import Configuration"
        panel.prompt = restoringBackup ? "Open Backup" : "Import"
        panel.message = restoringBackup ? "Choose a muty backup. You can review sessions and passwords before restoring." : "Choose a muty configuration file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try await Task.detached { try BackupArchive.load(url) }.value
                let isEncrypted = try await Task.detached { try BackupArchive.encrypted(data) }.value
                NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.makeKeyAndOrderFront(nil)
                if isEncrypted { lockedBackup = LockedBackup(data: data, sourcePath: url.path) }
                else {
                    var document = try await Task.detached { try BackupArchive.decode(data) }.value
                    document.sourcePath = url.path
                    configurationImport = document
                }
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
    @StateObject private var log = BackupOperationLog()
    private var keys: [SSHKeyRecord] { model.keyLibrary.keys.filter { $0.pendingDeletion != true } }
    private var plan: ConfigurationRestorePlan {
        ConfigurationRestorePlan(backup: backup, existing: model.profiles, selected: selected, keyBindings: bindings, availableKeys: Set(keys.map(\.id)))
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
        Group {
            if log.started {
                BackupOperationLogView(log: log) { dismiss() }
            } else {
                options
            }
        }.interactiveDismissDisabled(log.running)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text((backup.restoredPasswords.isEmpty && backup.restoredCredentials.isEmpty) ? "Import muty Configuration" : "Restore muty Backup").font(.title2.bold())
            Text("\(plan.profiles.count) ready · \(plan.existingIDs.count) already exist · \(selected.count - plan.profiles.count - plan.existingIDs.count) need attention")
            Text("Existing session settings stay unchanged. Private keys are not imported. No connections will start.").font(.caption).foregroundStyle(.secondary)
            if !backup.restoredPasswords.isEmpty || !backup.restoredCredentials.isEmpty {
                Toggle("Restore passwords from backup", isOn: $restorePasswords)
                Text("Backup contains \(backup.restoredPasswords.count) session passwords and \(backup.restoredCredentials.count) shared credentials.")
                    .font(.caption).foregroundStyle(.secondary)
                if restorePasswords {
                    Toggle("Replace existing passwords", isOn: $replacePasswords)
                    Text("By default, existing password storage passwords are kept. Partial selection restores only shared credentials referenced by selected sessions. All credentials, including unused ones, are restored when all sessions are selected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let buttonBar = backup.buttonBar {
                Toggle("Restore Button Bar (\(buttonBar.sets.count) sets, \(buttonBar.buttons.count) buttons)", isOn: $restoreButtonBar)
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
                        if let note = plan.notes[entry.id] { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(.vertical, 3)
            }.frame(height: 300)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    do {
                        let summary = try model.importConfiguration(backup, selected: selected, keyBindings: bindings,
                            restorePasswords: restorePasswords, replacePasswords: replacePasswords,
                            restoreButtonBar: restoreButtonBar, previewOnly: true)
                        guard model.confirm("Restore Backup?", text: summary, action: "Restore") else { return }
                    } catch {
                        self.error = error.localizedDescription
                        return
                    }
                    log.start("Restore Backup", path: backup.sourcePath)
                    Task { @MainActor in
                        await Task.yield()
                        do {
                            try model.importConfiguration(backup, selected: selected, keyBindings: bindings,
                                restorePasswords: restorePasswords, replacePasswords: replacePasswords,
                                restoreButtonBar: restoreButtonBar, progress: { log.append($0) })
                            log.finish("Restore complete.")
                        } catch { log.fail(error) }
                    }
                }.disabled(model.readOnly || selected.count > plan.profiles.count + plan.existingIDs.count || (plan.profiles.isEmpty && backup.folders.isEmpty && !restoreButtonBar && (!restorePasswords || (backup.restoredPasswords.isEmpty && backup.restoredCredentials.isEmpty))))
            }
        }.padding(22).frame(width: 680)
    }
}
