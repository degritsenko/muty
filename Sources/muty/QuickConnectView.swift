import SwiftUI
import AppKit

struct QuickConnectView: View {
    let dismiss: () -> Void
    @ObservedObject var model: AppModel
    @ViewState private var connectionType = ConnectionType.ssh
    @ViewState private var sshEnabled = true
    @ViewState private var sftpEnabled = false
    @ViewState private var host = ""
    @ViewState private var port = "22"
    @ViewState private var user = ""
    @ViewState private var error: String?
    @ViewState private var authentication = AuthenticationMode.password
    @ViewState private var credentialID: UUID?
    @ViewState private var keyID: UUID?
    @ViewState private var identityFile: String?
    @FocusState private var usernameFocused: Bool

    private var connectionHint: String {
        if connectionType == .ssh, authentication == .password, credentialID == nil {
            return "Click Connect to enter the password when prompted. No profile or password is saved."
        }
        return "No profile is saved."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Quick Connect", systemImage: "bolt.horizontal").font(.title2.bold())
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        Text("Protocol").foregroundStyle(.secondary)
                        Picker("Protocol", selection: $connectionType) {
                            ForEach(ConnectionType.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden()
                    }
                    if connectionType == .ssh {
                        GridRow {
                            Text("Open").foregroundStyle(.secondary)
                            HStack(spacing: 20) {
                                Toggle("SSH", isOn: $sshEnabled).disabled(sshEnabled && !sftpEnabled)
                                Toggle("SFTP", isOn: $sftpEnabled).disabled(sftpEnabled && !sshEnabled)
                                Spacer()
                            }.toggleStyle(.checkbox).controlSize(.regular)
                        }
                        GridRow {
                            Text("Host").foregroundStyle(.secondary); TextField("Host", text: $host).accessibilityLabel("Host")
                        }
                        GridRow {
                            Text("Port").foregroundStyle(.secondary); TextField("Port", text: $port).accessibilityLabel("Port")
                        }
                        GridRow {
                            Text("Username").foregroundStyle(.secondary)
                            if authentication == .password, let credentialID {
                                Text(
                                    model.vault.credentials.first(where: { $0.id == credentialID })?.username
                                        ?? "Unlock credentials to view")
                            } else {
                                TextField("Username", text: $user)
                                    .focused($usernameFocused)
                                    .accessibilityLabel("Username")
                            }
                        }
                        GridRow {
                            Text("Authentication").foregroundStyle(.secondary)
                            Picker("Authentication", selection: $authentication) {
                                ForEach(AuthenticationMode.selectable) { Text($0.title).tag($0) }
                            }.labelsHidden()
                        }
                        if authentication == .password {
                            GridRow {
                                Text("Credentials").foregroundStyle(.secondary)
                                CredentialSelectionView(
                                    vault: model.vault, credentialID: $credentialID,
                                    sessionCredentialsTitle: "Enter password when prompted"
                                )
                                .labelsHidden()
                            }
                        } else if authentication == .identityFile {
                            GridRow {
                                Text("SSH Key").foregroundStyle(.secondary)
                                Picker("SSH Key", selection: $keyID) {
                                    Text(identityFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Select a key")
                                        .tag(nil as UUID?)
                                    ForEach(model.keyLibrary.keys) { key in
                                        Text(key.name).tag(Optional(key.id))
                                    }
                                }
                                .pickerStyle(.menu).labelsHidden()
                                .onChange(of: keyID) { _, selectedKey in
                                    if selectedKey != nil { identityFile = nil }
                                    error = nil
                                }
                            }
                            GridRow {
                                Text("Key File").foregroundStyle(.secondary)
                                Button("Choose File…") { chooseKeyFile() }
                            }
                        }
                    } else {
                        Text("Starts your default login shell in your home directory.")
                            .gridCellColumns(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text(connectionHint)
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    do {
                        var profile = SessionProfile()
                        profile.connectionType = connectionType
                        profile.sshEnabled = sshEnabled; profile.sftpEnabled = sftpEnabled
                        if connectionType == .ssh {
                            guard let number = Int(port) else { throw MutyError("Enter a valid port.") }
                            let selectedUser: String
                            if authentication == .password, let credentialID {
                                try model.vault.ensureAvailable()
                                selectedUser = try model.vault.credential(credentialID).username
                            } else { selectedUser = user }
                            let address = try ConnectionAddress.parse(host, defaultUser: selectedUser, defaultPort: number)
                            if authentication == .password, credentialID != nil, address.user != selectedUser {
                                throw MutyError("The username in Host does not match the selected credential (\(selectedUser)).")
                            }
                            profile.host = address.host; profile.port = address.port; profile.user = address.user
                            profile.authentication = authentication
                            profile.credentialID = authentication == .password ? credentialID : nil
                            profile.keyID = keyID; profile.identityFile = identityFile
                            if authentication == .identityFile, keyID == nil, let identityFile {
                                try SSHKeyLibrary.validateConnectionKey(URL(fileURLWithPath: identityFile))
                            }
                        }
                        model.connect(try profile.validated(), temporary: true)
                        dismiss()
                    } catch SessionProfile.ValidationError.missingUsername {
                        self.error = SessionProfile.ValidationError.missingUsername.localizedDescription
                        usernameFocused = true
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(minWidth: 480, minHeight: 460)
    }

    private func chooseKeyFile() {
        guard let window = NSApp.modalWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a private SSH key for this connection. It will not be added to the key library."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let file = panel.url else { return }
            do {
                try SSHKeyLibrary.validateConnectionKey(file)
                identityFile = file.path
                keyID = nil
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

}
