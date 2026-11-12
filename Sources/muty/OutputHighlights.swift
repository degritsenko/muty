import SwiftUI
import AppKit

struct OutputHighlightRule: Codable, Identifiable {
    /// Rule format written by an earlier highlighting attempt (`patternType` instead of the
    /// `wholeWord`/`isRegex` pair). Loaded and migrated so saved rules keep their meaning.
    private enum LegacyPatternType: String, Codable {
        case wholeWord = "Whole Word"
        case literal = "Literal"
        case regex = "Regex"
    }

    private enum CodingKeys: String, CodingKey {
        case id, pattern, color, enabled, wholeWord, isRegex, patternType
    }

    var id = UUID()
    var pattern: String
    var color = "Red"
    var enabled = true
    var wholeWord: Bool?
    var isRegex: Bool?

    init(pattern: String, color: String = "Red", enabled: Bool = true,
         wholeWord: Bool? = nil, isRegex: Bool? = nil) {
        self.pattern = pattern
        self.color = color
        self.enabled = enabled
        self.wholeWord = wholeWord
        self.isRegex = isRegex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? "Red"
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        wholeWord = try container.decodeIfPresent(Bool.self, forKey: .wholeWord)
        isRegex = try container.decodeIfPresent(Bool.self, forKey: .isRegex)
        if let legacy = try container.decodeIfPresent(LegacyPatternType.self, forKey: .patternType) {
            switch legacy {
            case .wholeWord:
                wholeWord = true
                isRegex = nil
            case .literal:
                wholeWord = nil
                isRegex = nil
            case .regex:
                wholeWord = nil
                isRegex = true
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(pattern, forKey: .pattern)
        try container.encode(color, forKey: .color)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(wholeWord, forKey: .wholeWord)
        try container.encodeIfPresent(isRegex, forKey: .isRegex)
    }
}

@MainActor final class OutputHighlightStore: ObservableObject {
    static let shared = OutputHighlightStore()
    static let maxRules = 96

    private enum Keys {
        static let enabled = "outputHighlightsEnabled"
        static let rules = "outputHighlightRules"
    }

    // Keyword-coloured output, similar to MobaXterm's built-in syntax highlighting.
    static let commonRules: [OutputHighlightRule] = [
        .init(pattern: "ERROR", wholeWord: true),
        .init(pattern: "ERR", wholeWord: true),
        .init(pattern: "FAIL", wholeWord: true),
        .init(pattern: "FAILED", wholeWord: true),
        .init(pattern: "FAILURE", wholeWord: true),
        .init(pattern: "FATAL", wholeWord: true),
        .init(pattern: "CRITICAL", wholeWord: true),
        .init(pattern: "PANIC", wholeWord: true),
        .init(pattern: "EXCEPTION", wholeWord: true),
        .init(pattern: "DENIED", wholeWord: true),
        .init(pattern: "REFUSED", wholeWord: true),
        .init(pattern: "TIMEOUT", wholeWord: true),
        .init(pattern: "TIMED OUT", wholeWord: true),
        .init(pattern: "UNREACHABLE", wholeWord: true),
        .init(pattern: "PERMISSION DENIED", wholeWord: true),
        .init(pattern: "CONNECTION REFUSED", wholeWord: true),
        .init(pattern: "SEGMENTATION FAULT", wholeWord: true),
        .init(pattern: "OUT OF MEMORY", wholeWord: true),
        .init(pattern: "CORRUPTED", wholeWord: true),
        .init(pattern: "INVALID", wholeWord: true),
        .init(pattern: "UNSUPPORTED", wholeWord: true),
        .init(pattern: "ABORTED", wholeWord: true),
        .init(pattern: "NOT PERMITTED", wholeWord: true),
        .init(pattern: "NO SUCH FILE", wholeWord: true),
        .init(pattern: "WARNING", color: "Yellow", wholeWord: true),
        .init(pattern: "WARN", color: "Yellow", wholeWord: true),
        .init(pattern: "CANNOT", color: "Yellow", wholeWord: true),
        .init(pattern: "COULD NOT", color: "Yellow", wholeWord: true),
        .init(pattern: "UNABLE TO", color: "Yellow", wholeWord: true),
        .init(pattern: "NOT FOUND", color: "Yellow", wholeWord: true),
        .init(pattern: "UNEXPECTED", color: "Yellow", wholeWord: true),
        .init(pattern: "UNKNOWN", color: "Yellow", wholeWord: true),
        .init(pattern: "DISABLED", color: "Yellow", wholeWord: true),
        .init(pattern: "DISCONNECTED", color: "Yellow", wholeWord: true),
        .init(pattern: "DEPRECATED", color: "Yellow", wholeWord: true),
        .init(pattern: "RETRY", color: "Yellow", wholeWord: true),
        .init(pattern: "RETRYING", color: "Yellow", wholeWord: true),
        .init(pattern: "PENDING", color: "Yellow", wholeWord: true),
        .init(pattern: "TERMINATED", color: "Yellow", wholeWord: true),
        .init(pattern: "STOPPED", color: "Yellow", wholeWord: true),
        .init(pattern: "OUT OF SPACE", color: "Yellow", wholeWord: true),
        .init(pattern: "SUCCESS", color: "Green", wholeWord: true),
        .init(pattern: "SUCCESSFUL", color: "Green", wholeWord: true),
        .init(pattern: "SUCCEEDED", color: "Green", wholeWord: true),
        .init(pattern: "OK", color: "Green", wholeWord: true),
        .init(pattern: "ACCEPTED", color: "Green", wholeWord: true),
        .init(pattern: "ALLOWED", color: "Green", wholeWord: true),
        .init(pattern: "ENABLED", color: "Green", wholeWord: true),
        .init(pattern: "CONNECTED", color: "Green", wholeWord: true),
        .init(pattern: "READY", color: "Green", wholeWord: true),
        .init(pattern: "DONE", color: "Green", wholeWord: true),
        .init(pattern: "PASSED", color: "Green", wholeWord: true),
        .init(pattern: "INFO", color: "Cyan", wholeWord: true),
        .init(pattern: "NOTICE", color: "Cyan", wholeWord: true),
        .init(pattern: "LOADING", color: "Cyan", wholeWord: true),
        .init(pattern: "STARTING", color: "Cyan", wholeWord: true),
        .init(pattern: "CHECKING", color: "Cyan", wholeWord: true),
        .init(pattern: "CREATED", color: "Cyan", wholeWord: true),
        .init(pattern: "BUILDING", color: "Cyan", wholeWord: true),
        .init(pattern: "LAUNCHING", color: "Cyan", wholeWord: true),
        .init(pattern: "DEBUG", color: "Blue", wholeWord: true),
        .init(pattern: "TRACE", color: "Purple", wholeWord: true),
        .init(pattern: "LOCALHOST", color: "Magenta", wholeWord: true),
        .init(pattern: "NULL", color: "Magenta", wholeWord: true),
        .init(pattern: "NONE", color: "Magenta", wholeWord: true),
        .init(pattern: "\\b\\d{1,3}(?:\\.\\d{1,3}){3}\\b", color: "Magenta", wholeWord: true, isRegex: true)
    ]

    private let defaults: UserDefaults
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    @Published var rules: [OutputHighlightRule] {
        didSet {
            if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: Keys.rules) }
            rebuildRuleSet()
        }
    }
    private(set) var ruleSet = OutputHighlightRuleSet(rules: [])

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // An absent key means the feature was never deliberately disabled, so
        // highlighting starts enabled and only an explicit opt-out turns it off.
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.rules),
           let decoded = try? JSONDecoder().decode([OutputHighlightRule].self, from: data) {
            rules = decoded
            // Rules saved by an earlier implementation used a `patternType` schema. The
            // decoder migrates them; rewrite the stored JSON once so the old shape is gone.
            if data.range(of: Data("\"patternType\"".utf8)) != nil,
               let normalized = try? JSONEncoder().encode(decoded) {
                defaults.set(normalized, forKey: Keys.rules)
            }
        } else {
            rules = Self.commonRules
        }
        rebuildRuleSet()
    }

    var missingCommonRules: [OutputHighlightRule] {
        Self.commonRules.filter { preset in
            !rules.contains { $0.pattern.caseInsensitiveCompare(preset.pattern) == .orderedSame }
        }
    }

    private func rebuildRuleSet() {
        ruleSet = OutputHighlightRuleSet(rules: Array(rules.prefix(Self.maxRules)))
    }

    static func color(_ name: String) -> NSColor {
        switch name {
        case "Orange": return .systemOrange
        case "Yellow": return .systemYellow
        case "Green": return .systemGreen
        case "Cyan": return .systemCyan
        case "Blue": return .systemBlue
        case "Magenta": return .magenta
        case "Purple": return .systemPurple
        default: return .systemRed
        }
    }
}

struct OutputHighlightSettings: View {
    @ObservedObject private var store = OutputHighlightStore.shared
    @ViewState private var editing: OutputHighlightRule?
    @ViewState private var deleting: OutputHighlightRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Highlight terminal output", isOn: $store.enabled)
            Text("Highlighting applies to new terminal output.").font(.caption).foregroundStyle(.secondary)
                .help("Matches are case-insensitive. Only foreground color changes; copied text and logs are unchanged.")
            List {
                ForEach($store.rules) { $rule in
                    HStack {
                        Toggle("Enabled", isOn: $rule.enabled).labelsHidden().help("Enable rule")
                        Text(rule.pattern.isEmpty ? "Empty pattern" : rule.pattern).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Circle().fill(Color(nsColor: OutputHighlightStore.color(rule.color))).frame(width: 9, height: 9)
                        Text(rule.color).frame(width: 65, alignment: .leading)
                        Text(rule.isRegex == true ? "Regex" : (rule.wholeWord == true ? "Whole word" : "Text"))
                            .font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        Button("Edit") { editing = rule }
                        Menu {
                            Button("Duplicate") {
                                var copy = rule; copy.id = UUID(); editing = copy
                            }.disabled(store.rules.count >= OutputHighlightStore.maxRules)
                            Button("Delete…", role: .destructive) { deleting = rule }
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("Rule actions")
                    }
                }
            }
            HStack {
                Button("Add Rule") { editing = OutputHighlightRule(pattern: "") }.disabled(store.rules.count >= OutputHighlightStore.maxRules)
                Button("Add Common Rules") {
                    store.rules.append(contentsOf: store.missingCommonRules.prefix(max(0, OutputHighlightStore.maxRules - store.rules.count)))
                }.disabled(store.rules.count >= OutputHighlightStore.maxRules || store.missingCommonRules.isEmpty)
            }
        }.padding(14)
        .sheet(item: $editing) { rule in
            HighlightRuleEditor(rule: rule) { updated in
                if let index = store.rules.firstIndex(where: { $0.id == updated.id }) { store.rules[index] = updated }
                else if store.rules.count < OutputHighlightStore.maxRules { store.rules.append(updated) }
            }
        }
        .alert("Delete Highlight Rule?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let id = deleting?.id { store.rules.removeAll { $0.id == id } }
                deleting = nil
            }
        } message: { Text(deleting?.pattern ?? "") }
    }
}

private struct HighlightRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var rule: OutputHighlightRule
    @ViewState private var previewText = "ERROR: connection failed"
    let save: (OutputHighlightRule) -> Void

    init(rule: OutputHighlightRule, save: @escaping (OutputHighlightRule) -> Void) {
        _rule = State(initialValue: rule); self.save = save
    }
    private var regexError: String? {
        guard rule.isRegex == true, !rule.pattern.isEmpty else { return nil }
        do { _ = try NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]); return nil }
        catch { return error.localizedDescription }
    }
    private var preview: AttributedString {
        var result = AttributedString(previewText)
        var enabledRule = rule; enabledRule.enabled = true
        let bytes = Array(previewText.utf8)
        let matches = OutputHighlightRuleSet(rules: [enabledRule]).matches(in: bytes, text: previewText, leadingBoundary: true, trailingBoundary: true)
        for match in matches {
            guard let lowerUTF8 = previewText.utf8.index(previewText.utf8.startIndex, offsetBy: match.range.lowerBound, limitedBy: previewText.utf8.endIndex),
                  let upperUTF8 = previewText.utf8.index(previewText.utf8.startIndex, offsetBy: match.range.upperBound, limitedBy: previewText.utf8.endIndex),
                  let lower = String.Index(lowerUTF8, within: previewText), let upper = String.Index(upperUTF8, within: previewText),
                  let start = AttributedString.Index(lower, within: result), let end = AttributedString.Index(upper, within: result) else { continue }
            result[start..<end].foregroundColor = Color(nsColor: OutputHighlightStore.color(rule.color))
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Highlight Rule").font(.headline)
            TextField("Pattern", text: $rule.pattern)
            if let regexError { Text(regexError).font(.caption).foregroundStyle(.red) }
            Picker("Match", selection: Binding(get: { rule.isRegex == true }, set: { rule.isRegex = $0; if $0 { rule.wholeWord = false } })) {
                Text("Text").tag(false); Text("Regular expression").tag(true)
            }
            Toggle("Whole word", isOn: Binding(get: { rule.wholeWord == true }, set: { rule.wholeWord = $0 })).disabled(rule.isRegex == true)
            Picker("Color", selection: $rule.color) {
                ForEach(["Red", "Yellow", "Green", "Cyan", "Blue", "Magenta", "Purple", "Orange"], id: \.self) { Text($0).tag($0) }
            }
            Toggle("Enabled", isOn: $rule.enabled)
            TextField("Preview text", text: $previewText)
            Text(preview).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(rule); dismiss() }.keyboardShortcut(.defaultAction).disabled(rule.pattern.isEmpty || regexError != nil)
            }
        }.padding(20).frame(width: 460)
    }
}
