import AppKit

/// Colors and fonts a diagram draws with. Supplied by the conversation from the app theme.
struct AgentDiagramStyle {
    var font: NSFont = AppFont.system(12)
    var monoFont: NSFont = AppFont.mono(11)
    var foreground: NSColor = .labelColor
    var muted: NSColor = .secondaryLabelColor
    var surface: NSColor = .controlBackgroundColor
    var border: NSColor = .separatorColor
    var accent: NSColor = .controlAccentColor
    var accentSoft: NSColor = NSColor.controlAccentColor.withAlphaComponent(0.15)
    var warning: NSColor = .systemOrange
    var danger: NSColor = .systemRed
    /// Series colors for pie slices and multi-actor diagrams; the first is `accent`.
    var series: [NSColor] = [.controlAccentColor, .systemTeal, .systemPurple, .systemOrange, .systemGreen, .systemPink, .systemYellow, .systemIndigo]
}

/// A diagram source that cannot be drawn. The conversation shows the source instead, with the message.
struct AgentDiagramError: Error, Equatable {
    var message: String
    /// 1-based line of the source where parsing stopped, when known.
    var line: Int?
}

/// A laid-out diagram: its size, and a drawing closure for a Core Graphics context whose
/// origin is the diagram's top-left corner (flipped, y grows downward).
struct AgentDiagramLayout {
    var size: CGSize
    var draw: (CGContext) -> Void
}

/// One Mermaid diagram family. Parsing is pure and off-main-thread safe; layout and drawing use AppKit.
protocol AgentDiagramDocument {
    /// The Mermaid header keywords this family owns, lowercased, e.g. `["flowchart", "graph"]`.
    static var keywords: Set<String> { get }
    /// Parses the full Mermaid source, header line included. Throws `AgentDiagramError`.
    init(source: String) throws
    /// Lays the diagram out for at most `maxWidth` points; larger diagrams may exceed it and scroll.
    func layout(maxWidth: CGFloat, style: AgentDiagramStyle) -> AgentDiagramLayout
}

enum AgentDiagramSource {
    /// The first non-empty, non-comment, non-directive line's leading keyword, lowercased.
    /// Mermaid `%%` comments and `%%{init: …}%%` directives are skipped.
    static func keyword(of source: String) -> String? {
        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("%%") { continue }
            let word = line.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
            return word.isEmpty ? nil : word.lowercased()
        }
        return nil
    }
}
