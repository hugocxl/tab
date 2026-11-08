import AppKit
import Combine
import TabCore

extension ChromeColor {
    /// The color in sRGB.
    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension AppTheme {
    /// Hues from Pierre's icon palette, for its colorful icons.
    public enum IconHue {
        case blue, green, indigo, vermilion
    }

    /// `hue` as `#rrggbb`: Pierre's deeper shade on light themes, its
    /// lighter one on dark themes.
    public func iconHex(_ hue: IconHue) -> String {
        switch hue {
        case .blue: return isLight ? "#1a85d4" : "#69b1ff"
        case .green: return isLight ? "#199f43" : "#5ecc71"
        case .indigo: return isLight ? "#693acf" : "#9d6afb"
        case .vermilion: return isLight ? "#d5512f" : "#ff8c5b"
        }
    }
}

extension TabCore.RGBColor {
    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// The color nearest `color` in sRGB, dropping transparency.
    public init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        self.init(byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent) as UInt32)
    }
}

extension NSColor {
    /// `0xRRGGBB` in sRGB.
    public convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// The app's current colors: the chrome palette of the theme chosen for the
/// system's light or dark appearance. Views read its tokens and redraw when
/// `palette` publishes a change; nothing polls.
@MainActor
public final class AppTheme: ObservableObject {
    /// The theme every view uses unless given another.
    public static let shared = AppTheme()

    @Published public private(set) var palette: ChromePalette
    /// The terminal colors of the chosen theme.
    @Published public private(set) var scheme: ColorScheme
    /// Whether the system appearance is dark, choosing the dark theme.
    @Published public private(set) var systemIsDark: Bool
    @Published public private(set) var accessibility: AccessibilityOptions

    public private(set) var catalog: ThemeCatalog
    public private(set) var darkTheme: String
    public private(set) var lightTheme: String

    @Published public private(set) var interface = Appearance()

    public var glassEnabled: Bool { interface.interfaceStyle == .glass && !accessibility.reduceTransparency }
    public var glassPanes: Bool { glassEnabled && interface.glassPanes }
    public var paneBackground: NSColor { glassPanes ? .clear : card }
    public var interfaceIsDark: Bool { interface.colorScheme == .auto ? systemIsDark : interface.colorScheme == .dark }

    public func setInterface(_ appearance: Appearance) {
        guard interface.colorScheme != appearance.colorScheme || interface.interfaceStyle != appearance.interfaceStyle ||
              interface.glassPanes != appearance.glassPanes || interface.animationStyle != appearance.animationStyle else { return }
        interface = appearance
        apply()
    }

    private var appearanceObservation: NSKeyValueObservation?
    private var accessibilityObserver: NSObjectProtocol?

    /// A theme that follows the system appearance once `followSystem()` runs.
    /// `systemIsDark` fixes the appearance, for tests and previews.
    public init(
        catalog: ThemeCatalog = ThemeCatalog(entries: []),
        darkTheme: String = ThemeCatalog.defaultDark,
        lightTheme: String = ThemeCatalog.defaultLight,
        systemIsDark: Bool? = nil
    ) {
        let dark = systemIsDark ?? Self.currentSystemIsDark()
        let (scheme, palette) = Self.resolve(catalog: catalog, darkTheme: darkTheme, lightTheme: lightTheme, dark: dark)
        self.catalog = catalog
        self.darkTheme = darkTheme
        self.lightTheme = lightTheme
        self.systemIsDark = dark
        self.scheme = scheme
        self.palette = palette
        self.accessibility = AccessibilityOptions.current()
    }

    /// The colors for `dark` or light appearance; Tab's own theme stands in
    /// for a name the catalog does not have.
    public nonisolated static func resolve(
        catalog: ThemeCatalog,
        darkTheme: String,
        lightTheme: String,
        dark: Bool
    ) -> (ColorScheme, ChromePalette) {
        catalog.resolve(darkTheme: darkTheme, lightTheme: lightTheme, dark: dark)
    }

    /// Starts following the system appearance and accessibility options.
    public func followSystem() {
        if appearanceObservation == nil, let app = NSApp {
            appearanceObservation = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.setSystemDark(Self.currentSystemIsDark()) }
            }
        }
        if accessibilityObserver == nil {
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshAccessibility() }
            }
        }
        setSystemDark(Self.currentSystemIsDark())
        refreshAccessibility()
    }

    /// Reads the bundled and custom themes off the main thread, then applies
    /// them.
    public func loadCatalog(customDirectory: URL?) async {
        let catalog = await Task.detached(priority: .userInitiated) {
            ThemeCatalog.load(customDirectory: customDirectory)
        }.value
        setCatalog(catalog)
    }

    public func setCatalog(_ catalog: ThemeCatalog) {
        self.catalog = catalog
        apply()
    }

    /// Applies the theme names saved in Appearance.
    public func setThemes(dark: String, light: String) {
        guard dark != darkTheme || light != lightTheme else { return }
        darkTheme = dark
        lightTheme = light
        apply()
    }

    public func setSystemDark(_ dark: Bool) {
        guard dark != systemIsDark else { return }
        systemIsDark = dark
        apply()
    }

    private func refreshAccessibility() {
        let options = AccessibilityOptions.current()
        if options != accessibility { accessibility = options }
    }

    private func apply() {
        let (scheme, palette) = Self.resolve(catalog: catalog, darkTheme: darkTheme, lightTheme: lightTheme, dark: interfaceIsDark)
        if scheme != self.scheme { self.scheme = scheme }
        if palette != self.palette { self.palette = palette }
    }

    /// The name of the theme in use.
    public var currentThemeName: String { interfaceIsDark ? darkTheme : lightTheme }

    private static func currentSystemIsDark() -> Bool {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: Tokens

    public var bg: NSColor { palette.bg.nsColor.withAlphaComponent(glassEnabled ? 0.12 : 1) }
    public var fg: NSColor { palette.fg.nsColor }
    public var fgMuted: NSColor { palette.fgMuted.nsColor }
    public var fgDim: NSColor { palette.fgDim.nsColor }
    public var surface: NSColor { palette.surface.nsColor.withAlphaComponent(glassEnabled ? 0.28 : palette.surface.alpha) }
    public var border: NSColor { palette.border.nsColor }
    public var hover: NSColor { palette.hover.nsColor }
    public var accent: NSColor { palette.accent.nsColor }
    public var accentSoft: NSColor { palette.accentSoft.nsColor }
    public var accentForeground: NSColor { palette.accentForeground.nsColor }
    public var warning: NSColor { palette.warning.nsColor }
    public var danger: NSColor { palette.danger.nsColor }
    /// Information and progress: the system's blue, whatever the theme's accent.
    public var info: NSColor { .systemBlue }
    /// Something finished well: the theme's green.
    public var success: NSColor { palette.diffAdd.nsColor }
    public var diffAdd: NSColor { palette.diffAdd.nsColor }
    public var diffRemove: NSColor { palette.diffRemove.nsColor }
    public var diffHunk: NSColor { palette.diffHunk.nsColor }

    /// The foreground at `alpha`.
    public func fg(alpha: CGFloat) -> NSColor { palette.fg.withAlpha(alpha).nsColor }

    /// Pane cards: lighter than the window in dark themes, and the theme's own
    /// background in light ones, where the window darkens instead.
    public var card: NSColor { Self.card(palette).nsColor.withAlphaComponent(glassPanes ? 0.12 : 1) }
    /// The window background behind the pane cards, shared by the sidebar.
    public var chrome: NSColor { Self.chrome(palette).nsColor.withAlphaComponent(glassEnabled ? 0.18 : 1) }
    /// Card borders: 95% border over the background (about `#282827`).
    public var cardBorder: NSColor { Self.cardBorder(palette).nsColor }
    /// Raised surfaces such as the Settings sidebar and popovers.
    public var raised: NSColor { palette.raised.nsColor.withAlphaComponent(glassEnabled ? 0.25 : 1) }
    /// Surfaces floating over the window, such as the command palette: a
    /// faint tint of the background in light themes, raised in dark ones.
    public var floating: NSColor { (Self.isLight(palette) ? Self.tint(palette) : palette.raised).nsColor.withAlphaComponent(glassEnabled ? 0.3 : 1) }
    /// A stable readability tint for the palette, independent of Interface style.
    public var commandPaletteBackground: NSColor {
        floating.withAlphaComponent(accessibility.reduceTransparency ? 1 : (isLight ? 0.78 : 0.72))
    }
    /// Composer elevation brightens light themes while retaining the dark surface.
    var agentComposer: NSColor {
        let color = isLight ? ChromeColor(red: 1, green: 1, blue: 1).blended(over: palette.bg, amount: 0.65).nsColor : floating
        return glassEnabled ? color.withAlphaComponent(0.3) : color
    }
    /// What lies under every glass surface in the Glass interface style:
    /// HUD vibrancy sampling the desktop, under a plate that desaturates it
    /// toward the raised color in dark themes or whitens it with the canvas
    /// in light ones. Panes sample this, so the desktop's colors still
    /// project through their glass.
    public func windowBackdrop(isKey: Bool) -> GlassRecipe {
        let canvas = palette.bg.nsColor
        if isLight {
            return GlassRecipe(tint: .clear, fill: GlassPlane(canvas.withAlphaComponent(isKey ? 0.8 : 0.85)))
        }
        return GlassRecipe(tint: .clear, fill: GlassPlane(palette.raised.nsColor.withAlphaComponent(isKey ? 0.75 : 0.8)))
    }

    /// The window chrome between the glass surfaces: a canvas tint over the
    /// backdrop, darkened further in dark themes. It is cut out under every
    /// pane, so their glass sees the backdrop alone.
    public func windowVeil(isKey: Bool) -> GlassRecipe {
        let canvas = palette.bg.nsColor
        if isLight {
            return GlassRecipe(tint: canvas.withAlphaComponent(isKey ? 0.75 : 0.8))
        }
        return GlassRecipe(
            tint: canvas.withAlphaComponent(0.85),
            fill: isKey ? GlassPlane(NSColor.black.withAlphaComponent(0.3), blend: "overlayBlendMode") : GlassPlane(NSColor.black.withAlphaComponent(0.2))
        )
    }

    /// A pane's glass when glass panes are on: glass with a faint canvas
    /// tint and no border, so the desktop's colors project through it and
    /// its edges catch the light. The active pane in a light theme sits on
    /// a raised plate; other panes sit under a darker or lighter veil.
    public func paneGlass(isKey: Bool, isActive: Bool) -> GlassRecipe {
        let canvas = palette.bg.nsColor
        if isLight {
            let raised = palette.raised.nsColor
            let fill: GlassPlane? = switch (isKey, isActive) {
            case (true, true): GlassPlane(raised.withAlphaComponent(0.5))
            case (true, false): GlassPlane(NSColor(srgbRed: 0.122, green: 0.137, blue: 0.157, alpha: 0.05), blend: "plusD")
            case (false, _): GlassPlane(raised.withAlphaComponent(0.4))
            }
            return GlassRecipe(tint: canvas.withAlphaComponent(0.1), backdrop: isKey && isActive ? GlassPlane(raised.withAlphaComponent(0.85)) : nil, fill: fill)
        }
        return GlassRecipe(
            tint: canvas.withAlphaComponent(0.35),
            backdrop: GlassPlane(NSColor.black.withAlphaComponent(isKey ? 0.2 : 0.6)),
            fill: isKey && !isActive ? GlassPlane(NSColor.black.withAlphaComponent(0.2)) : nil
        )
    }

    /// Whether the palette is a light one.
    public var isLight: Bool { Self.isLight(palette) }
    /// Pills and chips at rest.
    public var pill: NSColor { surface }
    /// Pills and chips under the pointer.
    public var pillHover: NSColor { hover }
    /// The selected sidebar card's fill: the classic surface, opaque in the
    /// glass interface too.
    public var sidebarSelection: NSColor { palette.surface.nsColor }
    /// The fill of rows in an inset settings card.
    public var rowFill: NSColor { fg(alpha: 0.065) }
    /// The edge of an inset settings card.
    public var rowBorder: NSColor { fg(alpha: 0.06) }
    /// Lines between rows of an inset card.
    public var separator: NSColor { fg(alpha: 0.10) }
    /// A selected list or sidebar row.
    public var selection: NSColor { fg(alpha: 0.10) }
    /// The off track of a switch and a selected segment.
    public var control: NSColor { fg(alpha: 0.18) }
    /// Button fill.
    public var button: NSColor { fg(alpha: 0.16) }

    public nonisolated static func card(_ palette: ChromePalette) -> ChromeColor {
        isLight(palette) ? palette.bg : tint(palette)
    }

    public nonisolated static func chrome(_ palette: ChromePalette) -> ChromeColor {
        isLight(palette) ? tint(palette) : palette.bg
    }

    /// 2.5% foreground over the background (about `#161616` in the default theme).
    private nonisolated static func tint(_ palette: ChromePalette) -> ChromeColor {
        palette.fg.blended(over: palette.bg, amount: 0.025)
    }

    private nonisolated static func isLight(_ palette: ChromePalette) -> Bool {
        palette.bg.lightness > palette.fg.lightness
    }

    public nonisolated static func cardBorder(_ palette: ChromePalette) -> ChromeColor {
        palette.border.blended(over: palette.bg, amount: 0.95)
    }

    /// The window appearance matching the palette, so system controls and
    /// menus draw light or dark like the theme.
    public var nsAppearance: NSAppearance? { Self.nsAppearance(palette) }

    /// The appearance for `palette`. `$palette` publishes before the new
    /// value is stored, so its subscribers pass the value they receive.
    public nonisolated static func nsAppearance(_ palette: ChromePalette) -> NSAppearance? {
        NSAppearance(named: palette.isLight ? .aqua : .darkAqua)
    }
}

/// The accessibility display options the chrome follows.
public struct AccessibilityOptions: Equatable, Sendable {
    public var reduceTransparency: Bool
    public var increaseContrast: Bool
    public var reduceMotion: Bool

    public init(reduceTransparency: Bool = false, increaseContrast: Bool = false, reduceMotion: Bool = false) {
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
    }

    @MainActor
    public static func current() -> AccessibilityOptions {
        let workspace = NSWorkspace.shared
        return AccessibilityOptions(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion
        )
    }
}

/// How one glass surface is layered: the glass's tint, a plate under the
/// glass and a blend over it.
public struct GlassRecipe: Equatable {
    public var tint: NSColor
    public var backdrop: GlassPlane?
    public var fill: GlassPlane?

    public init(tint: NSColor, backdrop: GlassPlane? = nil, fill: GlassPlane? = nil) {
        self.tint = tint
        self.backdrop = backdrop
        self.fill = fill
    }
}

extension GlassView {
    /// Applies `recipe`'s tint and planes.
    func apply(_ recipe: GlassRecipe) {
        tint = recipe.tint
        backdrop = recipe.backdrop
        fill = recipe.fill
    }
}
