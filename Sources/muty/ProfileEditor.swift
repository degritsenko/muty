import SwiftUI

struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @ObservedObject private var buttonStore = SendStringButtonStore.shared
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

    private func selectDefaultKey() {
        if profile.authentication.supportsKey && profile.keyID == nil && profile.identityFile == nil {
            profile.keyID = model.keyLibrary.keys.first(where: { $0.pendingDeletion != true })?.id
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        Text("Protocol").foregroundStyle(.secondary)
                        Picker("Protocol", selection: $profile.connectionType) {
                            ForEach(ConnectionType.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Name").foregroundStyle(.secondary);
                        TextField("Name", text: $profile.name).accessibilityLabel("Name")
                    }
                    GridRow {
                        Text(""); Toggle("Favorite", isOn: $profile.favorite)
                    }
                    GridRow {
                        Text("Session Color").foregroundStyle(.secondary)
                        Picker(
                            "Session Color",
                            selection: Binding(get: { profile.color ?? "" }, set: { profile.color = $0.isEmpty ? nil : $0 })
                        ) {
                            Text("Default").tag("")
                            ForEach(["Red", "Orange", "Yellow", "Green", "Blue", "Purple"], id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Session Icon").foregroundStyle(.secondary)
                        Picker("Session Icon", selection: Binding(
                            get: { profile.icon ?? "" },
                            set: { profile.icon = $0.isEmpty ? nil : $0 }
                        )) {
                            Label("Default", systemImage: "desktopcomputer").tag("")
                            ForEach(SessionIcon.allCases) { icon in
                                Label { Text(icon.title) } icon: { CatalogIconView.image(icon.rawValue, fallback: "desktopcomputer") }.tag(icon.rawValue)
                            }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Button Bar").foregroundStyle(.secondary)
                        Picker("Button Bar", selection: Binding(
                            get: { profile.buttonBarSet ?? "inherit" },
                            set: { profile.buttonBarSet = $0 == "inherit" ? nil : $0 }
                        )) {
                            Text("Inherit from Folder").tag("inherit")
                            Text("Default").tag("")
                            if let value = profile.buttonBarSet, !value.isEmpty,
                               !buttonStore.document.sets.contains(where: { $0.id.uuidString == value }) {
                                Text("Unavailable").tag(value)
                            }
                            ForEach(buttonStore.document.sets) { item in Text(item.name).tag(item.id.uuidString) }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Terminal Theme").foregroundStyle(.secondary)
                        Picker(
                            "Terminal Theme",
                            selection: Binding(
                                get: { profile.terminalTheme ?? "" }, set: { profile.terminalTheme = $0.isEmpty ? nil : $0 })
                        ) {
                            Text("Inherit from Settings").tag("")
                            ForEach(TerminalColorScheme.allCases) { Text($0.name).tag($0.rawValue) }
                        }.labelsHidden()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.vertical, 4)
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
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Connection").font(.headline)
                                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                                    GridRow {
                                        Text("Host / IP").foregroundStyle(.secondary);
                                        TextField("Host / IP", text: $profile.host).accessibilityLabel("Host / IP")
                                    }
                                    GridRow {
                                        Text("Port").foregroundStyle(.secondary);
                                        TextField("Port", text: $port).accessibilityLabel("Port")
                                    }
                                    GridRow {
                                        Text("Jump Host").foregroundStyle(.secondary);
                                        JumpHostPicker(profile: $profile, profiles: model.profiles).labelsHidden()
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text("Authentication").font(.headline)
                                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                                    GridRow {
                                        Text("Method").foregroundStyle(.secondary)
                                        Picker("Method", selection: $profile.authentication) {
                                            ForEach(AuthenticationMode.selectable) { Text($0.title).tag($0) }
                                        }.labelsHidden()
                                    }
                                    if profile.authentication.supportsKey && profile.authentication.supportsPassword {
                                        GridRow {
                                            Text("SSH Key").foregroundStyle(.secondary)
                                            KeySelectionView(library: model.keyLibrary, keyID: $profile.keyID,
                                                             legacyPath: $profile.identityFile).labelsHidden()
                                        }
                                    }
                                    if profile.authentication.supportsPassword {
                                        GridRow {
                                            Text("Credentials").foregroundStyle(.secondary)
                                            CredentialSelectionView(vault: model.vault, credentialID: $profile.credentialID)
                                                .labelsHidden()
                                        }
                                        if profile.credentialID != nil {
                                            GridRow {
                                                Text("Username").foregroundStyle(.secondary)
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(
                                                        model.vault.credentials.first(where: { $0.id == profile.credentialID })?
                                                            .username ?? profile.user)
                                                    Text("Provided by selected credential")
                                                        .font(.caption).foregroundStyle(.secondary)
                                                }
                                            }
                                        } else {
                                            GridRow {
                                                Text("Username").foregroundStyle(.secondary);
                                                TextField("Username", text: $profile.user).accessibilityLabel("Username")
                                            }
                                        }
                                        if profile.credentialID != nil || profile.savePassword {
                                            GridRow {
                                                Text("Password").foregroundStyle(.secondary)
                                                SavedPasswordView(
                                                    vault: model.vault, passwordID: profile.credentialID ?? profile.id
                                                )
                                                .id(profile.credentialID ?? profile.id)
                                                .labelsHidden()
                                            }
                                        }
                                        if profile.credentialID == nil {
                                            if let original = draft.original, profile.savePassword {
                                                GridRow {
                                                    Text("");
                                                    HStack {
                                                        Button("Forget Saved Password…") {
                                                            if model.forgetSavedPassword(original) {
                                                                profile.savePassword = false
                                                            }
                                                        }.disabled(model.readOnly)
                                                    }
                                                }
                                            } else {
                                                GridRow {
                                                    Text("Password").foregroundStyle(.secondary); Text("Ask when connecting")
                                                }
                                            }
                                        }
                                    }
                                    if profile.authentication.supportsKey {
                                        if !profile.authentication.supportsPassword {
                                        GridRow {
                                            Text("Username").foregroundStyle(.secondary);
                                            TextField("Username", text: $profile.user).accessibilityLabel("Username")
                                        }
                                        }
                                        if !profile.authentication.supportsPassword {
                                        GridRow {
                                            Text("SSH Key").foregroundStyle(.secondary);
                                            KeySelectionView(
                                                library: model.keyLibrary, keyID: $profile.keyID,
                                                legacyPath: $profile.identityFile
                                            ).labelsHidden()
                                        }
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if profile.authentication.supportsKey {
                                    Divider().padding(.vertical, 4)
                                    Toggle("Enable X11 forwarding (-Y)", isOn: $profile.x11Forwarding)
                                    Text("Requires a running X11 server. Remote applications receive trusted access to your X server.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .topLeading).padding(.vertical, 4)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                        if !updated.authentication.supportsPassword || changed { updated.savePassword = false }
                        if !updated.authentication.supportsPassword { updated.credentialID = nil }
                        if !updated.authentication.supportsKey { updated.keyID = nil; updated.identityFile = nil }
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
        }.padding(22).frame(minWidth: 760, idealWidth: 820, minHeight: 440, idealHeight: 530)
        .onChange(of: profile.connectionType) { _, _ in page = "General"; error = nil; profile.savePassword = false }
        .onAppear { selectDefaultKey() }
        .onChange(of: profile.authentication) { _, _ in error = nil; selectDefaultKey() }
    }
}
