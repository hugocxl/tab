import AppKit

/// Pinned Lucide paths used by the conversation, without SF Symbol substitution.
@MainActor
enum AgentConversationIcon: String, CaseIterable {
    case copy, check, play
    case wrap = "wrap-text"
    case warning = "triangle-alert"
    case chevronDown = "chevron-down"
    case chevronRight = "chevron-right"
    case terminal, eye, search, globe, bot, wrench
    case edit = "square-pen"
    case externalLink = "external-link"
    case circle, info, download
    case circleCheck = "circle-check"
    case loader = "loader-circle"
    case listTodo = "list-todo"
    case fileText = "file-text"
    case folderDown = "folder-down"
    case foldVertical = "fold-vertical"
    case maximize = "maximize-2"

    private static var images: [String: NSImage] = [:]

    func image(size: CGFloat = 12) -> NSImage? {
        let key = "\(rawValue)-\(size)"
        if let image = Self.images[key] { return image }
        guard let image = BundledImage.load("agent-\(rawValue)", extension: "svg") else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        Self.images[key] = image
        return image
    }

    func image(size: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(rawValue)-\(size)-\(color)"
        if let image = Self.images[key] { return image }
        guard let source = image(size: size) else { return nil }
        let tinted = NSImage(size: source.size, flipped: false) { rect in
            source.draw(in: rect)
            color.setFill()
            // sourceIn preserves the tint's alpha as well as the SVG mask's alpha.
            rect.fill(using: .sourceIn)
            return true
        }
        Self.images[key] = tinted
        return tinted
    }
}
