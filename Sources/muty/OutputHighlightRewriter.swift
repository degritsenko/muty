import Foundation
import Darwin
import SwiftTerm

/// Compiled highlight rules.
///
/// Literal rules are matched with a byte-level search over an ASCII-lowercased copy of each
/// text run (`memmem`), so a run is scanned once per keyword without unicode collation
/// overhead. Rules containing non-ASCII text, and all regular-expression rules, use
/// `String`/`NSRegularExpression` matching.
struct OutputHighlightRuleSet {
    struct LiteralRule {
        let pattern: String
        /// Lowercased ASCII bytes of the pattern, or `nil` when the pattern is not pure ASCII.
        let patternBytes: [UInt8]?
        let color: String
        let order: Int
        let requiresLeadingBoundary: Bool
        let requiresTrailingBoundary: Bool
    }

    struct RegexRule {
        let expression: NSRegularExpression
        let color: String
        let order: Int
    }

    /// Upper bound on matches considered for one text run. Keeps a very broad user rule
    /// (for example a single-letter literal or the IPv4 expression on IP-heavy output) from
    /// turning a 128 KB read into quadratic work on the main thread.
    static let maxCandidatesPerRun = 4096

    let literalRules: [LiteralRule]
    let regexRules: [RegexRule]

    var isEmpty: Bool { literalRules.isEmpty && regexRules.isEmpty }

    init(rules: [OutputHighlightRule]) {
        var literals: [LiteralRule] = []
        var expressions: [RegexRule] = []
        for (order, rule) in rules.enumerated() {
            guard rule.enabled, !rule.pattern.isEmpty else { continue }
            if rule.isRegex == true {
                guard let expression = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
                expressions.append(RegexRule(expression: expression, color: rule.color, order: order))
                continue
            }
            let wholeWord = rule.wholeWord == true
            let bytes = rule.pattern.utf8.allSatisfy { $0 < 0x80 } ? Array(rule.pattern.lowercased().utf8) : nil
            literals.append(LiteralRule(
                pattern: rule.pattern,
                patternBytes: bytes,
                color: rule.color,
                order: order,
                requiresLeadingBoundary: wholeWord && Self.startsWithWordCharacter(rule.pattern),
                requiresTrailingBoundary: wholeWord && Self.endsWithWordCharacter(rule.pattern)
            ))
        }
        literalRules = literals
        regexRules = expressions
    }

    private static func startsWithWordCharacter(_ pattern: String) -> Bool {
        pattern.first.map(isWordCharacter) ?? false
    }

    private static func endsWithWordCharacter(_ pattern: String) -> Bool {
        pattern.last.map(isWordCharacter) ?? false
    }

    fileprivate static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    fileprivate static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }

    fileprivate static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
    }

    /// Whether the UTF-8 character ending just before `end` is a word character. Decodes
    /// non-ASCII neighbours so `ERROR：` (full-width punctuation) is still a word boundary
    /// while `ERRORы` is not.
    fileprivate static func isWordCharacter(before end: Int, in bytes: [UInt8]) -> Bool {
        guard end > 0 else { return false }
        let last = bytes[end - 1]
        if last < 0x80 { return isWordByte(last) }
        var start = end - 1
        while start > 0 && bytes[start] >= 0x80 && bytes[start] < 0xC0 { start -= 1 }
        guard let character = String(bytes: bytes[start..<end], encoding: .utf8)?.first else { return true }
        return isWordCharacter(character)
    }

    /// Whether the UTF-8 character starting at `start` is a word character.
    fileprivate static func isWordCharacter(after start: Int, in bytes: [UInt8]) -> Bool {
        guard start < bytes.count else { return false }
        let first = bytes[start]
        if first < 0x80 { return isWordByte(first) }
        var end = start + 1
        while end < bytes.count && bytes[end] >= 0x80 && bytes[end] < 0xC0 { end += 1 }
        guard let character = String(bytes: bytes[start..<end], encoding: .utf8)?.first else { return true }
        return isWordCharacter(character)
    }
}

extension OutputHighlightRuleSet {
    struct FoundMatch {
        /// Byte range inside the text run.
        let range: Range<Int>
        let color: String
    }

    /// Finds non-overlapping matches in one run of plain terminal text. Earlier rules win,
    /// which mirrors MobaXterm's colour-bucket ordering.
    ///
    /// `leadingBoundary`/`trailingBoundary` describe whether a word boundary exists at the
    /// run edges: the run may continue a word rendered before an escape sequence or in the
    /// next read, or it may end before an escape sequence that does not break the word.
    func matches(in bytes: [UInt8], text: String, leadingBoundary: Bool,
                 trailingBoundary: Bool) -> [FoundMatch] {
        guard !bytes.isEmpty, !isEmpty else { return [] }
        var candidates: [(range: Range<Int>, color: String, order: Int)] = []

        let asciiRules = literalRules.filter { $0.patternBytes != nil }
        if !asciiRules.isEmpty {
            let lowered = bytes.map(Self.asciiLowercase)
            for rule in asciiRules {
                guard candidates.count < Self.maxCandidatesPerRun else { break }
                guard let needle = rule.patternBytes, needle.count <= lowered.count else { continue }
                var offset = 0
                while offset + needle.count <= lowered.count,
                      let start = Self.search(lowered, needle, from: offset) {
                    let end = start + needle.count
                    if Self.boundariesOK(rule, start: start, end: end, bytes: bytes,
                                         leadingBoundary: leadingBoundary,
                                         trailingBoundary: trailingBoundary) {
                        candidates.append((start..<end, rule.color, rule.order))
                        if candidates.count >= Self.maxCandidatesPerRun { break }
                    }
                    offset = start + 1
                }
            }
        }

        let unicodeRules = literalRules.filter { $0.patternBytes == nil }
        for rule in unicodeRules {
            guard candidates.count < Self.maxCandidatesPerRun else { break }
            var searchStart = text.startIndex
            var cursor = text.startIndex
            var byteCursor = 0
            while searchStart < text.endIndex,
                  let found = text.range(of: rule.pattern, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
                let start = byteCursor + text[cursor..<found.lowerBound].utf8.count
                let end = start + text[found].utf8.count
                if Self.unicodeBoundariesOK(rule, found, in: text,
                                            leadingBoundary: leadingBoundary,
                                            trailingBoundary: trailingBoundary) {
                    candidates.append((start..<end, rule.color, rule.order))
                }
                cursor = found.upperBound
                byteCursor = end
                searchStart = found.upperBound
                if candidates.count >= Self.maxCandidatesPerRun { break }
            }
        }

        let asciiOnly = bytes.allSatisfy { $0 < 0x80 }
        for rule in regexRules {
            guard candidates.count < Self.maxCandidatesPerRun else { break }
            var cursor = text.startIndex
            var byteCursor = 0
            rule.expression.enumerateMatches(in: text, options: [],
                                             range: NSRange(location: 0, length: text.utf16.count)) { result, _, stop in
                guard let range = result?.range, range.length > 0 else { return }
                if asciiOnly {
                    candidates.append((range.location..<NSMaxRange(range), rule.color, rule.order))
                } else if let stringRange = Range(range, in: text) {
                    let start = byteCursor + text[cursor..<stringRange.lowerBound].utf8.count
                    let end = start + text[stringRange].utf8.count
                    candidates.append((start..<end, rule.color, rule.order))
                    cursor = stringRange.upperBound
                    byteCursor = end
                }
                if candidates.count >= Self.maxCandidatesPerRun { stop.pointee = true }
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Earlier rules take precedence; within a rule, earlier matches are kept.
        candidates.sort { lhs, rhs in
            lhs.order == rhs.order ? lhs.range.lowerBound < rhs.range.lowerBound : lhs.order < rhs.order
        }
        var accepted: [(range: Range<Int>, color: String)] = []
        for candidate in candidates {
            var low = 0
            var high = accepted.count
            while low < high {
                let mid = (low + high) / 2
                if accepted[mid].range.lowerBound < candidate.range.lowerBound { low = mid + 1 } else { high = mid }
            }
            let overlapsPrevious = low > 0 && accepted[low - 1].range.upperBound > candidate.range.lowerBound
            let overlapsNext = low < accepted.count && accepted[low].range.lowerBound < candidate.range.upperBound
            if !overlapsPrevious && !overlapsNext {
                accepted.insert((candidate.range, candidate.color), at: low)
            }
        }
        return accepted.map { FoundMatch(range: $0.range, color: $0.color) }
    }

    private static func search(_ haystack: [UInt8], _ needle: [UInt8], from offset: Int) -> Int? {
        guard !needle.isEmpty, offset <= haystack.count - needle.count else { return nil }
        return haystack.withUnsafeBytes { haystackBuffer -> Int? in
            needle.withUnsafeBytes { needleBuffer -> Int? in
                guard let haystackBase = haystackBuffer.baseAddress,
                      let needleBase = needleBuffer.baseAddress else { return nil }
                guard let found = memmem(haystackBase.advanced(by: offset), haystackBuffer.count - offset,
                                         needleBase, needle.count) else { return nil }
                return UnsafeRawPointer(found) - UnsafeRawPointer(haystackBase)
            }
        }
    }

    private static func boundariesOK(_ rule: LiteralRule, start: Int, end: Int, bytes: [UInt8],
                                     leadingBoundary: Bool, trailingBoundary: Bool) -> Bool {
        if rule.requiresLeadingBoundary {
            if start == 0 {
                if !leadingBoundary { return false }
            } else if isWordCharacter(before: start, in: bytes) {
                return false
            }
        }
        if rule.requiresTrailingBoundary {
            if end == bytes.count {
                if !trailingBoundary { return false }
            } else if isWordCharacter(after: end, in: bytes) {
                return false
            }
        }
        return true
    }

    private static func unicodeBoundariesOK(_ rule: LiteralRule, _ range: Range<String.Index>, in text: String,
                                            leadingBoundary: Bool, trailingBoundary: Bool) -> Bool {
        if rule.requiresLeadingBoundary {
            if range.lowerBound == text.startIndex {
                if !leadingBoundary { return false }
            } else if isWordCharacter(text[text.index(before: range.lowerBound)]) {
                return false
            }
        }
        if rule.requiresTrailingBoundary {
            if range.upperBound == text.endIndex {
                if !trailingBoundary { return false }
            } else if isWordCharacter(text[range.upperBound]) {
                return false
            }
        }
        return true
    }
}

enum OutputHighlightSegment {
    /// Bytes that must be fed to the terminal untouched.
    case raw([UInt8])
    /// Plain text bytes that should be drawn in `color` while keeping the current background
    /// and character style. The applier wraps these bytes in foreground-only SGR sequences.
    case highlighted([UInt8], color: String)
}

/// Rewrites a terminal output stream so that keyword matches are drawn in a different
/// foreground colour, without changing the background, the character attributes, the bytes
/// kept for copy and the raw output written to session logs.
///
/// SwiftTerm 1.20 has no public per-cell text-colour hook (`draw` is not `open` and
/// `Attribute` has no public initializer), so MobaXterm-style foreground highlighting is
/// implemented on the bytes before the terminal parses them rather than in the renderer.
///
/// Known tradeoffs of the byte-stream approach, kept conservative on purpose:
/// - a keyword ending exactly at a read boundary is not highlighted with whole-word matching
///   (the next byte could continue the word); a read boundary is never treated as a word
///   boundary and text is never held back, so echo and prompts stay responsive;
/// - regular-expression rules are evaluated per text run, so `^`, `$` and trailing `\b`
///   refer to the run rather than the visual line;
/// - a text run whose UTF-8 sequence is split by a read boundary is passed through
///   unhighlighted;
/// - under inverse video (SGR 7) the terminal renders the injected foreground as the cell
///   background, so the match appears as a colour band there.
struct OutputHighlightTransformer {
    private enum ParserState {
        case ground
        case escape
        case escapeIntermediate
        case csi
        case osc
        case oscEscape
        case string
        case stringEscape
    }

    private var state: ParserState = .ground
    private var text: [UInt8] = []
    private var lastRenderedWasWord = false
    private var outputSegments: [OutputHighlightSegment] = []
    private var rawBytes: [UInt8] = []

    mutating func reset() {
        state = .ground
        text.removeAll(keepingCapacity: true)
        lastRenderedWasWord = false
        rawBytes.removeAll(keepingCapacity: true)
        outputSegments.removeAll(keepingCapacity: true)
    }

    mutating func process(_ bytes: ArraySlice<UInt8>, ruleSet: OutputHighlightRuleSet) -> [OutputHighlightSegment] {
        guard !bytes.isEmpty else { return [] }
        scan(bytes, ruleSet: ruleSet)
        return outputSegments
    }

    /// Advances parser state without producing output. Used while highlighting is disabled so
    /// that enabling it in the middle of an escape sequence cannot inject bytes into that
    /// sequence.
    mutating func consume(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        scan(bytes, ruleSet: nil)
    }

    private mutating func scan(_ bytes: ArraySlice<UInt8>, ruleSet: OutputHighlightRuleSet?) {
        outputSegments.removeAll(keepingCapacity: true)
        rawBytes.removeAll(keepingCapacity: true)
        var index = 0
        for byte in bytes {
            if state == .ground {
                switch byte {
                case 0x1B:
                    let nextIsWord = Self.nextRenderedCharacterIsWord(from: index, in: bytes)
                    flushText(trailingBoundary: nextIsWord == false, ruleSet: ruleSet)
                    rawBytes.append(byte)
                    state = .escape
                case 0x00...0x1F, 0x7F:
                    flushText(trailingBoundary: true, ruleSet: ruleSet)
                    rawBytes.append(byte)
                    lastRenderedWasWord = false
                default:
                    text.append(byte)
                }
            } else {
                rawBytes.append(byte)
                Self.advanceSequence(&state, byte)
            }
            index += 1
        }
        if state == .ground, !text.isEmpty {
            flushText(trailingBoundary: false, ruleSet: ruleSet)
        }
        if ruleSet != nil {
            flushRaw()
        } else {
            rawBytes.removeAll(keepingCapacity: true)
        }
    }

    private mutating func flushText(trailingBoundary: Bool, ruleSet: OutputHighlightRuleSet?) {
        guard !text.isEmpty else { return }
        let bytes = text
        text.removeAll(keepingCapacity: true)
        let leadingBoundary = !lastRenderedWasWord
        lastRenderedWasWord = OutputHighlightRuleSet.isWordCharacter(before: bytes.count, in: bytes)
        guard let ruleSet else { return }
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            // A UTF-8 sequence was cut by the read boundary: pass the run through untouched.
            rawBytes.append(contentsOf: bytes)
            return
        }
        let matches = ruleSet.matches(in: bytes, text: string, leadingBoundary: leadingBoundary,
                                      trailingBoundary: trailingBoundary)
        guard !matches.isEmpty else {
            rawBytes.append(contentsOf: bytes)
            return
        }
        flushRaw()
        var cursor = 0
        for match in matches {
            if cursor < match.range.lowerBound {
                outputSegments.append(.raw(Array(bytes[cursor..<match.range.lowerBound])))
            }
            outputSegments.append(.highlighted(Array(bytes[match.range]), color: match.color))
            cursor = match.range.upperBound
        }
        if cursor < bytes.count {
            rawBytes.append(contentsOf: bytes[cursor...])
        }
    }

    private mutating func flushRaw() {
        guard !rawBytes.isEmpty else { return }
        outputSegments.append(.raw(rawBytes))
        rawBytes.removeAll(keepingCapacity: true)
    }

    private static func advanceSequence(_ state: inout ParserState, _ byte: UInt8) {
        switch state {
        case .ground:
            return
        case .escape:
            switch byte {
            case 0x1B: state = .escape
            case 0x20...0x2F: state = .escapeIntermediate
            case 0x5B: state = .csi
            case 0x5D: state = .osc
            case 0x50, 0x58, 0x5E, 0x5F: state = .string
            default: state = .ground
            }
        case .escapeIntermediate:
            if byte == 0x1B { state = .escape }
            else if byte == 0x18 || byte == 0x1A { state = .ground }
            else if byte < 0x20 || byte > 0x2F { state = .ground }
        case .csi:
            if byte == 0x1B { state = .escape }
            else if byte == 0x18 || byte == 0x1A || (byte >= 0x40 && byte <= 0x7E) { state = .ground }
        case .osc:
            if byte == 0x07 || byte == 0x18 || byte == 0x1A {
                state = .ground
            } else if byte == 0x1B {
                state = .oscEscape
            }
        case .oscEscape:
            if byte == 0x5C || byte == 0x18 || byte == 0x1A {
                state = .ground
            } else if byte != 0x1B {
                state = .osc
            }
        case .string:
            if byte == 0x1B {
                state = .stringEscape
            } else if byte == 0x18 || byte == 0x1A {
                state = .ground
            }
        case .stringEscape:
            if byte == 0x5C || byte == 0x18 || byte == 0x1A {
                state = .ground
            } else if byte != 0x1B {
                state = .string
            }
        }
    }

    /// Looks ahead past the escape sequence starting at `index` (the ESC byte) and reports
    /// whether the next rendered character is a word character. `nil` means the chunk ends
    /// before that character is known.
    private static func nextRenderedCharacterIsWord(from index: Int, in bytes: ArraySlice<UInt8>) -> Bool? {
        var state = ParserState.escape
        var position = index + 1
        while position < bytes.count {
            let byte = bytes[position]
            if state == .ground {
                if byte == 0x1B {
                    state = .escape
                } else if byte < 0x20 || byte == 0x7F {
                    return false
                } else {
                    return byte < 0x80 ? OutputHighlightRuleSet.isWordByte(byte) : true
                }
            } else {
                advanceSequence(&state, byte)
            }
            position += 1
        }
        return nil
    }
}

enum OutputHighlightColorStyle {
    /// ANSI foreground SGR code used for a highlight colour name.
    static func sgrForegroundCode(for name: String) -> Int {
        switch name {
        case "Green": return 92
        case "Yellow": return 93
        case "Blue": return 94
        case "Magenta": return 95
        case "Cyan": return 96
        case "Purple": return 35
        case "Orange": return 33
        default: return 91
        }
    }

    static func sgr(for name: String) -> String {
        "\u{1B}[\(sgrForegroundCode(for: name))m"
    }

    /// Restores the foreground colour that was active before a highlighted run.
    ///
    /// SwiftTerm has no SGR spelling for the internal `.defaultInvertedColor` foreground, so
    /// it falls back to the default foreground (`39`).
    static func restoring(_ color: Attribute.Color) -> String {
        switch color {
        case .defaultColor, .defaultInvertedColor:
            return "\u{1B}[39m"
        case .ansi256(let code):
            if code < 8 { return "\u{1B}[\(30 + Int(code))m" }
            if code < 16 { return "\u{1B}[\(90 + Int(code) - 8)m" }
            return "\u{1B}[38;5;\(Int(code))m"
        case .trueColor(let red, let green, let blue):
            return "\u{1B}[38;2;\(Int(red));\(Int(green));\(Int(blue))m"
        }
    }
}

enum OutputHighlightApplier {
    /// Feeds transformed output through a terminal view so SwiftTerm's own feed pipeline
    /// (display scheduling, search invalidation, selection handling) runs exactly once per
    /// emitted segment. Only the foreground colour of highlighted runs changes; the previous
    /// colour is restored before the next raw bytes.
    static func feed(_ segments: [OutputHighlightSegment],
                     currentForeground: () -> Attribute.Color,
                     feed: ([UInt8]) -> Void) {
        for segment in segments {
            switch segment {
            case .raw(let bytes):
                feed(bytes)
            case .highlighted(let bytes, let color):
                var wrapped = Array(OutputHighlightColorStyle.sgr(for: color).utf8)
                wrapped.append(contentsOf: bytes)
                wrapped.append(contentsOf: OutputHighlightColorStyle.restoring(currentForeground()).utf8)
                feed(wrapped)
            }
        }
    }
}
