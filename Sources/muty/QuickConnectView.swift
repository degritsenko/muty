import SwiftUI

struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @ViewState private var connectionType = ConnectionType.ssh
    @ViewState private var sshEnabled = true
    @ViewState private var sftpEnabled = false
    @ViewState private var host = ""
    @ViewState private var port = "22"
    @ViewState private var user = NSUserName()
    @ViewState private var error: String?
    @ViewState private var authentication = AuthenticationMode.password
    @ViewState private var credentialID: UUID?
    @ViewState private var keyID: UUID?
    @ViewState private var identityFile: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Quick Connect", systemImage: "bolt.horizontal").font(.title2.bold())
            Form {
                Picker("Protocol", selection: $connectionType) {
                    ForEach(ConnectionType.allCases) { Text(L($0.title)).tag($0) }
                }
                if connectionType == .ssh {
                    HStack(spacing: 20) {
                        Text("Open:")
                        Toggle("SSH", isOn: $sshEnabled).disabled(sshEnabled && !sftpEnabled)
                        Toggle("SFTP", isOn: $sftpEnabled).disabled(sftpEnabled && !sshEnabled)
                        Spacer()
                    }.toggleStyle(.switch).controlSize(.small)
                    TextField("Host or user@host:port", text: $host)
                    TextField("Port", text: $port)
                    TextField("Username", text: $user).disabled(credentialID != nil && authentication == .password)
                    if authentication == .password { CredentialSelectionView(vault: model.vault, credentialID: $credentialID) }
                    Picker("Authentication", selection: $authentication) {
                        ForEach(AuthenticationMode.selectable) { Text(L($0.title)).tag($0) }
                    }
                    if authentication == .identityFile {
                        KeySelectionView(library: model.keyLibrary, keyID: $keyID, legacyPath: $identityFile)
                    }
                } else {
                    Text("Starts your default login shell in your home directory.")
                }
            }.formStyle(.grouped).frame(maxHeight: 560)
            Text(connectionType == .ssh ? L("No profile or password is saved. Passwords and OTP are entered in the terminal; choose SSH Key to use a private key.") : L("No profile is saved."))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(L(error)).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
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
                            profile.host = address.host; profile.port = address.port; profile.user = address.user
                            profile.authentication = authentication
                            profile.credentialID = authentication == .password ? credentialID : nil
                            profile.keyID = keyID; profile.identityFile = identityFile
                        }
                        model.connect(try profile.validated(), temporary: true)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480)
    }
}
