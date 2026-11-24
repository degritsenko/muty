import SwiftUI
import AppKit

struct QuickConnectView: View {
    let dismiss: () -> Void
    @ObservedObject var model: AppModel
    let presentingWindow: () -> NSWindow?
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
        if connectionType == .ssh, authentication.supportsPassword, credentialID == nil, !model.vault.isLocked {
            return "Select a saved credential to connect without entering a password, or leave it empty to enter one when prompted."
        }
        if connectionType == .ssh, authentication.supportsPassword, credentialID == nil {
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
                            if authentication.supportsPassword, let credentialID {
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
                        if authentication.supportsKey {
                            GridRow {
                                Text("SSH Key").foregroundStyle(.secondary)
                                KeySelectionView(
                                    library: model.keyLibrary, keyID: $keyID, legacyPath: $identityFile,
                                    presentingWindow: presentingWindow
                                )
                            }
                        }
                        if authentication.supportsPassword {
                            GridRow {
                                Text("Credentials").foregroundStyle(.secondary)
                                CredentialSelectionView(
                                    vault: model.vault, credentialID: $credentialID,
                                    sessionCredentialsTitle: "Select a saved credential",
                                    autoSelectOnlyCredential: true
                                )
                                .labelsHidden()
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
                            if authentication.supportsPassword, let credentialID {
                                try model.vault.ensureAvailable()
                                selectedUser = try model.vault.credential(credentialID).username
                            } else { selectedUser = user }
                            let address = try ConnectionAddress.parse(host, defaultUser: selectedUser, defaultPort: number)
                            if authentication.supportsPassword, credentialID != nil, address.user != selectedUser {
                                throw MutyError("The username in Host does not match the selected credential (\(selectedUser)).")
                            }
                            profile.host = address.host; profile.port = address.port; profile.user = address.user
                            profile.authentication = authentication
                            profile.credentialID = authentication.supportsPassword ? credentialID : nil
                            profile.keyID = keyID; profile.identityFile = identityFile
                            if authentication.supportsKey, keyID == nil, let identityFile {
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
        .onAppear { selectDefaultKey() }
        .onChange(of: authentication) { _, _ in selectDefaultKey() }
    }

    private func selectDefaultKey() {
        if authentication.supportsKey && keyID == nil && identityFile == nil {
            keyID = model.keyLibrary.keys.first(where: { $0.pendingDeletion != true })?.id
        }
    }


}
