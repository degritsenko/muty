import SwiftUI
import AppKit

struct KeySelectionView: View {
    @ObservedObject var library: SSHKeyLibrary
    @Binding var keyID: UUID?
    @Binding var legacyPath: String?
    @ViewState private var error: String?
    var presentingWindow: (() -> NSWindow?)? = nil
    private var title: String {
        if let keyID { return library.keys.first(where: { $0.id == keyID })?.name ?? "Missing key" }
        return legacyPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Select a key"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            KeySelectionPopup(
                keys: library.keys.filter { $0.pendingDeletion != true },
                selectedKey: keyID, title: title,
                select: { keyID = $0; legacyPath = nil; error = nil },
                chooseFile: { chooseFile(from: $0) }
            )
            if let message = error ?? library.loadError {
                Text(message).foregroundStyle(.red).font(.caption)
            }
        }
    }
    private func chooseFile(from window: NSWindow?) {
        guard let ownerWindow = presentingWindow?() ?? window else { error = "Could not find the key selection window."; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = "Choose a private SSH key. It will not be added to the key library."
        panel.beginSheetModal(for: ownerWindow) { response in
            guard response == .OK, let file = panel.url else { return }
            do {
                try SSHKeyLibrary.validateConnectionKey(file)
                legacyPath = file.path; keyID = nil; error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct KeySelectionPopup: NSViewRepresentable {
    let keys: [SSHKeyRecord]
    let selectedKey: UUID?
    let title: String
    let select: (UUID) -> Void
    let chooseFile: (NSWindow?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.setAccessibilityLabel("SSH Key")
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.popup = self
        button.removeAllItems()
        let menu = button.menu
        menu?.autoenablesItems = false
        if !keys.contains(where: { $0.id == selectedKey }) {
            let current = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            current.isEnabled = false
            menu?.addItem(current)
        }
        for key in keys {
            let item = NSMenuItem(title: key.name, action: nil, keyEquivalent: "")
            item.representedObject = key.id
            menu?.addItem(item)
        }
        menu?.addItem(.separator())
        menu?.addItem(NSMenuItem(title: "Choose File…", action: nil, keyEquivalent: ""))
        context.coordinator.restoreSelection(in: button)
    }

    @MainActor final class Coordinator: NSObject {
        var popup: KeySelectionPopup
        init(_ popup: KeySelectionPopup) { self.popup = popup }

        func restoreSelection(in button: NSPopUpButton) {
            button.select(button.itemArray.first { ($0.representedObject as? UUID) == popup.selectedKey && $0.representedObject != nil }
                          ?? button.itemArray.first)
        }

        @objc func selectionChanged(_ button: NSPopUpButton) {
            if let id = button.selectedItem?.representedObject as? UUID {
                popup.select(id)
            } else if let item = button.selectedItem, item === button.itemArray.last {
                restoreSelection(in: button)
                let chooseFile = popup.chooseFile
                DispatchQueue.main.async { [weak button] in
                    guard let window = button?.window else { return }
                    chooseFile(window)
                }
            }
        }
    }
}

@MainActor final class ModalSettingsWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           attachedSheet == nil {
            performClose(nil)
            return
        }
        super.sendEvent(event)
    }

    override func close() {
        if NSApp.modalWindow === self { NSApp.stopModal() }
        super.close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct AppSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: SSHKeyLibrary
    @ViewState private var selectedTab: Tab = .general

    private enum Tab: String, CaseIterable {
        case general = "General"
        case terminal = "Terminal"
        case credentials = "Credentials"
        case keys = "SSH Keys"
        case hostKeys = "Host Keys"
        case highlights = "Syntax Highlighting"

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
            }.frame(width: 170)
            Divider()
            settingsPage.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding()
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
    @AppStorage("startupEmptyAction") private var startupEmptyAction = "empty"
    @ViewState private var choosingStartup = false
    @ViewState private var startupQuery = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("On launch").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        Text("Open").foregroundStyle(.secondary)
                        Picker(
                            "Open",
                            selection: Binding(
                                get: { startupSessionID.isEmpty ? startupEmptyAction : "session" },
                                set: { value in
                                    if value == "session" {
                                        startupQuery = ""; choosingStartup = true
                                    } else {
                                        startupSessionID = ""; startupEmptyAction = value
                                    }
                                }
                            )
                        ) {
                            Text("Empty window").tag("empty")
                            Text("Local Shell").tag("localShell")
                            Text("Quick Connect").tag("quickConnect")
                            Text("Saved session…").tag("session")
                        }.labelsHidden()
                    }
                    if !startupSessionID.isEmpty {
                        GridRow {
                            Text("Saved session").foregroundStyle(.secondary)
                            Button(model.profiles.first { $0.id.uuidString == startupSessionID }?.name ?? "Unavailable") {
                                startupQuery = ""; choosingStartup = true
                            }
                        }
                    }
                    GridRow {
                        Text(""); Toggle("Restore previous tabs", isOn: $restoreTabs)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text("Restored SSH tabs wait for reconnect. The selected startup session connects automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
        }
        .sheet(isPresented: $choosingStartup) {
            let query = startupQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let profiles = query.isEmpty ? model.profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : SavedSessionSearch.matches(model.profiles, query: query)
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose Startup Session").font(.headline)
                TextField("Search sessions or folders", text: $startupQuery)
                if profiles.isEmpty {
                    Text(query.isEmpty ? "No saved sessions" : "No matching sessions").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List { PaneSessionBranch(parent: nil, profiles: profiles, searching: !query.isEmpty, model: model) { profile in
                        startupSessionID = profile.id.uuidString; choosingStartup = false
                    } }
                }
                HStack { Spacer(); Button("Cancel") { choosingStartup = false }.keyboardShortcut(.cancelAction) }
            }.padding().frame(width: 420, height: 360)
        }
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
    @AppStorage("terminalTheme") private var theme = TerminalColorScheme.mutyDark.rawValue
    @AppStorage("terminalScrollback") private var scrollback = 10000.0
    @AppStorage("optionAsMetaKey") private var meta = true
    @AppStorage("confirmMultilinePaste") private var confirmPaste = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Terminal").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        Text("Font").foregroundStyle(.secondary)
                        Picker("Font", selection: $font) {
                            Text("System Monospaced").tag(""); Text("Menlo").tag("Menlo")
                            Text("Monaco").tag("Monaco"); Text("SF Mono").tag("SFMono-Regular")
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Font size").foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("Font size", value: boundedInteger($size, range: 9...30, fallback: 13),
                                      format: .number.grouping(.never))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                            Stepper("Font size", value: boundedInteger($size, range: 9...30, fallback: 13), in: 9...30)
                                .labelsHidden()
                            Text("pt").foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Color scheme").foregroundStyle(.secondary)
                        Picker("Color scheme", selection: $theme) {
                            ForEach(TerminalColorScheme.allCases) { scheme in
                                Text(scheme.name).tag(scheme.rawValue)
                            }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Scrollback").foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("Scrollback", value: boundedInteger($scrollback, range: 1000...50000, fallback: 10000),
                                      format: .number.grouping(.never))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("lines").foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Confirm multi-line paste", isOn: $confirmPaste)
                Toggle("Option as Meta", isOn: $meta)
                Text("Sends Alt/Meta shortcuts to the shell. Turn off to type macOS Option characters.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
        }
            .onAppear {
                let resolved = TerminalColorScheme.resolve(theme).rawValue
                if resolved != theme { theme = resolved }
            }
    }

    private func boundedInteger(_ value: Binding<Double>, range: ClosedRange<Int>, fallback: Int) -> Binding<Int> {
        Binding(
            get: {
                let current = value.wrappedValue
                return current.isFinite ? Int(max(Double(range.lowerBound), min(Double(range.upperBound), current))) : fallback
            },
            set: { value.wrappedValue = Double(max(range.lowerBound, min(range.upperBound, $0))) }
        )
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
                Button("Link Key File…") { add(copy: false) }.help("Use the existing file at its current location.")
                Button("Import Key Copy…") { add(copy: true) }.help("Copy the key into muty’s private storage.")
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
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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
        let dependent = model.profiles.filter { $0.authentication.supportsKey && $0.keyID == key.id }
        guard dependent.isEmpty else {
            error = "This key is used by: " + dependent.map(\.name).joined(separator: ", ") + ". Select another key in these sessions first."
            return
        }
        guard model.confirm("Remove Key?", text: key.imported ? "The private copy stored in muty will be deleted. The original file will not be changed." : "Only the reference will be removed. The source file will not be changed.") else { return }
        perform { try library.remove(key) }
    }
}

private struct KeyPickerWindowAnchor: NSViewRepresentable {
    let update: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Anchor { let view = Anchor(); view.update = update; return view }
    func updateNSView(_ view: Anchor, context: Context) { view.update = update }
    final class Anchor: NSView {
        var update: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); update?(window) }
    }
}
