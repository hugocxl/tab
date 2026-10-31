import AppKit

/// TextKit rounds block padding to whole points. Expanding the content rectangle
/// instead preserves CSS's fractional cell padding without splitting selection.
final class AgentMarkdownTextTable: NSTextTable {
    var ruleColor = NSColor.separatorColor

    private func padding(for block: NSTextTableBlock) -> CGFloat {
        AgentMarkdownLayout.units(block.startingRow == 0 ? 8.8 : 7.2)
    }

    override func rect(for block: NSTextTableBlock, layoutAt startingPoint: NSPoint, in rect: NSRect,
                       textContainer: NSTextContainer, characterRange: NSRange) -> NSRect {
        var result = super.rect(for: block, layoutAt: startingPoint, in: rect,
                                textContainer: textContainer, characterRange: characterRange)
        let padding = padding(for: block)
        result.origin.y += padding
        result.size.height -= padding
        return result
    }

    override func boundsRect(for block: NSTextTableBlock, contentRect: NSRect, in rect: NSRect,
                             textContainer: NSTextContainer, characterRange: NSRange) -> NSRect {
        let padding = padding(for: block)
        var expanded = contentRect
        expanded.origin.y -= padding
        expanded.size.height += padding * 2 + 1
        return super.boundsRect(for: block, contentRect: expanded, in: rect,
                                textContainer: textContainer, characterRange: characterRange)
    }

    override func drawBackground(for block: NSTextTableBlock, withFrame frameRect: NSRect, in controlView: NSView,
                                 characterRange: NSRange, layoutManager: NSLayoutManager) {
        super.drawBackground(for: block, withFrame: frameRect, in: controlView,
                             characterRange: characterRange, layoutManager: layoutManager)
        ruleColor.setFill()
        NSRect(x: frameRect.minX, y: frameRect.maxY - 1, width: frameRect.width, height: 1).fill()
    }
}
