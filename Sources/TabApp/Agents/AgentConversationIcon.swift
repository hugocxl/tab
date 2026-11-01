import AppKit

/// The SF Symbols the conversation draws, each centered on a square canvas so
/// callers can lay them out in fixed boxes.
@MainActor
enum AgentConversationIcon: CaseIterable {
    case copy, check, play, wrap, warning, chevronDown, chevronRight
    case terminal, eye, search, globe, bot, wrench, edit, externalLink
    case circle, info, download, circleCheck, loader, listTodo, fileText
    case folderDown, foldVertical, maximize

    var symbolName: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .check: return "checkmark"
        case .play: return "play"
        case .wrap: return "arrow.turn.down.left"
        case .warning: return "exclamationmark.triangle"
        case .chevronDown: return "chevron.down"
        case .chevronRight: return "chevron.right"
        case .terminal: return "terminal"
        case .eye: return "eye"
        case .search: return "magnifyingglass"
        case .globe: return "globe"
        case .bot: return "cpu"
        case .wrench: return "wrench.adjustable"
        case .edit: return "square.and.pencil"
        case .externalLink: return "arrow.up.forward.app"
        case .circle: return "circle"
        case .info: return "info.circle"
        case .download: return "arrow.down.to.line"
        case .circleCheck: return "checkmark.circle"
        case .loader: return "progress.indicator"
        case .listTodo: return "checklist"
        case .fileText: return "doc.text"
        case .folderDown: return "folder.badge.plus"
        case .foldVertical: return "arrow.down.and.line.horizontal.and.arrow.up"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        }
    }

    private static var images: [String: NSImage] = [:]

    func image(size: CGFloat = 12) -> NSImage? {
        let key = "\(self)-\(size)"
        if let image = Self.images[key] { return image }
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .regular, scale: .medium))
        else { return nil }
        let glyph = symbol.size
        let scale = min(1, size / max(glyph.width, 1), size / max(glyph.height, 1))
        let fitted = NSSize(width: glyph.width * scale, height: glyph.height * scale)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            symbol.draw(in: NSRect(x: (rect.width - fitted.width) / 2, y: (rect.height - fitted.height) / 2,
                                   width: fitted.width, height: fitted.height))
            return true
        }
        image.isTemplate = true
        Self.images[key] = image
        return image
    }

    func image(size: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(self)-\(size)-\(color)"
        if let image = Self.images[key] { return image }
        guard let source = image(size: size) else { return nil }
        let tinted = NSImage(size: source.size, flipped: false) { rect in
            source.draw(in: rect)
            color.setFill()
            // sourceIn preserves the tint's alpha as well as the glyph's alpha.
            rect.fill(using: .sourceIn)
            return true
        }
        Self.images[key] = tinted
        return tinted
    }
}
