import AppKit

/// The app's glass surface: native Liquid Glass on macOS 26 and later, a
/// frosted `NSVisualEffectView` before. Workspace backgrounds use vibrancy on
/// every macOS version. Add it as the bottom subview of any
/// view that should read as glass, keep its frame on the host's bounds and
/// set its `appearance` from the theme; the host keeps its own fill, border
/// and content above it. It never takes clicks, so the host's hit testing,
/// hover and context menu stay intact.
public final class GlassView: NSView {
    /// How the surface looks, chosen once per use.
    public struct Style: Sendable {
        /// The corner radius of the material, matching the host's layer.
        public var cornerRadius: CGFloat
        /// The surface's opacity; below 1 lets the host's fill show through.
        public var opacity: CGFloat
        /// Regular glass diffuses busy backgrounds more strongly than clear glass.
        public var regular: Bool
        /// Whether to use Liquid Glass when available, rather than flat vibrancy.
        public var usesLiquidGlass: Bool
        /// The `NSVisualEffectView` material on releases without Liquid Glass,
        /// and on every release for styles that never use it.
        public var fallbackMaterial: NSVisualEffectView.Material

        public init(cornerRadius: CGFloat, opacity: CGFloat = 1, fallbackMaterial: NSVisualEffectView.Material = .sidebar, regular: Bool = false, usesLiquidGlass: Bool = true) {
            self.cornerRadius = cornerRadius
            self.opacity = opacity
            self.regular = regular
            self.usesLiquidGlass = usesLiquidGlass
            self.fallbackMaterial = fallbackMaterial
        }

        /// Flat, desktop-sampling vibrancy with a translucent palette overlay.
        public static let workspace = Style(cornerRadius: 0, fallbackMaterial: .underWindowBackground, usesLiquidGlass: false)
        /// The main window's background: HUD vibrancy sampling the desktop,
        /// as other apps' windows do. Never Liquid Glass: glass over glass
        /// goes flat, and the panes' glass must find the desktop beneath it.
        public static let window = Style(cornerRadius: 0, fallbackMaterial: .hudWindow, usesLiquidGlass: false)
        /// A pane's continuous glass surface, underneath its header and content.
        public static let pane = Style(cornerRadius: Metrics.cardRadius, regular: true)
        /// The selected sidebar card's glass surface.
        public static let card = Style(cornerRadius: 8, opacity: 0.4)

        /// Always-on, diffused material for the command palette.
        public static let commandPalette = Style(cornerRadius: PaletteLayout.radius, fallbackMaterial: .popover, regular: true)
        /// The command palette's nested actions menu.
        public static let paletteActions = Style(cornerRadius: 14, fallbackMaterial: .popover, regular: true)

        /// A floating notice: a capsule of diffused glass, so its message reads over busy panes.
        public static let chip = Style(cornerRadius: NoticeView.height / 2, fallbackMaterial: .popover, regular: true)
        /// A mode chip beside the command palette's search field.
        public static let paletteChip = Style(cornerRadius: ModeChip.height / 2, fallbackMaterial: .popover, regular: true)
        /// The chrome's tooltip capsule.
        public static let tooltip = Style(cornerRadius: 10, fallbackMaterial: .toolTip)
        /// Popups anchored to a control, such as the agent composer's suggestions.
        public static let popover = Style(cornerRadius: 10, fallbackMaterial: .menu)
    }

    private let material: NSView
    private var fallbackTint: NSView?
    private let backdropPlane = NSView()
    private let fillPlane = NSView()

    /// A color layer under the glass, such as a darkening plate. Behind-window
    /// vibrancy covers it, so window backgrounds use `fill` and `tint` only.
    public var backdrop: GlassPlane? {
        didSet { if backdrop != oldValue { backdropPlane.apply(backdrop) } }
    }

    /// A color layer over the glass, blended with what the glass shows.
    public var fill: GlassPlane? {
        didSet { if fill != oldValue { fillPlane.apply(fill) } }
    }

    /// A color the glass takes on, such as a status color; `nil` keeps it
    /// clear. Vibrancy surfaces use a translucent overlay to carry the tint.
    public var tint: NSColor? {
        didSet {
            guard tint != oldValue else { return }
            if #available(macOS 26, *), let glass = material as? NSGlassEffectView {
                glass.tintColor = tint
            } else {
                fallbackTint?.layer?.backgroundColor = tint?.cgColor
            }
        }
    }

    public init(style: Style, behindWindow: Bool = false) {
        if #available(macOS 26, *), style.usesLiquidGlass {
            let glass = NSGlassEffectView()
            glass.style = style.regular ? .regular : .clear
            glass.cornerRadius = style.cornerRadius
            material = glass
        } else {
            let frost = NSVisualEffectView()
            frost.material = style.fallbackMaterial
            frost.blendingMode = behindWindow ? .behindWindow : .withinWindow
            frost.state = behindWindow ? .active : .followsWindowActiveState
            frost.wantsLayer = true
            frost.layer?.cornerRadius = style.cornerRadius
            frost.layer?.cornerCurve = .continuous
            frost.layer?.masksToBounds = true
            material = frost
        }
        super.init(frame: .zero)
        alphaValue = style.opacity
        for plane in [backdropPlane, fillPlane] {
            plane.wantsLayer = true
            plane.layer?.cornerRadius = style.cornerRadius
            plane.layer?.cornerCurve = .continuous
            plane.isHidden = true
        }
        addSubview(backdropPlane)
        addSubview(material)
        addSubview(fillPlane)
        if material is NSVisualEffectView {
            let overlay = NSView()
            overlay.wantsLayer = true
            overlay.layer?.cornerRadius = style.cornerRadius
            overlay.layer?.cornerCurve = .continuous
            fallbackTint = overlay
            addSubview(overlay)
        }
        setAccessibilityElement(false)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func layout() {
        super.layout()
        fallbackTint?.frame = bounds
        backdropPlane.frame = bounds
        material.frame = bounds
        fillPlane.frame = bounds
    }
}

/// A flat color layer in a `GlassView`, with an optional Core Animation
/// compositing filter such as `"overlayBlendMode"` or `"plusD"`.
public struct GlassPlane: Equatable {
    public var color: NSColor
    public var blend: String?

    public init(_ color: NSColor, blend: String? = nil) {
        self.color = color
        self.blend = blend
    }
}

private extension NSView {
    func apply(_ plane: GlassPlane?) {
        isHidden = plane == nil
        layer?.backgroundColor = plane?.color.cgColor
        layer?.compositingFilter = plane?.blend
    }
}
