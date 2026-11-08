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

    private var enabled: Bool {
        !request.profiles.isEmpty && (changeModes || changeUser || changeKey || changeJump || assignCredential)
        && (!changeUser || !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        && (!changeKey || UUID(uuidString: key) != nil)
        && (!assignCredential || (credentialID != nil && !changeKey && !changeUser))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bulk Edit Sessions").font(.title2)
            Text(LF("%@ · %ld SSH sessions, including subfolders", request.folder ?? L("Sessions"), request.profiles.count))
                .foregroundStyle(.secondary)
            Form {
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
            }.formStyle(.grouped)
            Text("Only checked fields change. Local Shell sessions are excluded. Active connections keep their current settings until reconnect.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(L(error)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply…") { confirming = true }.disabled(!enabled).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 510, height: 560)
        .confirmationDialog(LF("Apply changes to %ld SSH sessions?", request.profiles.count), isPresented: $confirming) {
            Button(LF("Apply to All %ld Sessions", request.profiles.count)) {
                do {
                    try model.applyBulkEdit(request, user: changeUser ? user : nil,
                        keyID: changeKey ? UUID(uuidString: key) : nil,
                        changeJump: changeJump, jumpID: UUID(uuidString: jump), credentialID: assignCredential ? credentialID : nil,
                        sshEnabled: changeModes ? sshEnabled : nil, sftpEnabled: changeModes ? sftpEnabled : nil)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
