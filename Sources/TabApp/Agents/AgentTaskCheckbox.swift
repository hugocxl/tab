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

    @MainActor
    static func draw(state: Int, in rect: NSRect) {
        let checked = state & 1 != 0
        let dark = state & 2 != 0
        func gray(_ value: CGFloat) -> NSColor { NSColor(srgbRed: value / 255, green: value / 255, blue: value / 255, alpha: 1) }
        let border = gray(dark ? (checked ? 136 : 117) : 217)
        let icon: AppIcon = checked ? .checkboxFill : .checkbox
        icon.image(size: rect.height, color: border)?.draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension NSAttributedString.Key {
    static let agentTaskCheckbox = NSAttributedString.Key("TabAgentTaskCheckbox")
}
