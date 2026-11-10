import SwiftUI

struct BulkEditRequest: Identifiable {
    let id = UUID()
    let folder: String?
    let profiles: [SessionProfile]
}

struct BulkSessionEditor: View {
    @ObservedObject var model: AppModel
    let request: BulkEditRequest
    @Environment(\.dismiss) private var dismiss
    @ViewState private var changeColor = false
    @ViewState private var color = ""
    @ViewState private var changeTheme = false
    @ViewState private var terminalTheme = ""
    @ViewState private var changeModes = false
    @ViewState private var sshEnabled = true
    @ViewState private var sftpEnabled = true
    @ViewState private var changeUser = false
    @ViewState private var user = ""
    @ViewState private var changeKey = false
    @ViewState private var key = ""
    @ViewState private var assignCredential = false
    @ViewState private var credentialID: UUID?
    @ViewState private var changeJump = false
    @ViewState private var jump = ""
    @ViewState private var error: String?
    @ViewState private var confirming = false
    @ViewState private var confirmingForget = false

    private var sshProfiles: [SessionProfile] { request.profiles.filter { $0.connectionType == .ssh } }
    private var sharedLinks: Int { sshProfiles.filter { $0.credentialID != nil }.count }
    private var hasSSH: Bool { request.profiles.contains { $0.connectionType == .ssh } }

    private var enabled: Bool {
        !request.profiles.isEmpty && ((hasSSH && (changeModes || changeUser || changeKey || changeJump || assignCredential)) || changeColor || changeTheme)
        && (!hasSSH || !changeUser || !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        && (!hasSSH || !changeKey || UUID(uuidString: key) != nil)
        && (!hasSSH || !assignCredential || (credentialID != nil && !changeKey && !changeUser))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bulk Edit Sessions").font(.title2)
            Text("\(request.folder ?? "Sessions") · \(request.profiles.count) sessions, including subfolders")
                .foregroundStyle(.secondary)
            Form {
                Toggle("Change Session Color", isOn: $changeColor)
                if changeColor {
                    Picker("Session Color", selection: $color) {
                        Text("Default").tag("")
                        ForEach(["Red", "Orange", "Yellow", "Green", "Blue", "Purple"], id: \.self) { Text($0).tag($0) }
                    }
                }
                Toggle("Change Terminal Theme", isOn: $changeTheme)
                if changeTheme {
                    Picker("Terminal Theme", selection: $terminalTheme) {
                        Text("Inherit from Settings").tag("")
                        ForEach(TerminalColorScheme.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                }
                Group {
                    Toggle("Change SSH / SFTP", isOn: $changeModes)
                    if changeModes {
                        HStack(spacing: 20) {
                            Toggle("SSH", isOn: $sshEnabled).disabled(sshEnabled && !sftpEnabled)
                            Toggle("SFTP", isOn: $sftpEnabled).disabled(sftpEnabled && !sshEnabled)
                        }.toggleStyle(.switch).controlSize(.small)
                    }
                    Toggle("Change username", isOn: $changeUser)
                    if changeUser { TextField("Username", text: $user) }
                    Toggle("Assign SSH key", isOn: $changeKey)
                    if changeKey {
                        Picker("SSH key", selection: $key) {
                            Text("Select a key").tag("")
                            ForEach(model.keyLibrary.keys.filter { $0.pendingDeletion != true }) { item in
                                Text(item.name).tag(item.id.uuidString)
                            }
                        }
                    }
                    Toggle("Assign shared credential", isOn: $assignCredential)
                    if assignCredential { CredentialSelectionView(vault: model.vault, credentialID: $credentialID) }
                    Toggle("Change Jump Host", isOn: $changeJump)
                    if changeJump {
                        Picker("Jump Host", selection: $jump) {
                            Text("None (direct connection)").tag("")
                            ForEach(model.profiles.filter { item in
                                item.connectionType == .ssh && item.jumpHostID == nil && !request.profiles.contains(where: { $0.id == item.id })
                            }) { item in Text(item.name).tag(item.id.uuidString) }
                        }
                    }
                }.disabled(!hasSSH)
            }.formStyle(.grouped)
            Text("Only checked fields change. Appearance applies to all selected sessions. Connection fields apply to SSH sessions only. Terminal themes apply immediately. Connection settings apply on reconnect.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Forget saved passwords…", role: .destructive) { confirmingForget = true }
                    .disabled(!hasSSH || model.readOnly)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply…") { confirming = true }.disabled(!enabled).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 510, height: 560)
        .confirmationDialog("Forget passwords for \(sshProfiles.count) SSH sessions?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget saved passwords", role: .destructive) {
                do {
                    try model.forgetBulkSavedPasswords(request)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("Delete saved session passwords, disable password saving and unlink \(sharedLinks) shared credential bindings. Shared credentials stay in the vault. Pending authentication is cancelled. Established SSH connections stay open. Other edits in this form are applied separately.")
        }
        .confirmationDialog("Apply changes to \(request.profiles.count) sessions?", isPresented: $confirming) {
            Button("Apply to All \(request.profiles.count) Sessions") {
                do {
                    try model.applyBulkEdit(request, user: hasSSH && changeUser ? user : nil,
                        keyID: hasSSH && changeKey ? UUID(uuidString: key) : nil,
                        changeJump: hasSSH && changeJump, jumpID: UUID(uuidString: jump), credentialID: hasSSH && assignCredential ? credentialID : nil,
                        sshEnabled: hasSSH && changeModes ? sshEnabled : nil, sftpEnabled: hasSSH && changeModes ? sftpEnabled : nil,
                        changeColor: changeColor, color: color.isEmpty ? nil : color,
                        changeTheme: changeTheme, terminalTheme: terminalTheme.isEmpty ? nil : terminalTheme)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
