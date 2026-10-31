import AppKit

@MainActor
final class AgentResponseDivider: AgentResponseSection {
    override var kind: Int { 5 }
    private var color: NSColor = .separatorColor

    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        color = AgentMarkdownPalette(theme: theme).divider
        needsDisplay = true
    }

    override func height(for width: CGFloat) -> CGFloat { 1 }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        color.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
