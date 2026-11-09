import SwiftUI
import AppKit

enum VaultAccessMode { case setup, unlock, change }

extension VaultStore {
    @MainActor func ensureAvailable() throws {
        if let loadError { throw MutyError("Password storage is unavailable: " + loadError) }
        if needsSetup || isLocked {
            guard showAccessDialog(mode: needsSetup ? .setup : .unlock) else { throw MutyError("Password storage was not unlocked.") }
        }
    }
    @MainActor @discardableResult func showAccessDialog(mode: VaultAccessMode) -> Bool {
        let panel = NativeVaultPanel(vault: self, mode: mode)
        defer { panel.clearSecrets() }
        return panel.run() == .OK
    }
}

struct CredentialsSettingsView: View {
    private struct Entry: Identifiable {
        let id: UUID
        let title: String
        let username: String
        let host: String
        let shared: Bool
    }
    @ObservedObject var model: AppModel
    @ObservedObject var vault: VaultStore
    @ViewState private var selected: UUID?
    @ViewState private var search = ""
    @ViewState private var filter = "All"
    @ViewState private var editing: SavedCredential?
    @ViewState private var editingSession: ProfileDraft?
    @ViewState private var error: String?

    private var entries: [Entry] {
        let savedIDs = vault.savedSessionIDs
        let shared = vault.credentials.map { Entry(id: $0.id, title: $0.title, username: $0.username, host: "", shared: true) }
        let sessions = model.profiles.filter { $0.credentialID == nil && savedIDs.contains($0.id) }
            .map { Entry(id: $0.id, title: $0.name, username: $0.user, host: $0.host, shared: false) }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (shared + sessions).filter { item in
            (filter == "All" || (filter == "Shared" ? item.shared : !item.shared)) &&
            (query.isEmpty || [item.title, item.username, item.host].contains { $0.localizedStandardContains(query) })
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        let visibleEntries = entries
        let selection = visibleEntries.first { $0.id == selected }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Credentials").font(.headline)
                Spacer()
                if vault.needsSetup || vault.isLocked {
                    Button(vault.needsSetup ? "Set Up…" : "Unlock…") { action { try vault.ensureAvailable() } }
                } else {
                    Label(vault.isProtected ? "Unlocked" : "Automatic unlock", systemImage: "lock.open")
                        .font(.body).foregroundStyle(vault.isProtected ? Color.secondary : Color.orange)
                    Menu {
                        Button("Change Master Password…") { _ = vault.showAccessDialog(mode: .change) }
                        if vault.isProtected {
                            Button("Disable Master Password…") {
                                guard model.confirm("Disable Master Password?",
                                    text: "Saved passwords will remain available with automatic unlock. Anyone who copies the vault file will be able to recover them.",
                                    action: "Disable") else { return }
                                action { try vault.changeProtection(masterPassword: nil) }
                            }.disabled(model.readOnly)
                            Divider()
                            Button("Lock") { model.lockPasswordStorage() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }.menuStyle(.borderlessButton).fixedSize()
                        .help("Password storage protection")
                }
            }
            if let problem = vault.loadError { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
            else if vault.needsSetup { Text("New local password storage. Existing Keychain passwords are not imported.").foregroundStyle(.secondary) }
            else if vault.isLocked { Text("Locked. Unlock to access saved credentials.").foregroundStyle(.secondary) }
            else {
                TextField("Search name, username or host", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("Show", selection: $filter) {
                    Text("All").tag("All")
                    Text("Shared").tag("Shared")
                    Text("Sessions").tag("Sessions")
                }.pickerStyle(.segmented).labelsHidden()
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(visibleEntries.count) entries").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                editing = SavedCredential(title: "", username: NSUserName(), password: "")
                            } label: {
                                Image(systemName: "plus")
                            }.buttonStyle(.borderless).disabled(model.readOnly)
                                .help("Add shared credential").accessibilityLabel("Add shared credential")
                        }
                        List(visibleEntries, selection: $selected) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.shared ? "person.2" : "terminal")
                                    .foregroundStyle(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).lineLimit(1)
                                    Text(item.shared ? item.username : "\(item.username)@\(item.host)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.padding(.vertical, 2).tag(item.id)
                        }.listStyle(.inset)
                        .overlay {
                            if visibleEntries.isEmpty {
                                Text(search.isEmpty ? "No saved credentials." : "No matches.")
                                    .foregroundStyle(.secondary).allowsHitTesting(false)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider().padding(.horizontal, 14)
                    VStack(alignment: .leading, spacing: 16) {
                        if let selection {
                            Label(selection.shared ? "Shared Credential" : "Session Password",
                                  systemImage: selection.shared ? "person.2" : "terminal")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(selection.title).font(.title3.bold()).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Username").font(.caption).foregroundStyle(.secondary)
                                Text(selection.username).textSelection(.enabled)
                            }
                            if !selection.shared {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Host").font(.caption).foregroundStyle(.secondary)
                                    Text(selection.host).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Divider()
                            SavedPasswordView(vault: vault, passwordID: selection.id).id(selection.id)
                            if selection.shared {
                                HStack {
                                    Button("Edit…") { action { editing = try vault.credential(selection.id) } }
                                    Button("Delete…") { model.deleteSharedCredential(selection.id) }
                                }.disabled(model.readOnly)
                            } else {
                                Button("Session Settings…") {
                                    if let profile = model.profiles.first(where: { $0.id == selection.id }) {
                                        editingSession = ProfileDraft(profile)
                                    }
                                }.disabled(model.readOnly)
                            }
                        } else {
                            Spacer()
                            Image(systemName: "key.horizontal").font(.largeTitle).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                            Text("Select an entry to view its saved password.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 250, alignment: .topLeading)
                }.frame(maxHeight: .infinity)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(16)
        .sheet(item: $editing) { CredentialEditor(model: model, credential: $0) }
        .sheet(item: $editingSession) { ProfileEditor(model: model, draft: $0) }
        .onChange(of: search) { _, _ in selected = nil }
        .onChange(of: filter) { _, _ in selected = nil }
        .onChange(of: vault.isLocked) { _, locked in
            if locked { selected = nil }
        }
    }
    private func action(_ work: () throws -> Void) { do { try work(); error = nil } catch { self.error = error.localizedDescription } }
}

private struct CredentialEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var value: SavedCredential
    @ViewState private var confirmation: String
    @ViewState private var error: String?
    init(model: AppModel, credential: SavedCredential) {
        self.model = model; _value = State(initialValue: credential); _confirmation = State(initialValue: credential.password)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shared Credential").font(.title2)
            TextField("Name", text: $value.title)
            TextField("Username", text: $value.username)
            SecureField("Password", text: $value.password)
            SecureField("Confirm password", text: $confirmation)
            Text("Changes apply to all linked sessions on their next connection.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try model.saveSharedCredential(value); dismiss() } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(value.password.isEmpty || value.password != confirmation)
            }
        }.padding(22).frame(width: 440)
        .onDisappear { value.password = ""; confirmation = "" }
    }
}

struct SavedPasswordView: View {
    @ObservedObject var vault: VaultStore
    let passwordID: UUID
    @ViewState private var revealedPassword: String?
    @ViewState private var error: String?

    private func hide() {
        revealedPassword = nil
    }

    var body: some View {
        LabeledContent("Password") {
            HStack {
                if let revealedPassword, !vault.isLocked {
                    Text(verbatim: revealedPassword).font(.body.monospaced())
                        .privacySensitive()
                } else {
                    Text("••••••••").accessibilityLabel("Saved password")
                }
                Button {
                    if revealedPassword != nil {
                        hide()
                    } else {
                        do {
                            try vault.ensureAvailable()
                            guard let password = try vault.read(id: passwordID) else {
                                throw MutyError("No saved password is available.")
                            }
                            revealedPassword = password
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: revealedPassword == nil ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .help(revealedPassword == nil ? "Show password" : "Hide password")
                .accessibilityLabel(revealedPassword == nil ? "Show password" : "Hide password")
            }
        }
        .task(id: revealedPassword) {
            guard revealedPassword != nil else { return }
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            hide()
        }
        .onChange(of: vault.isLocked) { _, locked in
            if locked { hide() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in hide() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in hide() }
        .onDisappear { hide() }
        .alert("Could Not Show Password", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

struct CredentialSelectionView: View {
    @ObservedObject var vault: VaultStore
    @Binding var credentialID: UUID?
    var sessionCredentialsTitle = "Session credentials"

    var body: some View {
        if vault.isLocked || vault.needsSetup {
            HStack {
                Text(credentialID == nil ? sessionCredentialsTitle : "Shared credential selected")
                Spacer()
                Button(vault.needsSetup ? "Set Up Credentials…" : "Unlock Credentials…") { try? vault.ensureAvailable() }
            }
        } else {
            Picker("Credentials", selection: $credentialID) {
                Text(sessionCredentialsTitle).tag(nil as UUID?)
                ForEach(vault.credentials) { Text($0.title).tag(Optional($0.id)) }
                if let credentialID, !vault.credentials.contains(where: { $0.id == credentialID }) { Text("Missing credential").tag(Optional(credentialID)) }
            }
        }
    }
}
