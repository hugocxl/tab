import AppKit

enum AgentTaskCheckbox {
    static let size: CGFloat = 13
    static let top: CGFloat = 4.765625

    static func textInset(font: NSFont) -> CGFloat {
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        return size + AgentMarkdownLayout.units(font.pointSize * 0.35) + ceil(space * 64) / 64
    }

    static func state(marker: String, dark: Bool) -> Int? {
        guard marker == "☐" || marker == "☑" else { return nil }
        return (marker == "☑" ? 1 : 0) + (dark ? 2 : 0)
    }

    static func draw(state: Int, in rect: NSRect) {
        let checked = state & 1 != 0
        let dark = state & 2 != 0
        func gray(_ value: CGFloat) -> NSColor { NSColor(srgbRed: value / 255, green: value / 255, blue: value / 255, alpha: 1) }
        let border = gray(dark ? (checked ? 136 : 117) : 217)
        let fill = checked ? border : gray(dark ? 76 : 249)
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.5, yRadius: 1.5)
        fill.setFill(); box.fill()
        border.setStroke(); box.lineWidth = 1; box.stroke()
        if checked {
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + 3, y: rect.minY + 6.5))
            check.line(to: NSPoint(x: rect.minX + 5.3, y: rect.minY + 8.8))
            check.line(to: NSPoint(x: rect.minX + 10, y: rect.minY + 3.6))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            gray(dark ? 76 : 240).setStroke(); check.stroke()
        }
    }
}

extension NSAttributedString.Key {
    static let agentTaskCheckbox = NSAttributedString.Key("TabAgentTaskCheckbox")
}
