import AppKit
import TabCore

/// The icons the chrome uses, drawn with SF Symbols, except the terminal
/// stack, which is a bundled SVG. Images are templates, so they tint with
/// `contentTintColor` or the drawing color.
public enum AppIcon: String, CaseIterable, Sendable {
    case appWindow, arrowUpDown, chevronDown, chevronLeft, chevronRight, chevronUp, check, circleX, command
    case code, circleUser, columns, ellipsis, folder, gitBranch, globe, eye, keyboard, lightbulb
    case maximize, network, palette, panelBottom, panelLeft, panelRight, pin, pinOff, plus, puzzle
    case restore, refresh, rows, search, settings, terminal, terminalStack, close, externalLink
    case filter, filterCircle, history, arrowDownCircle, arrowUpCircle, chevronsUpDown
    case circle, circleCheck, clock, file, gitMerge, gitPullRequest, octagonX, copy, pause, pencil
    case play, quote, stop, triangleAlert, phone, trash, minus, qrcode, arrowDown
    case plusCircle, filterCircleFill, addProject, layers, laptop, globeBadgePlus, clearField

    /// The SF Symbol drawn for the icon, or `nil` for the icons composed or
    /// bundled instead.
    public var symbolName: String? {
        switch self {
        case .appWindow: return "macwindow"
        case .arrowUpDown: return "arrow.up.arrow.down"
        case .chevronDown: return "chevron.down"
        case .chevronLeft: return "chevron.left"
        case .chevronRight: return "chevron.right"
        case .chevronUp: return "chevron.up"
        case .check: return "checkmark"
        case .circleX: return "xmark.circle"
        case .command: return "command"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .circleUser: return "person.crop.circle"
        case .columns: return "square.split.2x1"
        case .ellipsis: return "ellipsis"
        case .folder: return "folder"
        case .gitBranch: return "arrow.triangle.branch"
        case .globe: return "globe"
        case .eye: return "eye"
        case .keyboard: return "keyboard"
        case .lightbulb: return "lightbulb"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .network: return "network"
        case .palette: return "paintpalette"
        case .panelBottom: return "rectangle.bottomhalf.inset.filled"
        case .panelLeft: return "sidebar.left"
        case .panelRight: return "sidebar.right"
        case .pin: return "pin"
        case .pinOff: return "pin.slash"
        case .plus: return "plus"
        case .puzzle: return "puzzlepiece.extension"
        case .restore: return "arrow.down.right.and.arrow.up.left"
        case .refresh: return "arrow.clockwise"
        case .rows: return "square.split.1x2"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        case .terminal: return "terminal"
        case .terminalStack: return nil
        case .close: return "xmark"
        case .externalLink: return "arrow.up.forward.app"
        case .filter: return "line.3.horizontal.decrease"
        case .filterCircle: return "line.3.horizontal.decrease.circle"
        case .history: return "clock.arrow.circlepath"
        case .arrowDownCircle: return "arrow.down.circle"
        case .arrowUpCircle: return "arrow.up.circle"
        case .chevronsUpDown: return "chevron.up.chevron.down"
        case .circle: return "circle"
        case .circleCheck: return "checkmark.circle"
        case .clock: return "clock"
        case .file: return "doc"
        case .gitMerge: return "arrow.triangle.merge"
        case .gitPullRequest: return "arrow.triangle.pull"
        case .octagonX: return "xmark.octagon"
        case .copy: return "rectangle.on.rectangle"
        case .pause: return "pause"
        case .pencil: return "pencil"
        case .play: return "play"
        case .quote: return "text.quote"
        case .stop: return "stop"
        case .triangleAlert: return "exclamationmark.triangle"
        case .phone: return "iphone"
        case .trash: return "trash"
        case .minus: return "minus"
        case .qrcode: return "qrcode"
        case .arrowDown: return "arrow.down"
        case .plusCircle: return "plus.circle"
        case .filterCircleFill: return "line.3.horizontal.decrease.circle.fill"
        case .addProject: return "rectangle.stack.badge.plus"
        case .layers: return "square.3.layers.3d"
        case .laptop: return "laptopcomputer"
        case .globeBadgePlus: return nil
        case .clearField: return "xmark.circle.fill"
        }
    }

    /// A template image `size` points tall.
    @MainActor
    public func image(size: CGFloat = Metrics.glyph, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(rawValue)-\(size)-\(weight.rawValue)"
        if let cached = IconCache.images[key] { return cached }
        var image: NSImage?
        if self == .globeBadgePlus {
            image = Self.badged(AppIcon.globe.symbolImage(size: size, weight: weight))
        }
        if self == .terminalStack, let bundled = BundledImage.load("terminal-stack", extension: "svg") {
            bundled.size = NSSize(width: size, height: size)
            image = bundled
        }
        if image == nil {
            image = symbolImage(size: size, weight: weight)
        }
        image?.isTemplate = true
        IconCache.images[key] = image
        return image
    }

    private func symbolImage(size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        guard let symbolName, let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return nil }
        return symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: weight, scale: .medium))
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

@MainActor
private enum IconCache {
    static var images: [String: NSImage] = [:]
    static var ink: [ObjectIdentifier: NSRect] = [:]
}

extension NSImage {
    /// The part of the image that is drawn, in its own points: glyphs leave
    /// uneven margins, which matters when spacing them by what is visible.
    @MainActor
    var inkBounds: NSRect {
        if let cached = IconCache.ink[ObjectIdentifier(self)] { return cached }
        let scale = 4
        let width = Int(ceil(size.width)) * scale, height = Int(ceil(size.height)) * scale
        var bounds = NSRect(origin: .zero, size: size)
        if width > 0, height > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        ), let data = rep.bitmapData {
            rep.size = NSSize(width: ceil(size.width), height: ceil(size.height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            var minX = width, maxX = -1, minY = height, maxY = -1
            for y in 0..<height {
                for x in 0..<width where data[(y * width + x) * 4 + 3] > 76 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            if maxX >= 0 {
                let unit = 1 / CGFloat(scale)
                // Bitmap rows run top down; the image's points run bottom up.
                bounds = NSRect(x: CGFloat(minX) * unit, y: size.height - CGFloat(maxY + 1) * unit,
                                width: CGFloat(maxX + 1 - minX) * unit, height: CGFloat(maxY + 1 - minY) * unit)
            }
        }
        IconCache.ink[ObjectIdentifier(self)] = bounds
        return bounds
    }
}

/// Images shipped in `Resources/Icons`.
public enum BundledImage {
    public static func url(_ name: String, extension fileExtension: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Icons")
    }

    public static func load(_ name: String, extension fileExtension: String) -> NSImage? {
        url(name, extension: fileExtension).flatMap(NSImage.init(contentsOf:))
    }
}

/// Agent logos, colored, with dark-on-light variants where the logo needs
/// one. Every logo comes back on the same square canvas with the same optical
/// weight: tile logos fill it with rounded corners and a hairline edge that
/// keeps a tile matching the background in shape, bare glyphs sit inset.
public enum AgentLogo {
    private enum Shape { case tile, glyph }

    /// How much of the canvas a bare glyph covers, so it reads as large as a
    /// filled tile.
    private static let glyphScale: CGFloat = 0.88
    /// The corner radius of tile logos, relative to the canvas side.
    private static let tileRadius: CGFloat = 0.22
    /// The width of a tile's inner edge, relative to the canvas side: about
    /// 1pt at sidebar size.
    private static let tileEdge: CGFloat = 1.0 / 16

    /// The logo for `provider`, or `nil` for an unknown provider.
    @MainActor
    public static func image(for provider: AgentProvider, lightBackground: Bool) -> NSImage? {
        guard let (name, hasLightVariant, shape) = resource(provider) else { return nil }
        if name == "provider-xal" {
            guard let image = BundledImage.load(name, extension: "svg") else { return nil }
            let normalized = normalize(image, shape: shape, lightBackground: lightBackground)
            normalized.isTemplate = true
            return normalized
        }
        let source = lightBackground && hasLightVariant
            ? BundledImage.load("\(name)-light", extension: "png") ?? BundledImage.load(name, extension: "png")
            : BundledImage.load(name, extension: "png")
        return source.map { normalize($0, shape: shape, lightBackground: lightBackground) }
    }

    /// Redraws `image` on a square canvas: aspect-fit and inset for glyphs,
    /// clipped to a rounded square with a contrasting inner edge for tiles.
    private static func normalize(_ image: NSImage, shape: Shape, lightBackground: Bool) -> NSImage {
        let side: CGFloat = 64
        let canvas = NSRect(x: 0, y: 0, width: side, height: side)
        return NSImage(size: canvas.size, flipped: false) { _ in
            switch shape {
            case .tile:
                let radius = side * tileRadius
                let path = NSBezierPath(roundedRect: canvas, xRadius: radius, yRadius: radius)
                path.addClip()
                image.draw(in: canvas)
                // Twice the width, since the clip hides the outer half.
                path.lineWidth = side * tileEdge * 2
                (lightBackground ? NSColor(white: 0, alpha: 0.12) : NSColor(white: 1, alpha: 0.16)).setStroke()
                path.stroke()
            case .glyph:
                let box = side * glyphScale
                let scale = min(box / max(image.size.width, 1), box / max(image.size.height, 1))
                let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                      width: size.width, height: size.height))
            }
            return true
        }
    }

    private static func resource(_ provider: AgentProvider) -> (String, Bool, Shape)? {
        switch provider {
        case .claude: return ("agent-claude", false, .glyph)
        case .codex: return ("agent-codex", true, .glyph)
        case .openCode: return ("agent-opencode", false, .tile)
        case .cursor: return ("agent-cursor", false, .tile)
        case .copilot: return ("agent-copilot", false, .tile)
        case .droid: return ("agent-droid", false, .tile)
        case .pi: return ("agent-pi", false, .tile)
        case .grok: return ("agent-grok", true, .tile)
        case .kiro: return ("agent-kiro", false, .tile)
        case .xal: return ("provider-xal", false, .glyph)
        case .antigravity: return ("agent-antigravity", false, .glyph)
        case .ohMyPi: return ("agent-omp", false, .tile)
        case .unknown: return nil
        }
    }
}
