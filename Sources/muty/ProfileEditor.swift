import SwiftUI

struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let draft: ProfileDraft
    @ViewState private var profile: SessionProfile
    @ViewState private var port: String
    @ViewState private var page = "General"
    @ViewState private var error: String?

    init(model: AppModel, draft: ProfileDraft) {
        self.model = model; self.draft = draft
        var initial = draft.profile
        if initial.authentication == .agent || initial.authentication == .automatic {
            initial.authentication = (initial.keyID != nil || !(initial.identityFile ?? "").isEmpty) ? .identityFile : .password
        }
        if draft.original == nil && initial.folder == nil { initial.folder = model.selectedFolder }
        _profile = State(initialValue: initial)
        _port = State(initialValue: String(initial.port))
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker("Protocol", selection: $profile.connectionType) {
                    ForEach(ConnectionType.allCases) { Text($0.title).tag($0) }
                }
                TextField("Name", text: $profile.name)
                Toggle("Favorite", isOn: $profile.favorite)
                Picker("Session Color", selection: Binding(get: { profile.color ?? "" }, set: { profile.color = $0.isEmpty ? nil : $0 })) {
                    Text("Default").tag("")
                    ForEach(["Red", "Orange", "Yellow", "Green", "Blue", "Purple"], id: \.self) { Text($0).tag($0) }
                }
            }.formStyle(.grouped).frame(height: 185)
            if profile.connectionType == .ssh && !profile.tunnelOnly {
                HStack(spacing: 20) {
                    Text("Open:")
                    Toggle("SSH", isOn: $profile.sshEnabled).disabled(profile.sshEnabled && !profile.sftpEnabled)
                    Toggle("SFTP", isOn: $profile.sftpEnabled).disabled(profile.sftpEnabled && !profile.sshEnabled)
                    Spacer()
                }.toggleStyle(.switch).controlSize(.small)
            }
            if profile.connectionType == .localShell {
                Text("Starts your default login shell in your home directory.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 5) {
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $profile.description)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    .accessibilityLabel("Description")
            }.frame(height: 70)

        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.original == nil ? "New Session" : "Session Settings — " + draft.profile.name).font(.title2.bold())
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(profile.connectionType == .ssh ? ["General", "SSH", "Port Forwarding"] : ["General"], id: \.self) { item in
                        Button { page = item } label: {
                            Text(item).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                .background(page == item ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }.frame(width: 145)
                Divider()
                if page == "Port Forwarding" && profile.connectionType == .ssh {
                    ForwardingSettingsView(profile: $profile)
                } else {
                    if page == "General" || profile.connectionType == .localShell {
                        generalSettings
                    } else {
                        Form {
                            Section("Connection") {
                                TextField("Host / IP", text: $profile.host)
                                TextField("Port", text: $port)
                                TextField("Username", text: $profile.user)
                                    .disabled(profile.authentication == .password && profile.credentialID != nil)
                                JumpHostPicker(profile: $profile, profiles: model.profiles)
                            }
                            Section("Authentication") {
                                Picker("Method", selection: $profile.authentication) {
                                    ForEach(AuthenticationMode.selectable) { Text($0.title).tag($0) }
                                }
                                if profile.authentication == .password {
                                    CredentialSelectionView(vault: model.vault, credentialID: $profile.credentialID)
                                    if profile.credentialID == nil {
                                        if let original = draft.original, profile.savePassword {
                                            LabeledContent("Password saved in muty") {
                                                Button("Forget Saved Password…") {
                                                    if model.forgetSavedPassword(original) { profile.savePassword = false }
                                                }.disabled(model.readOnly)
                                            }
                                        } else {
                                            Text("Password will be requested when connecting.")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                } else if profile.authentication == .identityFile {
                                    KeySelectionView(library: model.keyLibrary, keyID: $profile.keyID, legacyPath: $profile.identityFile)
                                }
                            }
                        }.formStyle(.grouped)
                    }
                }
            }.frame(height: 430)
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Text("Changes apply on the next connection.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        var updated = profile
                        if updated.connectionType == .ssh {
                            guard let number = Int(port) else { page = "SSH"; throw MutyError("Enter a valid port.") }
                            updated.port = number
                        }
                        let changed = draft.original.map { !updated.sameDestination(as: $0) } ?? false
                        if updated.authentication != .password || changed { updated.savePassword = false }
                        if updated.authentication != .password { updated.credentialID = nil }
                        if updated.authentication != .identityFile { updated.keyID = nil; updated.identityFile = nil }
                        try model.save(updated, password: "", reuse: false)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 820)
        .onChange(of: profile.connectionType) { _, _ in page = "General"; error = nil; profile.savePassword = false }
        .onChange(of: profile.authentication) { _, _ in error = nil }
    }
}
