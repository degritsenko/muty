import AppKit

struct MultilinePasteOptions {
    var confirm = true
    var delayEnabled = false
    var delayMilliseconds = 5
    static func load() -> Self {
        let defaults = UserDefaults.standard
        let delay = defaults.object(forKey: "multilinePasteDelayMilliseconds") as? Int ?? 5
        return Self(confirm: defaults.object(forKey: "confirmMultilinePaste") as? Bool ?? true,
                    delayEnabled: defaults.bool(forKey: "multilinePasteDelayEnabled"),
                    delayMilliseconds: max(0, min(1000, delay)))
    }
    func save() {
        UserDefaults.standard.set(confirm, forKey: "confirmMultilinePaste")
        UserDefaults.standard.set(delayEnabled, forKey: "multilinePasteDelayEnabled")
        UserDefaults.standard.set(delayMilliseconds, forKey: "multilinePasteDelayMilliseconds")
    }
}

@MainActor final class MultilinePastePanel: CancellableModalPanel, NSTextFieldDelegate {
    private let preview = NSTextView()
    private let dontShow = NSButton(checkboxWithTitle: "Do not show this dialog again", target: nil, action: nil)
    private let delayEnabled = NSButton(checkboxWithTitle: "Override line send delay:", target: nil, action: nil)
    private let delay = NSTextField()
    private let stepper = NSStepper()
    private(set) var result: MultilinePasteOptions?
    private(set) var pastedText: String?

    init(text: String, options: MultilinePasteOptions) {
        super.init(title: "Confirm Multi-line Paste", width: 840, height: 420)
        _ = label("Clipboard contents:", y: 382, width: 680)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 65, width: 680, height: 300))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        preview.frame = NSRect(x: 0, y: 0, width: 680, height: 300)
        preview.isEditable = true; preview.isSelectable = true; preview.isRichText = false
        preview.allowsUndo = true
        preview.isAutomaticQuoteSubstitutionEnabled = false
        preview.isAutomaticDashSubstitutionEnabled = false
        preview.isAutomaticTextReplacementEnabled = false
        preview.isAutomaticSpellingCorrectionEnabled = false
        preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.string = text
        preview.textContainerInset = NSSize(width: 6, height: 6)
        preview.isHorizontallyResizable = true; preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        preview.minSize = NSSize(width: 680, height: 300)
        preview.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        preview.textContainer?.containerSize = preview.maxSize
        preview.textContainer?.widthTracksTextView = false
        scroll.documentView = preview; contentView?.addSubview(scroll)
        let paste = NSButton(title: "Paste", target: self, action: #selector(submit(_:)))
        paste.bezelStyle = .rounded; paste.keyEquivalent = "\r"
        paste.frame = NSRect(x: 715, y: 336, width: 105, height: 30)
        contentView?.addSubview(paste)
        cancelButton(x: 723, y: 296)
        dontShow.frame = NSRect(x: 20, y: 23, width: 300, height: 22)
        contentView?.addSubview(dontShow)
        delayEnabled.frame = NSRect(x: 340, y: 23, width: 210, height: 22)
        delayEnabled.state = options.delayEnabled ? .on : .off
        delayEnabled.target = self; delayEnabled.action = #selector(refresh(_:))
        contentView?.addSubview(delayEnabled)
        let formatter = NumberFormatter()
        formatter.numberStyle = .none; formatter.allowsFloats = false
        formatter.minimum = 0; formatter.maximum = 1000
        delay.delegate = self
        delay.formatter = formatter; delay.integerValue = options.delayMilliseconds
        delay.frame = NSRect(x: 555, y: 22, width: 55, height: 24)
        contentView?.addSubview(delay)
        stepper.minValue = 0; stepper.maxValue = 1000; stepper.increment = 1
        stepper.integerValue = options.delayMilliseconds
        stepper.target = self; stepper.action = #selector(step(_:))
        stepper.frame = NSRect(x: 615, y: 21, width: 19, height: 26)
        contentView?.addSubview(stepper)
        _ = label("milliseconds", x: 644, y: 23, width: 160)
        initialFirstResponder = preview
        refresh(nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func refresh(_ sender: Any?) {
        delay.isEnabled = delayEnabled.state == .on; stepper.isEnabled = delay.isEnabled
    }
    func controlTextDidChange(_ notification: Notification) { stepper.integerValue = max(0, min(1000, delay.integerValue)) }
    @objc private func step(_ sender: Any?) { delay.integerValue = stepper.integerValue }
    @objc private func submit(_ sender: Any?) {
        guard makeFirstResponder(nil) else { return }
        pastedText = preview.string
        result = MultilinePasteOptions(confirm: dontShow.state != .on,
                                       delayEnabled: delayEnabled.state == .on,
                                       delayMilliseconds: max(0, min(1000, delay.integerValue)))
        finish(.OK)
    }
    func clearContents() { preview.string = ""; pastedText = nil }
}
