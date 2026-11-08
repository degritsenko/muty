import AppKit

@MainActor class CancellableModalPanel: NSPanel, NSWindowDelegate {
    private var finished = false
    init(title: String, width: CGFloat, height: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.title = title; isReleasedWhenClosed = false; delegate = self
    }
    @discardableResult func run() -> NSApplication.ModalResponse {
        center()
        let result = NSApp.runModal(for: self)
        orderOut(nil)
        return result
    }
    func finish(_ response: NSApplication.ModalResponse) {
        guard !finished else { return }
        finished = true
        NSApp.stopModal(withCode: response)
        orderOut(nil)
        // Accessibility and asynchronous callbacks may run outside the modal event loop.
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: windowNumber, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: true)
        }
    }
    @objc func cancel(_ sender: Any?) { finish(.cancel) }
    override func cancelOperation(_ sender: Any?) { finish(.cancel) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(.cancel); return false }
    func label(_ text: String, x: CGFloat = 20, y: CGFloat, width: CGFloat, height: CGFloat = 22) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.frame = NSRect(x: x, y: y, width: width, height: height)
        contentView?.addSubview(field)
        return field
    }
    @discardableResult func cancelButton(x: CGFloat, y: CGFloat = 16) -> NSButton {
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        button.bezelStyle = .rounded; button.keyEquivalent = "\u{1b}"
        button.frame = NSRect(x: x, y: y, width: 90, height: 28)
        contentView?.addSubview(button)
        return button
    }
}

@MainActor final class NativeVaultPanel: CancellableModalPanel, NSTextFieldDelegate {
    private let vault: VaultStore
    private let mode: VaultAccessMode
    private let protected = NSButton(checkboxWithTitle: "Use a master password", target: nil, action: nil)
    private let password = NSSecureTextField()
    private let confirmation = NSSecureTextField()
    private let save = NSButton()
    private var hint: NSTextField!
    private var error: NSTextField!
    init(vault: VaultStore, mode: VaultAccessMode) {
        self.vault = vault; self.mode = mode
        super.init(title: "Password Storage", width: 450, height: 300)
        let title = label(mode == .unlock ? "Unlock Password Storage" : mode == .setup ? "Set Up Password Storage" : "Change Password Protection", y: 254, width: 410, height: 28)
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        protected.frame = NSRect(x: 20, y: 220, width: 410, height: 22)
        protected.state = .on; protected.target = self; protected.action = #selector(refresh(_:))
        contentView?.addSubview(protected)
        password.frame = NSRect(x: 20, y: 184, width: 410, height: 26)
        password.placeholderString = "Master password"; password.delegate = self
        confirmation.frame = NSRect(x: 20, y: 150, width: 410, height: 26)
        confirmation.placeholderString = "Confirm master password"; confirmation.delegate = self
        contentView?.addSubview(password); contentView?.addSubview(confirmation)
        hint = label("", y: 100, width: 410, height: 38); hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        error = label("", y: 48, width: 410, height: 44); error.font = .systemFont(ofSize: 12); error.textColor = .systemRed
        let cancel = cancelButton(x: 240)
        save.title = mode == .unlock ? "Unlock" : "Save"; save.bezelStyle = .rounded
        save.target = self; save.action = #selector(submit(_:)); save.keyEquivalent = "\r"
        save.frame = NSRect(x: 340, y: 16, width: 90, height: 28)
        contentView?.addSubview(save)
        protected.nextKeyView = password
        password.nextKeyView = confirmation
        confirmation.nextKeyView = cancel
        cancel.nextKeyView = save
        save.nextKeyView = protected
        initialFirstResponder = password
        refresh(nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func clearSecrets() { password.stringValue = ""; confirmation.stringValue = "" }
    func controlTextDidChange(_ obj: Notification) { refresh(nil) }
    @objc private func refresh(_ sender: Any?) {
        let usesMaster = mode == .unlock || protected.state == .on
        protected.isHidden = mode == .unlock
        password.isHidden = !usesMaster
        confirmation.isHidden = mode == .unlock || !usesMaster
        hint.frame = NSRect(x: 20, y: usesMaster ? 100 : 152, width: 410, height: usesMaster ? 38 : 55)
        hint.stringValue = usesMaster ? "Unlock once per app launch. A forgotten master password cannot be recovered." : "Without a master password, the key is stored with the vault. Anyone who copies the vault can recover its passwords."
        hint.textColor = usesMaster ? .secondaryLabelColor : .systemOrange
        save.isEnabled = !usesMaster || (!password.stringValue.isEmpty && password.stringValue.utf8.count <= 1024 &&
            (mode == .unlock || password.stringValue == confirmation.stringValue))
    }
    @objc private func submit(_ sender: Any?) {
        guard save.isEnabled else { return }
        if mode != .unlock && protected.state == .off {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = mode == .change ? L("Disable Master Password?") : L("Save Without a Master Password?")
            alert.informativeText = hint.stringValue
            alert.addButton(withTitle: L("Cancel"))
            alert.addButton(withTitle: mode == .change ? L("Disable") : L("Save Without Master Password"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do {
            switch mode {
            case .setup: try vault.initialize(masterPassword: protected.state == .on ? password.stringValue : nil)
            case .unlock: try vault.unlock(masterPassword: password.stringValue)
            case .change: try vault.changeProtection(masterPassword: protected.state == .on ? password.stringValue : nil)
            }
            clearSecrets(); finish(.OK)
        } catch { self.error.stringValue = error.localizedDescription }
    }
}

@MainActor final class NativeSSHPasswordPanel: CancellableModalPanel {
    private let password = NSSecureTextField()
    private let remember: NSButton
    private let canSave: Bool
    private(set) var result: (String, Bool)?
    init(endpoint: String, prompt: String, canSave: Bool, replaceSaved: Bool) {
        self.canSave = canSave
        remember = NSButton(checkboxWithTitle: "Save password in muty", target: nil, action: nil)
        super.init(title: "SSH Authentication", width: 380, height: 190)
        let server = label(endpoint, y: 148, width: 340)
        server.font = .systemFont(ofSize: 13, weight: .semibold); server.lineBreakMode = .byTruncatingMiddle; server.toolTip = endpoint
        _ = label(prompt, y: 119, width: 340)
        password.frame = NSRect(x: 20, y: 86, width: 340, height: 26)
        contentView?.addSubview(password)
        remember.frame = NSRect(x: 20, y: 52, width: 340, height: 24)
        remember.isHidden = !canSave; remember.state = canSave && replaceSaved ? .on : .off
        contentView?.addSubview(remember)
        cancelButton(x: 170)
        let connect = NSButton(title: "Connect", target: self, action: #selector(submit(_:)))
        connect.bezelStyle = .rounded; connect.keyEquivalent = "\r"
        connect.frame = NSRect(x: 270, y: 16, width: 90, height: 28)
        contentView?.addSubview(connect)
        initialFirstResponder = password
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func submit(_ sender: Any?) {
        result = (password.stringValue, canSave && remember.state == .on)
        password.stringValue = ""
        finish(.OK)
    }
    func clearSecrets() { password.stringValue = "" }
}
