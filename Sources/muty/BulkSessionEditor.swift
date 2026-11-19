import SwiftUI

struct BulkEditRequest: Identifiable {
    let id = UUID()
    let folder: String?
    let profiles: [SessionProfile]
    var includesSubfolders = true
}

struct BulkSessionEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var buttonStore = SendStringButtonStore.shared
    let request: BulkEditRequest
    @Environment(\.dismiss) private var dismiss
    @ViewState private var changeColor = false
    @ViewState private var color = ""
    @ViewState private var changeTheme = false
    @ViewState private var terminalTheme = ""
    @ViewState private var changeButtonBar = false
    @ViewState private var buttonBarSet = "mixed"
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
        !request.profiles.isEmpty && ((hasSSH && (changeModes || changeUser || changeKey || changeJump || assignCredential)) || changeColor || changeTheme || changeButtonBar)
        && (!changeButtonBar || buttonBarSet != "mixed")
        && (!hasSSH || !changeUser || !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        && (!hasSSH || !changeKey || UUID(uuidString: key) != nil)
        && (!hasSSH || !assignCredential || (credentialID != nil && !changeKey && !changeUser))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bulk Edit Sessions").font(.title2)
            Text("\(request.folder ?? "Sessions") · \(request.profiles.count) sessions\(request.includesSubfolders ? ", including subfolders" : "")")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                GridRow {
                    Toggle("Session Color", isOn: $changeColor)
                        Picker("Session Color", selection: $color) {
                            Text("Default").tag("")
                            ForEach(["Red", "Orange", "Yellow", "Green", "Blue", "Purple"], id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().disabled(!changeColor)
                }
                GridRow {
                    Toggle("Terminal Theme", isOn: $changeTheme)
                        Picker("Terminal Theme", selection: $terminalTheme) {
                            Text("Inherit from Settings").tag("")
                            ForEach(TerminalColorScheme.allCases) { Text($0.name).tag($0.rawValue) }
                        }.labelsHidden().disabled(!changeTheme)
                }
                GridRow {
                    Toggle("Button Bar", isOn: $changeButtonBar)
                    Picker("Button Bar", selection: $buttonBarSet) {
                        if buttonBarSet == "mixed" { Text("Multiple values").tag("mixed") }
                        Text("Inherit from Folder").tag("inherit")
                        Text("Default").tag("")
                        ForEach(buttonStore.document.sets) { item in
                            Text(item.name).tag(item.id.uuidString)
                        }
                    }.labelsHidden().disabled(!changeButtonBar)
                }
                Divider().gridCellColumns(2)
                GridRow {
                    Toggle("SSH / SFTP", isOn: $changeModes).disabled(!hasSSH)
                        HStack(spacing: 20) {
                            Toggle("SSH", isOn: $sshEnabled).disabled(sshEnabled && !sftpEnabled)
                            Toggle("SFTP", isOn: $sftpEnabled).disabled(sftpEnabled && !sshEnabled)
                        }.disabled(!hasSSH || !changeModes)
                }
                GridRow {
                    Toggle("Username", isOn: $changeUser).disabled(!hasSSH)
                    TextField("Username", text: $user).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Username").disabled(!hasSSH || !changeUser)
                }
                GridRow {
                    Toggle("SSH Key", isOn: $changeKey).disabled(!hasSSH)
                        Picker("SSH key", selection: $key) {
                            Text("Select a key").tag("")
                            ForEach(model.keyLibrary.keys.filter { $0.pendingDeletion != true }) { item in
                                Text(item.name).tag(item.id.uuidString)
                            }
                        }.labelsHidden().disabled(!hasSSH || !changeKey)
                }
                GridRow {
                    Toggle("Shared Credential", isOn: $assignCredential).disabled(!hasSSH)
                        CredentialSelectionView(vault: model.vault, credentialID: $credentialID)
                            .labelsHidden().disabled(!hasSSH || !assignCredential)
                }
                GridRow {
                    Toggle("Jump Host", isOn: $changeJump).disabled(!hasSSH)
                        Picker("Jump Host", selection: $jump) {
                            Text("None (direct connection)").tag("")
                            ForEach(model.profiles.filter { item in
                                item.connectionType == .ssh && item.jumpHostID == nil && !request.profiles.contains(where: { $0.id == item.id })
                            }) { item in Text(item.name).tag(item.id.uuidString) }
                        }.labelsHidden().disabled(!hasSSH || !changeJump)
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            Divider()
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
        }.padding(22).frame(width: 660)
        .onAppear {
            let values = Set(request.profiles.map { $0.buttonBarSet ?? "inherit" })
            buttonBarSet = values.count == 1 ? values.first! : "mixed"
        }
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
                        changeTheme: changeTheme, terminalTheme: terminalTheme.isEmpty ? nil : terminalTheme,
                        changeButtonBar: changeButtonBar, buttonBarSet: buttonBarSet == "inherit" ? nil : buttonBarSet)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
