import AppKit
import TabCore
import TabProtocol

/// Existing app color roles transported to the conversation, without another theme catalog.
struct AgentConversationTheme: Equatable {
    let mode: String
    private let scheme: ColorScheme
    private let chrome: ChromePalette
    let colors: [String: String]
    let syntax: [String: String]
    let ansi16: [String]

    @MainActor
    init(_ theme: AppTheme) {
        mode = theme.palette.isLight ? "light" : "dark"
        scheme = theme.scheme
        chrome = theme.palette
        let roles: [String: NSColor] = [
            // The conversation occupies a pane, like TerminalPane. The raw
            // scheme background belongs behind pane cards in dark themes.
            "background": theme.card, "foreground": theme.fg,
            "mutedForeground": theme.fgMuted, "dimForeground": theme.fgDim,
            "surface": theme.surface, "border": theme.border, "hover": theme.hover,
            "accent": theme.accent, "accentSoft": theme.accentSoft,
            "accentForeground": theme.accentForeground, "warning": theme.warning,
            "danger": theme.danger, "diffAdd": theme.diffAdd, "diffRemove": theme.diffRemove,
            "diffHunk": theme.diffHunk, "card": theme.card, "cardBorder": theme.cardBorder,
            "raised": theme.raised, "floating": theme.floating, "selection": theme.selection,
        ]
        colors = roles.mapValues(Self.css)
        let tokens = theme.syntaxColors
        var tokenColors = Dictionary(uniqueKeysWithValues: TokenKind.allCases.map {
            (String(describing: $0), Self.css(tokens.color($0)))
        })
        tokenColors["foreground"] = Self.css(tokens.foreground.nsColor)
        syntax = tokenColors
        let terminal = TerminalPalette(scheme: theme.scheme, options: TerminalOptions(), dark: !theme.palette.isLight)
        ansi16 = terminal.colors.prefix(16).map { RGBColor($0).hex }
    }

    var payload: [String: Any] {
        var value: [String: Any] = colors
        value["syntax"] = syntax
        value["ansi16"] = ansi16
        return value
    }

    static func css(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return "rgba(\(rgb.redComponent * 255),\(rgb.greenComponent * 255),\(rgb.blueComponent * 255),\(rgb.alphaComponent))"
    }
}
