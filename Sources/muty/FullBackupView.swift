import SwiftUI
import AppKit

extension AppModel {
    func beginFullBackupExport() {
        NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.makeKeyAndOrderFront(nil)
        fullBackupExport = true
    }
}

struct FullBackupExportView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var includePasswords = true
    @ViewState private var encrypted = false
    @ViewState private var password = ""
    @ViewState private var confirmation = ""
    @ViewState private var acknowledged = false
    @ViewState private var busy = false
    @ViewState private var error: String?
    private var ready: Bool {
        encrypted ? !password.isEmpty && password.utf8.count <= 1024 && password == confirmation : (!includePasswords || acknowledged)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Back Up").font(.title2)
            Toggle("Include passwords", isOn: $includePasswords)
            Text(includePasswords ? "Includes configuration, Button Bar, session passwords and shared credentials. Private keys are excluded." : "Includes sessions, folders and Button Bar. Passwords, shared credentials and private keys are excluded.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Button commands are included. Use encryption if commands contain sensitive values.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Encrypt with a master password", isOn: $encrypted)
            if encrypted {
                SecureField("Master password", text: $password)
                SecureField("Confirm master password", text: $confirmation)
                Text("Keep this password separately. Without it, the backup cannot be restored.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if includePasswords {
                Text("This file will contain readable SSH passwords. Anyone with access to it can read them.")
                    .foregroundStyle(.orange)
                Toggle("I understand: passwords will be saved without encryption", isOn: $acknowledged)
                    .font(.callout)
            }
            if busy { ProgressView(model.backupProgress ?? "Writing backup…") }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Save Backup…", action: export).keyboardShortcut(.defaultAction).disabled(busy || !ready)
            }
        }.padding(22).frame(width: 470)
        .disabled(busy).interactiveDismissDisabled(busy)
        .onChange(of: includePasswords) { _, _ in acknowledged = false }
        .onDisappear { password = ""; confirmation = "" }
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "muty-backup.mutybackup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; error = nil
        let master = encrypted ? password : nil
        Task { @MainActor in
            do {
                let backup = try await model.makeFullBackup(includePasswords: includePasswords)
                let count = backup.passwords.count + (backup.credentials?.count ?? 0)
                try await Task.detached {
                    let data = try BackupArchive.encode(backup, masterPassword: master)
                    try BackupArchive.write(data, to: url)
                }.value
                model.operationStatus = "Backup complete: \(backup.configuration.sessions.count) sessions and \(count) passwords saved to \(url.path)"
                password = ""; confirmation = ""; busy = false; dismiss()
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
}

struct BackupUnlockView: View {
    @ObservedObject var model: AppModel
    let backup: LockedBackup
    @Environment(\.dismiss) private var dismiss
    @ViewState private var password = ""
    @ViewState private var busy = false
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unlock Backup").font(.title2)
            SecureField("Master password", text: $password)
            if busy { ProgressView("Decrypting…") }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Unlock") {
                    busy = true; error = nil
                    let secret = password; let data = backup.data
                    Task { @MainActor in
                        do {
                            let document = try await Task.detached { try BackupArchive.decode(data, masterPassword: secret) }.value
                            password = ""; busy = false; dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.configurationImport = document }
                        } catch { self.error = error.localizedDescription; busy = false }
                    }
                }.keyboardShortcut(.defaultAction).disabled(busy || password.isEmpty || password.utf8.count > 1024)
            }
        }.padding(22).frame(width: 400)
        .disabled(busy).interactiveDismissDisabled(busy)
        .onDisappear { password = "" }
    }
}
