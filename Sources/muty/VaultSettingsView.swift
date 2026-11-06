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
    @ObservedObject var model: AppModel
    @ObservedObject var vault: VaultStore
    @ViewState private var selected: UUID?
    @ViewState private var editing: SavedCredential?
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Password Storage").font(.headline)
                Spacer()
                if vault.needsSetup || vault.isLocked {
                    Button(vault.needsSetup ? "Set Up…" : "Unlock…") { action { try vault.ensureAvailable() } }
                } else {
                    Button("Change Protection…") { _ = vault.showAccessDialog(mode: .change) }
                    if vault.isProtected { Button("Lock") { model.lockPasswordStorage() } }
                }
            }
            if let problem = vault.loadError { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
            else if vault.needsSetup { Text("New local password storage. Existing Keychain passwords are not imported.").foregroundStyle(.secondary) }
            else if vault.isLocked { Text("Locked. Unlock to access saved credentials.").foregroundStyle(.secondary) }
            else {
                Text(vault.isProtected ? "Protected with a master password" : "Automatic unlock · weaker protection")
                    .font(.caption).foregroundStyle(vault.isProtected ? Color.secondary : Color.orange)
                Text("\(vault.sessionPasswordCount) session passwords · \(vault.credentials.count) shared credentials")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Shared Credentials").font(.headline)
                List(vault.credentials, selection: $selected) { item in
                    HStack { Text(item.title); Spacer(); Text(item.username).foregroundStyle(.secondary) }.tag(item.id)
                }
                HStack {
                    Button("Add…") { editing = SavedCredential(title: "", username: NSUserName(), password: "") }
                    Button("Edit…") { action { if let selected { editing = try vault.credential(selected) } } }.disabled(selected == nil)
                    Button("Delete…") { if let selected { model.deleteSharedCredential(selected) } }.disabled(selected == nil || model.readOnly)
                    Spacer()
                }
                Text("Link sessions to a shared credential in Session Settings → SSH. Editing a shared credential updates every linked session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Spacer(minLength: 0)
        }.padding(16)
        .sheet(item: $editing) { CredentialEditor(model: model, credential: $0) }
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

struct CredentialSelectionView: View {
    @ObservedObject var vault: VaultStore
    @Binding var credentialID: UUID?
    var body: some View {
        if vault.isLocked || vault.needsSetup {
            HStack {
                Text(credentialID == nil ? "Session-specific password" : "Shared credential selected")
                Spacer()
                Button(vault.needsSetup ? "Set Up Credentials…" : "Unlock Credentials…") { try? vault.ensureAvailable() }
            }
        } else {
            Picker("Credentials", selection: $credentialID) {
                Text("Session-specific password").tag(nil as UUID?)
                ForEach(vault.credentials) { Text($0.title + " · " + $0.username).tag(Optional($0.id)) }
                if let credentialID, !vault.credentials.contains(where: { $0.id == credentialID }) { Text("Missing credential").tag(Optional(credentialID)) }
            }
        }
    }
}
