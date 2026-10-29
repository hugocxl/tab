import AppKit

/// The desktop style's geometry, from Codesh's `docs/codesh/style.md`: one
/// 8pt gutter, 10pt card radius, 1pt border, 36pt headers and 8pt control
/// gaps. Views use these instead of literal numbers so the chrome stays one
/// system.
public enum Metrics {
    /// Window inset, gaps between cards, sidebar and panel padding.
    public static let gutter: CGFloat = 8
    public static let cardRadius: CGFloat = 10
    public static let border: CGFloat = 1
    public static let headerHeight: CGFloat = 36
    public static let controlGap: CGFloat = 8
    /// Header and toolbar glyphs.
    public static let glyph: CGFloat = 16

    public static let radiusSmall: CGFloat = 4
    public static let radiusMedium: CGFloat = 6
    public static let radiusLarge: CGFloat = 8

    /// Standard control height: buttons, fields, pop-ups, segmented pills.
    public static let controlHeight: CGFloat = 24
    /// Width of text fields and pop-ups in settings rows.
    public static let controlWidth: CGFloat = 210
    public static let sliderWidth: CGFloat = 220

    public static let sidebarExpandedWidth: CGFloat = 270
    public static let sidebarMinimumWidth: CGFloat = 180
    public static let sidebarMaximumWidth: CGFloat = 480

    /// A keycap's side, as in the command palette.
    public static let keycap: CGFloat = 20
}

/// The app's fonts: SF for the chrome, SF Mono where text lines up.
public enum AppFont {
    /// Card and pane headers: 13pt semibold.
    public static var header: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    public static var body: NSFont { .systemFont(ofSize: 13) }
    public static var bodyMedium: NSFont { .systemFont(ofSize: 13, weight: .medium) }
    public static var small: NSFont { .systemFont(ofSize: 12) }
    public static var footnote: NSFont { .systemFont(ofSize: 11) }
    public static var footnoteMedium: NSFont { .systemFont(ofSize: 11, weight: .medium) }
    public static var caption: NSFont { .systemFont(ofSize: 10) }
    public static var micro: NSFont { .systemFont(ofSize: 8, weight: .bold) }
    public static var title: NSFont { .systemFont(ofSize: 17, weight: .semibold) }

    public static func system(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    public static func mono(_ size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
}
