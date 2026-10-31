import AppKit

/// Conversation roles from the selected app theme, shared with the native shell.
@MainActor
struct AgentMarkdownPalette {
    let heading: NSColor
    let body: NSColor
    let muted: NSColor
    let link: NSColor
    let border: NSColor
    let divider: NSColor
    let quoteRule: NSColor
    let tableRule: NSColor
    let inlineCodeBackground: NSColor

    init(theme: AppTheme) {
        heading = theme.fg
        body = theme.fg
        muted = theme.fgMuted
        link = theme.accent
        border = theme.border
        divider = theme.border
        quoteRule = theme.border
        tableRule = theme.border
        inlineCodeBackground = theme.selection
    }
}
