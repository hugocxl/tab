import AppKit

/// SF artwork retained by the sidebar chrome and pane headers.
public enum SystemSymbol: String, CaseIterable, Sendable {
    case panelLeft
    case panelRight
    case command
    case plusCircle
    case addProject
    case globeBadgePlus
    case filterCircleFill
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

    /// A cached template image using the chrome's original symbol sizing.
    @MainActor
    public func image(size: CGFloat = Metrics.glyph, weight: NSFont.Weight = .regular) -> NSImage? {
        if self == .globeBadgePlus {
            let key = "badge-\(size)-\(weight.rawValue)"
            if let cached = Self.images[key] { return cached }
            let image = Self.badged(Self.globe.image(size: size, weight: weight))
            image?.isTemplate = true
            Self.images[key] = image
            return image
        }
        return Self.image(named: symbolName, size: size, weight: weight)
    }

    @MainActor private static var images: [String: NSImage] = [:]

    @MainActor
    static func image(named name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(name)-\(size)-\(weight.rawValue)"
        if let cached = images[key] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: weight, scale: .medium))
        image?.isTemplate = true
        images[key] = image
        return image
    }

    private var symbolName: String {
        switch self {
        case .panelLeft: return "sidebar.left"
        case .panelRight: return "sidebar.right"
        case .command: return "command"
        case .plusCircle: return "plus.circle"
        case .addProject: return "rectangle.stack.badge.plus"
        case .filterCircleFill: return "line.3.horizontal.decrease.circle.fill"
        case .clearField: return "xmark.circle.fill"
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
        case .globeBadgePlus: return "globe"
        }
    }

    /// `base` with a filled plus badge sticking out at its bottom left and
    /// cut out of the glyph, like the system's `.badge.plus` symbols, so the
    /// glyph keeps its full size.
    private static func badged(_ base: NSImage?) -> NSImage? {
        guard let base else { return nil }
        let glyph = base.size
        let diameter = (glyph.height * 0.5).rounded()
        let overhang = (diameter * 0.4).rounded()
        let gap: CGFloat = 1.5
        let badge = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: diameter * 0.85, weight: .semibold))
        let size = NSSize(width: glyph.width + overhang, height: glyph.height + overhang)
        return NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(x: overhang, y: overhang, width: glyph.width, height: glyph.height))
            let badgeRect = NSRect(x: 0, y: 0, width: diameter, height: diameter)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -gap, dy: -gap)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            badge?.draw(in: badgeRect)
            return true
        }
    }
}
