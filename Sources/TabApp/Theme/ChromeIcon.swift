import AppKit

/// The SF Symbols of the sidebar chrome and pane headers.
public enum ChromeIcon: String, CaseIterable, Sendable {
    case panelLeft
    case panelRight
    case command
    case plusCircle
    case addProject
    case globeBadgePlus
    case filter
    case clearField
    case terminal
    case code
    case file
    case gitBranch
    case globe
    case phone
    case chevronLeft
    case home
    case rotate
    case keyboard
    case appearance
    case camera
    case ellipsis
    case network
    case columns
    case rows
    case maximize
    case restore
    case close

    /// The SF Symbol drawn for this icon.
    var symbolName: String {
        switch self {
        case .panelLeft: return "sidebar.left"
        case .panelRight: return "sidebar.right"
        case .command: return "command"
        case .plusCircle: return "plus.circle"
        case .addProject: return "rectangle.stack.badge.plus"
        case .globeBadgePlus: return "safari"
        case .filter: return "line.3.horizontal.decrease.circle"
        case .clearField: return "xmark.circle"
        case .terminal: return "terminal"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .file: return "doc"
        case .gitBranch: return "arrow.triangle.branch"
        case .globe: return "globe"
        case .phone: return "iphone"
        case .chevronLeft: return "chevron.left"
        case .home: return "house"
        case .rotate: return "rotate.left"
        case .keyboard: return "keyboard"
        case .appearance: return "circle.lefthalf.filled"
        case .camera: return "camera"
        case .ellipsis: return "ellipsis"
        case .network: return "network"
        case .columns: return "rectangle.split.2x1"
        case .rows: return "rectangle.split.1x2"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .restore: return "arrow.down.right.and.arrow.up.left"
        case .close: return "xmark"
        }
    }

    /// A cached template image on a square canvas `size` points on a side.
    @MainActor
    public func image(size: CGFloat = Metrics.glyph) -> NSImage? {
        let key = "\(rawValue)-\(size)"
        if let cached = Self.images[key] { return cached }
        guard let source = SFSymbol.image(symbolName, pointSize: size), source.size.width > 0, source.size.height > 0 else { return nil }
        let fit = min(size / source.size.width, size / source.size.height)
        let fitted = NSSize(width: source.size.width * fit, height: source.size.height * fit)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: NSRect(x: (rect.width - fitted.width) / 2, y: (rect.height - fitted.height) / 2,
                                   width: fitted.width, height: fitted.height))
            return true
        }
        image.isTemplate = true
        Self.images[key] = image
        return image
    }

    @MainActor private static var images: [String: NSImage] = [:]
}
