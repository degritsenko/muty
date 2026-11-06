import SwiftUI
import AppKit

struct KeySelectionView: View {
    @ObservedObject var library: SSHKeyLibrary
    @Binding var keyID: UUID?
    @Binding var legacyPath: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("SSH Key", selection: $keyID) {
                Text(legacyPath == nil ? "Select a key" : "Existing file: \(URL(fileURLWithPath: legacyPath!).lastPathComponent)").tag(nil as UUID?)
                ForEach(library.keys) { key in Text(key.name).tag(Optional(key.id)) }
                if let keyID, !library.keys.contains(where: { $0.id == keyID }) {
                    Text("Missing key").tag(Optional(keyID))
                }
            }
            if let loadError = library.loadError {
                Text(loadError).foregroundStyle(.red).font(.caption)
            } else if library.keys.isEmpty {
                Text("Add keys in Settings → SSH Keys (⌘,).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @ObservedObject var library: SSHKeyLibrary
    @ViewState private var selectedTab: Tab = .general

    private enum Tab: String, CaseIterable {
        case general = "General"
        case highlights = "Highlights"
        case terminal = "Terminal"
        case keys = "SSH Keys"
        case hostKeys = "Host Keys"
        case credentials = "Credentials"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .highlights: return "highlighter"
            case .terminal: return "terminal"
            case .credentials: return "lock.shield"
            case .keys: return "key"
            case .hostKeys: return "checkmark.shield"
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button { selectedTab = tab } label: {
                        Label(tab.rawValue, systemImage: tab.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(selectedTab == tab ? Color.accentColor.opacity(0.2) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }.frame(width: 145)
            Divider()
            settingsPage.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(width: selectedTab == .credentials ? 940 : 760,
                height: selectedTab == .credentials ? 520 : 440).padding()
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding([.horizontal, .bottom])
        }
        .onAppear { selectedTab = .general }
        .overlay(alignment: .bottom) { OperationStatusView(model: model) }
    }

    @ViewBuilder private var settingsPage: some View {
        switch selectedTab {
        case .general: GeneralSettingsView(model: model)
        case .highlights: OutputHighlightSettings()
        case .terminal: TerminalSettingsView()
        case .credentials: CredentialsSettingsView(model: model, vault: model.vault)
        case .keys: KeyLibraryView(model: model, library: library)
        case .hostKeys: KnownHostsSettingsView(model: model)
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("restoreTabsOnLaunch") private var restoreTabs = false
    @AppStorage("startupSessionID") private var startupSessionID = ""
    var body: some View {
        Form {
            Picker("Startup session", selection: $startupSessionID) {
                Text("None").tag("")
                ForEach(model.profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { profile in
                    Text(profile.folder.map { $0 + "/" + profile.name } ?? profile.name).tag(profile.id.uuidString)
                }
            }
            Text("Automatically connects the selected session when muty launches.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Restore tabs on launch", isOn: $restoreTabs)
            Text("Restores saved SSH and Local Shell tabs, their names and order. The startup session connects automatically. For other restored tabs, press Enter or choose Reconnect. Temporary tabs, SFTP browser state and terminal output are excluded.")
                .font(.caption).foregroundStyle(.secondary)

        }.formStyle(.grouped).padding()
        .onChange(of: restoreTabs) { _, value in model.workspacePreferenceChanged(value) }
        .onChange(of: model.profiles.map(\.id), initial: true) { _, ids in
            guard !model.readOnly, !startupSessionID.isEmpty,
                  !ids.contains(where: { $0.uuidString == startupSessionID }) else { return }
            startupSessionID = ""
        }
    }
}

private struct TerminalSettingsView: View {
    @AppStorage("terminalFontSize") private var size = 13.0
    @AppStorage("terminalFontName") private var font = ""
    @AppStorage("terminalTheme") private var theme = "Dark"
    @AppStorage("terminalScrollback") private var scrollback = 10000.0
    @AppStorage("optionAsMetaKey") private var meta = true
    @AppStorage("confirmMultilinePaste") private var confirmPaste = true
    var body: some View {
        Form {
            Picker("Font", selection: $font) {
                Text("System Monospaced").tag(""); Text("Menlo").tag("Menlo")
                Text("Monaco").tag("Monaco"); Text("SF Mono").tag("SFMono-Regular")
            }
            Slider(value: $size, in: 9...30, step: 1) { Text("Font size") }
            Text("\(Int(size.isFinite ? max(9, min(30, size)) : 13)) pt")
            Picker("Theme", selection: $theme) { Text("Dark").tag("Dark"); Text("Light").tag("Light") }
            Slider(value: $scrollback, in: 1000...50000, step: 1000) { Text("Scrollback") }
            Text("\(Int(scrollback.isFinite ? max(1000, min(50000, scrollback)) : 10000)) lines")
            Toggle("Confirm multi-line paste", isOn: $confirmPaste)
            Toggle("Option as Meta", isOn: $meta)
            Text("Sends Alt/Meta shortcuts to the shell. Turn off to type macOS Option characters.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).padding()
    }
}

private struct KeyLibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: SSHKeyLibrary
    @ViewState private var selected: UUID?
    @ViewState private var error: String?
    @ViewState private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SSH Keys").font(.title2.bold()); Spacer()
                Button("Use Existing File…") { add(copy: false) }
                Button("Import…") { add(copy: true) }
            }
            if library.busy { ProgressView("Inspecting SSH key…").controlSize(.small) }
            List(selection: $selected) {
                ForEach(library.keys) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key.name).font(.headline)
                        if key.pendingDeletion == true {
                            Text("Deletion pending — retry Remove").font(.caption).foregroundStyle(.orange)
                        }
                        Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        Text(key.imported ? "Stored in muty" : key.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(key.id)
                }
            }
            if let key = library.keys.first(where: { $0.id == selected }) {
                HStack {
                    TextField("Key name", text: $name)
                    Button("Rename") { perform { try library.rename(key, to: name) } }
                    Button("Remove…", role: .destructive) { remove(key) }
                }
            }
            Text("Imported files are copied unchanged into a private local directory. Removing a reference never deletes its source file.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = error ?? library.loadError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.disabled(library.busy).padding().onChange(of: selected) { _, id in name = library.keys.first { $0.id == id }?.name ?? "" }
    }
    private func perform(_ body: () throws -> Void) {
        do { try body(); error = nil } catch { self.error = error.localizedDescription }
    }
    private func add(copy: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let file = panel.url else { return }
        Task {
            do {
                selected = try await library.addAsync(file: file, copy: copy).id
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    private func remove(_ key: SSHKeyRecord) {
        let dependent = model.profiles.filter { $0.authentication == .identityFile && $0.keyID == key.id }
        guard dependent.isEmpty else {
            error = "This key is used by: " + dependent.map(\.name).joined(separator: ", ") + ". Select another key in these sessions first."
            return
        }
        guard model.confirm("Remove Key?", text: key.imported ? "The private copy stored in muty will be deleted. The original file will not be changed." : "Only the reference will be removed. The source file will not be changed.") else { return }
        perform { try library.remove(key) }
    }
}
