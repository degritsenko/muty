import Foundation

struct TerminalSettings: Equatable {
    var fontSize: Double
    var scrollback: Int
    var theme: String
    var optionAsMetaKey: Bool
    var fontName: String

    static func resolve(
        profileTheme: String?, fontSize: Double, scrollback: Double, globalTheme: String,
        optionAsMetaKey: Bool, fontName: String
    ) -> Self {
        Self(
            fontSize: min(30, max(9, fontSize.isFinite ? fontSize : 13)),
            scrollback: Int(scrollback.isFinite ? max(1000, min(50000, scrollback)) : 10000),
            theme: profileTheme ?? globalTheme,
            optionAsMetaKey: optionAsMetaKey,
            fontName: fontName
        )
    }
}
