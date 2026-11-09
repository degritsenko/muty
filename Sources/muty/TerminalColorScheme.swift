import AppKit
import SwiftTerm

enum TerminalColorScheme: String, CaseIterable, Identifiable {
    case mutyDark
    case mutyLight
    case solarizedDark
    case solarizedLight
    case dracula
    case nord
    case monokai
    case gruvboxDark
    case gruvboxLight
    case oneDark
    case oneLight
    case tokyoNight
    case catppuccinMocha
    case catppuccinLatte
    case everforestDark
    case tango

    var id: String { rawValue }

    var name: String {
        switch self {
        case .mutyDark: "Muty Dark"
        case .mutyLight: "Muty Light"
        case .solarizedDark: "Solarized Dark"
        case .solarizedLight: "Solarized Light"
        case .dracula: "Dracula"
        case .nord: "Nord"
        case .monokai: "Monokai"
        case .gruvboxDark: "Gruvbox Dark"
        case .gruvboxLight: "Gruvbox Light"
        case .oneDark: "One Dark"
        case .oneLight: "One Light"
        case .tokyoNight: "Tokyo Night"
        case .catppuccinMocha: "Catppuccin Mocha"
        case .catppuccinLatte: "Catppuccin Latte"
        case .everforestDark: "Everforest Dark"
        case .tango: "Tango"
        }
    }

    private var definition: (background: UInt32, foreground: UInt32, ansi: [UInt32]?) {
        switch self {
        case .mutyDark:
            (0x0E1116, 0xE6E6E6, nil)
        case .mutyLight:
            (0xFAFAFA, 0x141414, nil)
        case .solarizedDark:
            (0x002B36, 0x839496, [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                                  0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3])
        case .solarizedLight:
            (0xFDF6E3, 0x657B83, [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                                  0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3])
        case .dracula:
            (0x282A36, 0xF8F8F2, [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                                  0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF])
        case .nord:
            (0x2E3440, 0xD8DEE9, [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                                  0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4])
        case .monokai:
            (0x272822, 0xF8F8F2, [0x272822, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
                                  0x75715E, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF9F8F5])
        case .gruvboxDark:
            (0x282828, 0xEBDBB2, [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                                  0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2])
        case .gruvboxLight:
            (0xFBF1C7, 0x3C3836, [0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
                                  0x928374, 0x9D0006, 0x79740E, 0xB57614, 0x076678, 0x8F3F71, 0x427B58, 0x3C3836])
        case .oneDark:
            (0x282C34, 0xABB2BF, [0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
                                  0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF])
        case .oneLight:
            (0xFAFAFA, 0x383A42, [0x383A42, 0xE45649, 0x50A14F, 0xC18401, 0x0184BC, 0xA626A4, 0x0997B3, 0xFAFAFA,
                                  0xA0A1A7, 0xE45649, 0x50A14F, 0xC18401, 0x0184BC, 0xA626A4, 0x0997B3, 0xFFFFFF])
        case .tokyoNight:
            (0x1A1B26, 0xA9B1D6, [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                                  0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5])
        case .catppuccinMocha:
            (0x1E1E2E, 0xCDD6F4, [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
                                  0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8])
        case .catppuccinLatte:
            (0xEFF1F5, 0x4C4F69, [0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
                                  0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC])
        case .everforestDark:
            (0x2D353B, 0xD3C6AA, [0x343F44, 0xE67E80, 0xA7C080, 0xDBBC7F, 0x7FBBB3, 0xD699B6, 0x83C092, 0xD3C6AA,
                                  0x3D484D, 0xE67E80, 0xA7C080, 0xDBBC7F, 0x7FBBB3, 0xD699B6, 0x83C092, 0xD3C6AA])
        case .tango:
            (0x2E3436, 0xD3D7CF, [0x2E3436, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
                                  0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC])
        }
    }

    var background: NSColor { Self.nsColor(hex: definition.background) }
    var foreground: NSColor { Self.nsColor(hex: definition.foreground) }
    var previewColors: [NSColor] {
        let colors = ansiColors
        return [1, 2, 4, 6, 5].map { index in
            let color = colors[index]
            return NSColor(calibratedRed: CGFloat(color.red) / 65535,
                           green: CGFloat(color.green) / 65535,
                           blue: CGFloat(color.blue) / 65535,
                           alpha: 1)
        }
    }

    var ansiColors: [SwiftTerm.Color] {
        guard let values = definition.ansi else {
            return SwiftTerm.Color.terminalAppColors.map { SwiftTerm.Color(red: $0.red, green: $0.green, blue: $0.blue) }
        }
        return values.map { hex in
            SwiftTerm.Color(red8: UInt16((hex >> 16) & 0xFF),
                            green8: UInt16((hex >> 8) & 0xFF),
                            blue8: UInt16(hex & 0xFF))
        }
    }

    static func resolve(_ id: String) -> TerminalColorScheme {
        if let scheme = TerminalColorScheme(rawValue: id) { return scheme }
        switch id {
        case "Light": return .mutyLight
        default: return .mutyDark
        }
    }

    private static func nsColor(hex: UInt32) -> NSColor {
        NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}
