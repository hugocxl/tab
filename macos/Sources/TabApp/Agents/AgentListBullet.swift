import AppKit

/// Browser list markers are geometric shapes, not the font's bullet characters.
/// Keep the original character in storage for selection and clipboard operations.
enum AgentListBullet {
    static func recognizes(_ marker: String) -> Bool { ["•", "◦", "▪"].contains(marker) }

    static func rect(textX: CGFloat, baseline: CGFloat, font: NSFont) -> NSRect {
        let ascent = font.ascender.rounded()
        let size = floor((floor(ascent * 2 / 3) + 1) / 2)
        return NSRect(x: floor(textX - size - 11), y: floor(baseline - ascent / 2), width: size, height: size)
    }

    static func draw(_ marker: String, rect: NSRect, color: NSColor) {
        color.setFill()
        color.setStroke()
        if marker == "▪" { rect.fill() }
        else {
            let path = NSBezierPath(ovalIn: rect)
            if marker == "◦" { path.lineWidth = 1; path.stroke() }
            else { path.fill() }
        }
    }
}

extension NSAttributedString.Key {
    static let agentListBullet = NSAttributedString.Key("TabAgentListBullet")
}
