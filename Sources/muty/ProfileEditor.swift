import SwiftUI

struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let draft: ProfileDraft
    var onSave: ((SessionProfile) throws -> Void)? = nil
    @ViewState private var profile: SessionProfile
    @ViewState private var port: String
    @ViewState private var page = "General"
    @ViewState private var error: String?

    init(model: AppModel, draft: ProfileDraft, onSave: ((SessionProfile) throws -> Void)? = nil) {
        self.model = model; self.draft = draft
        self.onSave = onSave
        var initial = draft.profile
        if initial.authentication == .agent || initial.authentication == .automatic {
            initial.authentication = (initial.keyID != nil || !(initial.identityFile ?? "").isEmpty) ? .identityFile : .password
        }
        if draft.original == nil && initial.folder == nil { initial.folder = model.selectedFolder }
        _profile = State(initialValue: initial)
        _port = State(initialValue: String(initial.port))
    }

    private var title: String {
        if draft.original == nil { return draft.fromTemporaryTab ? "Save as Session" : "New Session" }
        return (draft.fromTemporaryTab ? "Temporary Tab Settings — " : "Saved Session Settings — ") + draft.profile.name
    }

    private var saveHint: String {
        if draft.original == nil {
            return draft.fromTemporaryTab ? "Creates a saved profile. The current tab remains temporary." :
                "Creates a saved profile in Session Manager."
        }
        return draft.fromTemporaryTab ? "Connection changes require a restart. Colors and themes apply immediately." :
            "Connection changes apply on reconnect. Colors and themes apply immediately."
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
                Picker("Terminal Theme", selection: Binding(get: { profile.terminalTheme ?? "" }, set: { profile.terminalTheme = $0.isEmpty ? nil : $0 })) {
                    Text("Inherit from Settings").tag("")
                    ForEach(TerminalColorScheme.allCases) { Text($0.name).tag($0.rawValue) }
                }
            }.formStyle(.grouped).frame(height: 220)
            if profile.connectionType == .ssh && !profile.tunnelOnly {
                HStack(spacing: 20) {
                    Text("Open:")
                    Toggle("SSH", isOn: $profile.sshEnabled).disabled(profile.sshEnabled && !profile.sftpEnabled)
                    Toggle("SFTP", isOn: $profile.sftpEnabled).disabled(profile.sftpEnabled && !profile.sshEnabled)
                    Spacer()
                }.toggleStyle(.checkbox).controlSize(.regular)
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
            Text(title).font(.title2.bold())
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
                                JumpHostPicker(profile: $profile, profiles: model.profiles)
                            }
                            Section("Authentication") {
                                Picker("Method", selection: $profile.authentication) {
                                    ForEach(AuthenticationMode.selectable) { Text($0.title).tag($0) }
                                }
                                if profile.authentication == .password {
                                    CredentialSelectionView(vault: model.vault, credentialID: $profile.credentialID)
                                    if profile.credentialID != nil {
                                        LabeledContent("Username", value: model.vault.credentials.first(where: { $0.id == profile.credentialID })?.username ?? profile.user)
                                        Text("Provided by selected credential")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        TextField("Username", text: $profile.user)
                                    }
                                    if profile.credentialID != nil || profile.savePassword {
                                        SavedPasswordView(vault: model.vault, passwordID: profile.credentialID ?? profile.id)
                                            .id(profile.credentialID ?? profile.id)
                                    }
                                    if profile.credentialID == nil {
                                        if let original = draft.original, profile.savePassword {
                                            HStack {
                                                Button("Forget Saved Password…") {
                                                    if model.forgetSavedPassword(original) { profile.savePassword = false }
                                                }.disabled(model.readOnly)
                                            }
                                        } else {
                                            LabeledContent("Password", value: "Ask when connecting")
                                        }
                                    }
                                } else if profile.authentication == .identityFile {
                                    TextField("Username", text: $profile.user)
                                    KeySelectionView(library: model.keyLibrary, keyID: $profile.keyID, legacyPath: $profile.identityFile)
                                }
                            }
                        }.formStyle(.grouped)
                    }
                }
            }.frame(height: 430)
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Text(saveHint).font(.caption).foregroundStyle(.secondary)
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
                        if let onSave { try onSave(updated) }
                        else {
                            try model.save(updated, password: "", reuse: false)
                            if draft.fromTemporaryTab {
                                model.operationStatus = "Session saved. The current tab remains temporary."
                            }
                        }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 820)
        .onChange(of: profile.connectionType) { _, _ in page = "General"; error = nil; profile.savePassword = false }
        .onChange(of: profile.authentication) { _, _ in error = nil }
    }
}
