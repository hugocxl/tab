import AppKit

/// The app's glass surface: native Liquid Glass on macOS 26 and later, a
/// frosted `NSVisualEffectView` before. Add it as the bottom subview of any
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
        /// The `NSVisualEffectView` material on releases without Liquid Glass.
        public var fallbackMaterial: NSVisualEffectView.Material

        public init(cornerRadius: CGFloat, opacity: CGFloat = 1, fallbackMaterial: NSVisualEffectView.Material = .sidebar) {
            self.cornerRadius = cornerRadius
            self.opacity = opacity
            self.fallbackMaterial = fallbackMaterial
        }

        /// The selected sidebar card: a faint clear glass over the card fill.
        public static let card = Style(cornerRadius: 8, opacity: 0.4)
        /// The chrome's tooltip capsule.
        public static let tooltip = Style(cornerRadius: 10, fallbackMaterial: .toolTip)
    }

    private let material: NSView

    public init(style: Style) {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = style.cornerRadius
            material = glass
        } else {
            let frost = NSVisualEffectView()
            frost.material = style.fallbackMaterial
            frost.blendingMode = .withinWindow
            frost.state = .followsWindowActiveState
            frost.wantsLayer = true
            frost.layer?.cornerRadius = style.cornerRadius
            frost.layer?.cornerCurve = .continuous
            frost.layer?.masksToBounds = true
            material = frost
        }
        super.init(frame: .zero)
        alphaValue = style.opacity
        addSubview(material)
        setAccessibilityElement(false)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func layout() {
        super.layout()
        material.frame = bounds
    }
}
