import SwiftUI
import AppKit
import SwiftTerm

struct OutputHighlightRule: Codable, Identifiable {
    var id = UUID()
    var pattern: String
    var color = "Red"
    var enabled = true
    var wholeWord: Bool?
}
@MainActor final class OutputHighlightStore: ObservableObject {
    static let shared = OutputHighlightStore()
    private static let commonRules: [OutputHighlightRule] = [
        .init(pattern: "ERROR", wholeWord: true), .init(pattern: "FAIL", wholeWord: true),
        .init(pattern: "FAILED", wholeWord: true), .init(pattern: "CRITICAL", wholeWord: true),
        .init(pattern: "FATAL", wholeWord: true),
        .init(pattern: "WARNING", color: "Yellow", wholeWord: true),
        .init(pattern: "WARN", color: "Yellow", wholeWord: true),
        .init(pattern: "PENDING", color: "Yellow", wholeWord: true),
        .init(pattern: "RETRY", color: "Yellow", wholeWord: true),
        .init(pattern: "SUCCESS", color: "Green", wholeWord: true),
        .init(pattern: "OK", color: "Green", wholeWord: true),
        .init(pattern: "READY", color: "Green", wholeWord: true),
        .init(pattern: "RUNNING", color: "Green", wholeWord: true),
        .init(pattern: "INFO", color: "Cyan", wholeWord: true),
        .init(pattern: "DEBUG", color: "Blue", wholeWord: true),
        .init(pattern: "TRACE", color: "Purple", wholeWord: true),
        .init(pattern: "Permission denied"), .init(pattern: "Connection refused"),
        .init(pattern: "timed out", color: "Yellow")
    ]
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "outputHighlightsEnabled") } }
    @Published var rules: [OutputHighlightRule] { didSet { if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "outputHighlightRules") } } }
    init() {
        enabled = UserDefaults.standard.bool(forKey: "outputHighlightsEnabled")
        rules = UserDefaults.standard.data(forKey: "outputHighlightRules").flatMap { try? JSONDecoder().decode([OutputHighlightRule].self, from: $0) }
            ?? Self.commonRules
    }
    var missingCommonRules: [OutputHighlightRule] {
        Self.commonRules.filter { preset in
            !rules.contains { $0.pattern.caseInsensitiveCompare(preset.pattern) == .orderedSame }
        }
    }
    static func color(_ name: String) -> NSColor {
        switch name {
        case "Orange": return .systemOrange
        case "Yellow": return .systemYellow
        case "Green": return .systemGreen
        case "Cyan": return .systemCyan
        case "Blue": return .systemBlue
        case "Purple": return .systemPurple
        default: return .systemRed
        }
    }
}
struct OutputHighlightSettings: View {
    @ObservedObject private var store = OutputHighlightStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Highlight terminal output", isOn: $store.enabled)
            Text("Case-insensitive literal matches. Highlights affect display only; copied text and session logs remain unchanged.").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach($store.rules) { $rule in
                    HStack {
                        Toggle("Enabled", isOn: $rule.enabled).labelsHidden()
                        TextField("Text to highlight", text: $rule.pattern)
                        Toggle("Whole word", isOn: Binding(
                            get: { rule.wholeWord == true },
                            set: { rule.wholeWord = $0 }
                        ))
                        Picker("Color", selection: $rule.color) {
                            ForEach(["Red", "Yellow", "Green", "Cyan", "Blue", "Purple"], id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 100)
                        Button { store.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus") }
                    }
                }
            }
            HStack {
                Button("Add Rule") { if store.rules.count < 32 { store.rules.append(.init(pattern: "")) } }
                    .disabled(store.rules.count >= 32)
                Button("Add Common Rules") {
                    store.rules.append(contentsOf: store.missingCommonRules.prefix(max(0, 32 - store.rules.count)))
                }.disabled(store.rules.count >= 32 || store.missingCommonRules.isEmpty)
            }
        }.padding(14)
    }
}

@MainActor final class OutputHighlightOverlay: NSView {
    weak var terminal: ReconnectTerminalView?
    private var timer: Timer?
    private var rectangles: [(CGRect, NSColor)] = []
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); timer?.invalidate(); timer = nil
        if window != nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }
    deinit { timer?.invalidate() }
    private func refresh() {
        guard let terminal, window != nil, !terminal.isHiddenOrHasHiddenAncestor, terminal.highlightVisible else {
            if !rectangles.isEmpty { rectangles = []; needsDisplay = true }; return
        }
        let store = OutputHighlightStore.shared
        guard store.enabled else { if !rectangles.isEmpty { rectangles = []; needsDisplay = true }; return }
        let engine = terminal.getTerminal(), size = terminal.getOptimalFrameSize()
        guard engine.cols > 0, engine.rows > 0 else { return }
        let height = size.height / CGFloat(engine.rows)
        let width = ("M" as NSString).size(withAttributes: [.font: terminal.font]).width
        let rules = store.rules.prefix(32).filter { $0.enabled && !$0.pattern.isEmpty }.map { rule in
            let wordPattern = "\\b" + NSRegularExpression.escapedPattern(for: rule.pattern) + "\\b"
            let expression = rule.wholeWord == true
                ? try? NSRegularExpression(pattern: wordPattern, options: .caseInsensitive)
                : nil
            return (rule, expression)
        }
        var result: [(CGRect, NSColor)] = []
        for row in 0..<engine.rows {
            guard let line = engine.getLine(row: row) else { continue }
            var text = "", offsets: [(Int, Int, Int)] = []
            for col in 0..<engine.cols {
                let cell = line[col]
                guard cell.width > 0 else { continue }
                let char = String(engine.getCharacter(for: cell)), start = text.utf16.count
                text += char; offsets.append((start, col, max(1, Int(cell.width))))
            }
            let value = text as NSString
            for (rule, expression) in rules {
                var search = NSRange(location: 0, length: value.length)
                while search.length > 0 {
                    let match: NSRange
                    if let expression {
                        guard let result = expression.firstMatch(in: text, options: .withTransparentBounds, range: search) else { break }
                        match = result.range
                    } else {
                        match = value.range(of: rule.pattern, options: .caseInsensitive, range: search)
                    }
                    if match.location == NSNotFound { break }
                    let cells = offsets.filter { $0.0 >= match.location && $0.0 < NSMaxRange(match) }
                    if let first = cells.first, let last = cells.last {
                        result.append((CGRect(x: CGFloat(first.1) * width, y: bounds.height - CGFloat(row + 1) * height,
                                              width: CGFloat(last.1 + last.2 - first.1) * width, height: height), OutputHighlightStore.color(rule.color).withAlphaComponent(0.3)))
                    }
                    search = NSRange(location: NSMaxRange(match), length: value.length - NSMaxRange(match))
                    if result.count >= 1000 { break }
                }
                if result.count >= 1000 { break }
            }
            if result.count >= 1000 { break }
        }
        rectangles = result; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        for (rect, color) in rectangles where rect.intersects(dirtyRect) { color.setFill(); rect.fill() }
    }
}
