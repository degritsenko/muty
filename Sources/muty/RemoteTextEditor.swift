import AppKit

struct RemoteTextSnapshot: Equatable {
    static let maximumBytes: UInt64 = 1_048_576
    let bytes: Data
    let attributes: SFTPAttributes
    init(bytes: Data, attributes: SFTPAttributes) throws {
        guard bytes.count <= Self.maximumBytes else { throw MutyError("The editor supports files up to 1 MiB.") }
        guard let text = String(data: bytes, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else {
            throw MutyError("Only UTF-8 text files can be opened. Binary files are not supported.")
        }
        self.bytes = bytes; self.attributes = attributes
    }
    private var hasBOM: Bool { bytes.starts(with: [0xef, 0xbb, 0xbf]) }
    private var originalText: String { String(decoding: hasBOM ? bytes.dropFirst(3) : bytes[...], as: UTF8.self) }
    var text: String { originalText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
    func encode(_ text: String) -> Data {
        let lineEnding = originalText.contains("\r\n") ? "\r\n" : originalText.contains("\r") ? "\r" : "\n"
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var result = hasBOM ? Data([0xef, 0xbb, 0xbf]) : Data()
        result.append(Data(normalized.replacingOccurrences(of: "\n", with: lineEnding).utf8))
        return result
    }
}

@MainActor private final class RemoteEditorWindow: NSWindow {
    var saveAction: (() -> Void)?
    var findAction: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           attachedSheet == nil, NSApp.modalWindow == nil {
            performClose(nil)
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            if event.charactersIgnoringModifiers == "s" { saveAction?(); return true }
            if event.charactersIgnoringModifiers == "f" { findAction?(); return true }
            if event.charactersIgnoringModifiers == "w" { performClose(nil); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class RemoteTextEditor: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private static var openEditors: [UUID: RemoteTextEditor] = [:]
    private let editorID = UUID()
    private let editor = NSTextView()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var snapshot: RemoteTextSnapshot
    private let readOnly: Bool
    private let usesYAMLIndentation: Bool
    private var saving = false
    private var disconnected = false
    private let saveDocument: (Data, RemoteTextSnapshot) async throws -> RemoteTextSnapshot
    var onClose: (() -> Void)?
    private var dirty: Bool { editor.string != snapshot.text }

    init(path: String, snapshot: RemoteTextSnapshot, readOnly: Bool, tabGroupID: UUID,
         save: @escaping (Data, RemoteTextSnapshot) async throws -> RemoteTextSnapshot) {
        self.snapshot = snapshot; self.readOnly = readOnly; self.saveDocument = save
        usesYAMLIndentation = ["yaml", "yml"].contains((path as NSString).pathExtension.lowercased())
        let window = RemoteEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 580),
                                        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = (readOnly ? "View — " : "Edit — ") + (path as NSString).lastPathComponent
        window.tabbingIdentifier = "muty.sftp.editor." + tabGroupID.uuidString
        window.tabbingMode = .preferred
        window.minSize = NSSize(width: 500, height: 320); window.delegate = self
        window.isReleasedWhenClosed = false
        window.saveAction = { [weak self] in self?.save() }
        window.findAction = { [weak self] in self?.findText() }
        let pathLabel = NSTextField(wrappingLabelWithString: path)
        pathLabel.isSelectable = true; pathLabel.font = .systemFont(ofSize: 12); pathLabel.lineBreakMode = .byTruncatingMiddle
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        editor.isRichText = false; editor.isEditable = !readOnly; editor.isSelectable = true
        editor.allowsUndo = true; editor.usesFindBar = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.string = snapshot.text; editor.delegate = self; scroll.documentView = editor
        let find = NSButton(title: "Find…", target: self, action: #selector(findText))
        find.bezelStyle = .rounded
        saveButton.target = self; saveButton.action = #selector(saveClicked); saveButton.bezelStyle = .rounded
        saveButton.isHidden = readOnly
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked)); close.bezelStyle = .rounded
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [message, find, saveButton, close]); buttons.orientation = .horizontal; buttons.spacing = 8
        message.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [pathLabel, scroll, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        guard let content = window.contentView else { return }
        content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.initialFirstResponder = editor; window.center(); update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    static func allowTermination() -> Bool {
        if let saving = openEditors.values.first(where: { $0.saving }) {
            saving.window?.makeKeyAndOrderFront(nil)
            let alert = NSAlert(); alert.messageText = "A file is being saved."
            alert.informativeText = "Wait for saving to finish before quitting."; alert.runModal()
            return false
        }
        guard let dirty = openEditors.values.first(where: { $0.dirty }) else { return true }
        dirty.window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert(); alert.messageText = "Remote files have unsaved changes."
        alert.informativeText = "Review the editor windows before quitting, or discard all unsaved changes."
        alert.addButton(withTitle: "Review Changes"); alert.addButton(withTitle: "Discard Changes and Quit"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertSecondButtonReturn
    }
    override func showWindow(_ sender: Any?) { Self.openEditors[editorID] = self; super.showWindow(sender) }
    func activate() {
        guard let window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard usesYAMLIndentation, textView.isEditable, commandSelector == #selector(NSResponder.insertTab(_:)) else { return false }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let prefix = text.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let column = prefix.reduce(0) { column, character in
            column + (character == "\t" ? 2 - column % 2 : 1)
        }
        textView.insertText(String(repeating: " ", count: 2 - column % 2), replacementRange: selection)
        return true
    }
    func textDidChange(_ notification: Notification) {
        message.stringValue = disconnected ? "SSH connection ended. Your draft remains available to copy." : dirty ? "Unsaved changes" : ""
        update()
    }
    private func update() {
        window?.isDocumentEdited = dirty
        saveButton.isEnabled = dirty && !saving && !readOnly && !disconnected
        editor.isEditable = !readOnly && !saving
    }
    func connectionEnded() {
        disconnected = true; message.stringValue = "SSH connection ended. Your draft remains available to copy."; update()
    }
    @objc private func findText() {
        window?.makeFirstResponder(editor)
        let item = NSMenuItem(); item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        editor.performFindPanelAction(item)
    }
    @objc private func saveClicked() { save() }
    @objc private func closeClicked() { window?.performClose(nil) }
    private func save(closeAfter: Bool = false) {
        guard !saving, !disconnected, !readOnly, dirty else { return }
        let data = snapshot.encode(editor.string), expected = snapshot
        saving = true; message.stringValue = "Saving…"; update()
        Task { [self] in
            do {
                snapshot = try await saveDocument(data, expected)
                message.stringValue = "Saved"; saving = false; update()
                if closeAfter { window?.close() }
            } catch {
                saving = false; message.stringValue = error.localizedDescription; update()
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !saving else { return false }
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes before closing?"
        alert.informativeText = "Unsaved changes will be lost."
        if !disconnected { alert.addButton(withTitle: "Save") }
        alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        let result = alert.runModal()
        if disconnected { return result == .alertFirstButtonReturn }
        if result == .alertFirstButtonReturn { save(closeAfter: true); return false }
        return result == .alertSecondButtonReturn
    }
    func windowWillClose(_ notification: Notification) { onClose?(); Self.openEditors[editorID] = nil }
}
