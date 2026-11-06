import SwiftUI
import AppKit

enum SendStringAction: Equatable {
    case text(String)
    case pause
}

struct SendStringButton: Codable, Identifiable {
    var id = UUID()
    var title = ""
    var string = ""
    var setID: UUID?
    var color: String?
    var confirm: Bool?
    func validated() throws -> Self {
        var result = self
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.title.isEmpty, result.title.count <= 80 else { throw MutyError("Enter a button name (up to 80 characters).") }
        guard !string.isEmpty, string.utf8.count <= 65536, !string.contains("\0") else { throw MutyError("Enter a Send string (up to 64 KB, without NUL).") }
        guard color == nil || Self.colors.contains(color!) else { throw MutyError("Invalid button color.") }
        _ = try Self.actions(string)
        return result
    }
    static let colors = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple"]

    static func actions(_ input: String) throws -> [SendStringAction] {
        var result: [SendStringAction] = []
        var output = ""
        var iterator = input.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else { output.append(character); continue }
            guard let escaped = iterator.next() else { throw MutyError("Use \\\\ for a literal backslash.") }
            switch escaped {
            case "p":
                if !output.isEmpty { result.append(.text(output)); output = "" }
                result.append(.pause)
            case "b": output.append("\u{08}")
            case "r": output.append("\r")
            case "n": output.append("\n")
            case "t": output.append("\t")
            case "e": output.append("\u{1b}")
            case "\\": output.append("\\")
            default: throw MutyError("Supported escapes: \\r, \\n, \\t, \\e, \\p, \\b and \\\\.")
            }
        }
        if !output.isEmpty { result.append(.text(output)) }
        return result
    }
}

struct ButtonBarSet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
}

struct ButtonBarDocument: Codable {
    var sets: [ButtonBarSet] = []
    var buttons: [SendStringButton] = []
    var folderSets: [String: UUID] = [:]

    func validated() throws -> Self {
        guard sets.count <= 100, buttons.count <= 1000, folderSets.count <= 10000,
              Set(sets.map(\.id)).count == sets.count,
              Set(buttons.map(\.id)).count == buttons.count else { throw MutyError("Invalid Button Bar data.") }
        let ids = Set(sets.map(\.id))
        var names = Set<String>()
        for set in sets {
            let name = set.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80, name == set.name,
                  names.insert(name.lowercased()).inserted else { throw MutyError("Invalid or duplicate button set name.") }
        }
        for button in buttons {
            _ = try button.validated()
            guard button.setID.map(ids.contains) ?? true else { throw MutyError("Button set is missing.") }
        }
        for (folder, id) in folderSets {
            guard SessionProfile.canonicalFolder(folder) == folder, ids.contains(id) else {
                throw MutyError("Invalid button set folder assignment.")
            }
        }
        return self
    }
}

@MainActor final class SendStringButtonStore: ObservableObject {
    static let shared = SendStringButtonStore()
    @Published private(set) var document = ButtonBarDocument()
    private(set) var loadError: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        do {
            if let data = defaults.data(forKey: "buttonBarDocument") {
                document = try JSONDecoder().decode(ButtonBarDocument.self, from: data).validated()
            } else if let data = defaults.data(forKey: "sendStringButtons") {
                document.buttons = try JSONDecoder().decode([SendStringButton].self, from: data)
                document = try document.validated()
            }
        } catch { loadError = "Cannot load Button Bar: " + error.localizedDescription }
    }
    func snapshot() throws -> ButtonBarDocument {
        if let loadError { throw MutyError(loadError) }
        return document
    }
    struct Checkpoint {
        let data: Data?
        let document: ButtonBarDocument
        let loadError: String?
    }
    func checkpoint() -> Checkpoint {
        Checkpoint(data: defaults.data(forKey: "buttonBarDocument"), document: document, loadError: loadError)
    }
    func rollback(_ checkpoint: Checkpoint) {
        defaults.set(checkpoint.data, forKey: "buttonBarDocument")
        document = checkpoint.document
        loadError = checkpoint.loadError
    }
    func restore(_ value: ButtonBarDocument) throws {
        let value = try value.validated()
        let data = try JSONEncoder().encode(value)
        defaults.set(data, forKey: "buttonBarDocument")
        loadError = nil
        document = value
    }
    func movingFolders(_ mapping: [String: String]) throws -> ButtonBarDocument {
        var updated = try snapshot()
        var assignments = document.folderSets
        let moved = document.folderSets.filter { folder, _ in
            mapping.keys.contains { folder == $0 || folder.hasPrefix($0 + "/") }
        }
        for folder in moved.keys { assignments.removeValue(forKey: folder) }
        for (folder, set) in moved {
            guard let root = mapping.keys.first(where: { folder == $0 || folder.hasPrefix($0 + "/") }),
                  let target = mapping[root] else { continue }
            assignments[target + folder.dropFirst(root.count)] = set
        }
        updated.folderSets = assignments
        return updated
    }
    func addStarterSets() throws -> UUID? {
        let presets: [(String, [(String, String)])] = [
            ("Linux", [("Uptime", "uptime"), ("Disk", "df -h"), ("Memory", "free -m"), ("Processes", "ps aux")]),
            ("Cisco", [("Version", "show version"), ("Interfaces", "show interfaces"), ("IP Brief", "show ip interface brief")]),
            ("Kubernetes", [("Pods", "kubectl get pods"), ("Services", "kubectl get services"), ("Events", "kubectl get events")])
        ]
        var updated = document
        var firstAdded: UUID?
        for (name, commands) in presets {
            guard !updated.sets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            let set = ButtonBarSet(name: name)
            updated.sets.append(set)
            if firstAdded == nil { firstAdded = set.id }
            for (title, command) in commands {
                var button = SendStringButton()
                button.title = title
                button.string = command + "\\r"
                button.setID = set.id
                updated.buttons.append(button)
            }
        }
        try replace(updated)
        return firstAdded
    }
    func replace(_ value: ButtonBarDocument) throws {
        if let loadError { throw MutyError(loadError) }
        let value = try value.validated()
        let data = try JSONEncoder().encode(value)
        defaults.set(data, forKey: "buttonBarDocument")
        document = value
    }
    func save(_ button: SendStringButton) throws {
        let button = try button.validated()
        var updated = document
        if let index = updated.buttons.firstIndex(where: { $0.id == button.id }) { updated.buttons[index] = button }
        else { updated.buttons.append(button) }
        try replace(updated)
    }
    func remove(_ button: SendStringButton) throws {
        var updated = document
        updated.buttons.removeAll { $0.id == button.id }
        try replace(updated)
    }
    func duplicate(_ button: SendStringButton) throws {
        var copy = button
        copy.id = UUID()
        copy.title = String(button.title.prefix(75)) + " Copy"
        try save(copy)
    }
    func move(_ source: UUID, before target: UUID) throws -> Bool {
        guard source != target, let button = document.buttons.first(where: { $0.id == source }),
              let destination = document.buttons.first(where: { $0.id == target }), button.setID == destination.setID else { return false }
        let sourceIndex = document.buttons.firstIndex { $0.id == source }!
        let targetIndex = document.buttons.firstIndex { $0.id == target }!
        var updated = document
        updated.buttons.removeAll { $0.id == source }
        guard let index = updated.buttons.firstIndex(where: { $0.id == target }) else { return false }
        updated.buttons.insert(button, at: sourceIndex < targetIndex ? index + 1 : index)
        try replace(updated)
        return true
    }
    func saveSet(name: String, id: UUID? = nil) throws -> UUID {
        var updated = document
        let set = ButtonBarSet(id: id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        if let index = updated.sets.firstIndex(where: { $0.id == set.id }) { updated.sets[index] = set }
        else { updated.sets.append(set) }
        try replace(updated)
        return set.id
    }
    func removeSet(_ id: UUID) throws {
        var updated = document
        updated.sets.removeAll { $0.id == id }
        for index in updated.buttons.indices where updated.buttons[index].setID == id { updated.buttons[index].setID = nil }
        updated.folderSets = updated.folderSets.filter { $0.value != id }
        try replace(updated)
    }
    func assign(_ set: UUID?, to folder: String) throws {
        var updated = document
        updated.folderSets[folder] = set
        try replace(updated)
    }
    func assignedSet(for folder: String?) -> UUID? {
        var path = folder
        while let current = path {
            if let id = document.folderSets[current] { return id }
            path = SessionProfile.canonicalFolder((current as NSString).deletingLastPathComponent)
        }
        return nil
    }
}

struct SendStringButtonBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = SendStringButtonStore.shared
    @ViewState private var selectedSet: UUID?
    @ViewState private var editingSet = false
    @ViewState private var setName = ""
    @ViewState private var setToRename: UUID?

    private var folder: String? {
        model.selectedConnection.flatMap { model.currentFolder(for: $0) }
    }
    private var title: String { store.document.sets.first { $0.id == selectedSet }?.name ?? "Default" }
    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Default") { selectedSet = nil }
                ForEach(store.document.sets) { set in Button(set.name) { selectedSet = set.id } }
                Divider()
                Button("New Set…") { setToRename = nil; setName = ""; editingSet = true }
                Button("Add Starter Sets") {
                    perform { if let id = try store.addStarterSets() { selectedSet = id } }
                }
                if let selectedSet {
                    Button("Rename Set…") { setToRename = selectedSet; setName = title; editingSet = true }
                    Button("Remove Set…") {
                        guard model.confirm("Remove Button Set?", text: "Its buttons will move to Default.", action: "Remove") else { return }
                        perform { try store.removeSet(selectedSet); self.selectedSet = nil }
                    }
                }
                if let folder {
                    Divider()
                    if let selectedSet {
                        Button("Assign to " + folder) { perform { try store.assign(selectedSet, to: folder) } }
                    }
                    if store.document.folderSets[folder] != nil {
                        Button("Remove Folder Assignment") { perform { try store.assign(nil, to: folder) }; followFolder() }
                    }
                }
            } label: { Label(title, systemImage: "square.stack").lineLimit(1) }
                .fixedSize()
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .disabled(store.loadError != nil)
                .help("Button set · folder assignments include subfolders")
            Divider().frame(height: 18)
                .padding(.horizontal, 2)
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(store.document.buttons.filter { $0.setID == selectedSet }) { button in
                        Group {
                            if let connection = model.selectedConnection {
                                ConnectedSendButton(connection: connection, button: button, model: model)
                            } else { Button(button.title) {}.disabled(true) }
                        }
                        .contextMenu { actions(button) }
                        .draggable("muty-button:" + button.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard items.count == 1, let value = items.first, value.hasPrefix("muty-button:"),
                                  let source = UUID(uuidString: String(value.dropFirst("muty-button:".count))) else { return false }
                            do { return try store.move(source, before: button.id) }
                            catch { model.errorMessage = error.localizedDescription; return false }
                        }
                    }
                    if let error = store.loadError { Text("Button Bar unavailable").foregroundStyle(.red).help(error) }
                    Spacer(minLength: 0)
                }
            }.scrollIndicators(.hidden)
            Button { edit(nil) } label: { Image(systemName: "plus") }
                .help("New Send String Button").disabled(store.loadError != nil)
        }
        .font(.system(size: 12)).controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 4).frame(height: 32)
        .background(.bar).contentShape(Rectangle())
        .onChange(of: model.selectedTab, initial: true) { _, _ in followFolder() }
        .onChange(of: folder) { _, _ in followFolder() }
        .onChange(of: store.document.sets) { _, sets in
            if let selectedSet, !sets.contains(where: { $0.id == selectedSet }) { followFolder() }
        }
        .alert(setToRename == nil ? "New Button Set" : "Rename Button Set", isPresented: $editingSet) {
            TextField("Name", text: $setName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { perform { selectedSet = try store.saveSet(name: setName, id: setToRename) } }
        }
        .contextMenu { Button("New Button…") { edit(nil) }.disabled(store.loadError != nil) }
    }
    private func followFolder() { selectedSet = store.assignedSet(for: folder) }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { model.errorMessage = error.localizedDescription }
    }
    @ViewBuilder private func actions(_ button: SendStringButton) -> some View {
        Button("New Button…") { edit(nil) }
        Button("Edit…") { edit(button) }
        Button("Duplicate") { perform { try store.duplicate(button) } }
        Menu("Move to Set") {
            Button("Default") { perform { var copy = button; copy.setID = nil; try store.save(copy) } }
            ForEach(store.document.sets) { set in
                Button(set.name) { perform { var copy = button; copy.setID = set.id; try store.save(copy) } }
            }
        }
        Button("Delete", role: .destructive) { perform { try store.remove(button) } }
    }
    private func edit(_ button: SendStringButton?) {
        var value = button ?? SendStringButton()
        if button == nil { value.setID = selectedSet }
        let panel = SendStringButtonEditor(button: value, isNew: button == nil)
        defer { panel.clearContents() }
        guard panel.run() == .OK, let result = panel.result else { return }
        perform { try store.save(result) }
    }
}

private struct ConnectedSendButton: View {
    @ObservedObject var connection: SSHConnection
    let button: SendStringButton
    @ObservedObject var model: AppModel
    var body: some View {
        Button(button.title) {
            guard model.selectedConnection?.id == connection.id, connection.running, !connection.showingSFTP else { return }
            let pid = connection.terminal.process.shellPid
            if button.confirm == true {
                guard model.confirm("Send Button Command?", text: connection.profile.name + "\n" + connection.profile.endpoint + "\n\n" + button.string, action: "Send") else { return }
            }
            guard model.selectedConnection?.id == connection.id, connection.running, !connection.showingSFTP,
                  connection.terminal.process.shellPid == pid else { return }
            do {
                let actions = try SendStringButton.actions(button.string)
                connection.terminal.sendButtonActions(actions)
                connection.terminal.window?.makeFirstResponder(connection.terminal)
            } catch { model.errorMessage = error.localizedDescription }
        }
        .tint(button.color.map { Color(nsColor: OutputHighlightStore.color($0)) })
        .foregroundStyle(button.color.map { Color(nsColor: OutputHighlightStore.color($0)) } ?? .primary)
        .disabled(!connection.running || connection.showingSFTP).help(button.string)
    }
}

@MainActor private final class SendStringButtonEditor: CancellableModalPanel {
    private var button: SendStringButton
    private let name = NSTextField()
    private let color = NSPopUpButton()
    private let confirm = NSButton(checkboxWithTitle: "Confirm before sending", target: nil, action: nil)
    private let string = NSTextView()
    private var error: NSTextField!
    private(set) var result: SendStringButton?
    init(button: SendStringButton, isNew: Bool) {
        self.button = button
        super.init(title: isNew ? "New Button" : "Edit Button", width: 480, height: 360)
        _ = label("Name:", y: 322, width: 70)
        name.frame = NSRect(x: 90, y: 320, width: 370, height: 24)
        name.stringValue = button.title; contentView?.addSubview(name)
        _ = label("Send string:", y: 288, width: 440)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 182, width: 440, height: 100))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        string.frame = NSRect(x: 0, y: 0, width: 440, height: 100)
        string.isRichText = false; string.allowsUndo = true
        string.isAutomaticQuoteSubstitutionEnabled = false
        string.isAutomaticDashSubstitutionEnabled = false
        string.isAutomaticTextReplacementEnabled = false
        string.isAutomaticSpellingCorrectionEnabled = false
        string.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        string.string = button.string
        string.autoresizingMask = [.width]; string.textContainer?.widthTracksTextView = true
        scroll.documentView = string; contentView?.addSubview(scroll)
        let hint = label("\\r = Enter · \\n = New line (LF) · \\t = Tab · \\e = Escape\n\\p = Pause 1 second · \\b = Backspace · \\\\ = backslash\nExample: sudo su -\\r\\p", y: 72, width: 440, height: 46)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        color.frame = NSRect(x: 20, y: 140, width: 135, height: 26)
        color.addItems(withTitles: ["Default"] + SendStringButton.colors)
        color.selectItem(withTitle: button.color ?? "Default")
        contentView?.addSubview(color)
        confirm.frame = NSRect(x: 170, y: 140, width: 290, height: 26)
        confirm.state = button.confirm == true ? .on : .off
        contentView?.addSubview(confirm)
        error = label("", y: 49, width: 440, height: 25); error.textColor = .systemRed; error.font = .systemFont(ofSize: 11)
        cancelButton(x: 270)
        let save = NSButton(title: "Save", target: self, action: #selector(submit(_:)))
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        save.frame = NSRect(x: 370, y: 16, width: 90, height: 28)
        contentView?.addSubview(save); initialFirstResponder = name
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func submit(_ sender: Any?) {
        button.title = name.stringValue; button.string = string.string
        button.color = color.titleOfSelectedItem == "Default" ? nil : color.titleOfSelectedItem
        button.confirm = confirm.state == .on
        do { result = try button.validated(); finish(.OK) }
        catch { self.error.stringValue = error.localizedDescription }
    }
    func clearContents() { string.string = ""; result = nil }
}
