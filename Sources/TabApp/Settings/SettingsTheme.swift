import SwiftUI

/// The app theme's colors as Settings draws them, so the window matches the
/// workspace instead of the system's grays.
public struct SettingsTheme {
    public var background: SwiftUI.Color
    public var sidebar: SwiftUI.Color
    public var card: SwiftUI.Color
    public var text: SwiftUI.Color
    public var secondaryText: SwiftUI.Color
    public var accent: SwiftUI.Color
    public var danger: SwiftUI.Color

    @MainActor
    public init(_ theme: AppTheme) {
        background = SwiftUI.Color(nsColor: theme.bg)
        sidebar = SwiftUI.Color(nsColor: theme.raised)
        card = SwiftUI.Color(nsColor: theme.rowFill)
        text = SwiftUI.Color(nsColor: theme.fg)
        secondaryText = SwiftUI.Color(nsColor: theme.fgMuted)
        accent = SwiftUI.Color(nsColor: theme.accent)
        danger = SwiftUI.Color(nsColor: theme.danger)
    }
}

private struct SettingsThemeKey: EnvironmentKey {
    static let defaultValue: SettingsTheme? = nil
}

extension EnvironmentValues {
    /// The theme Settings is drawn with.
    public var settingsTheme: SettingsTheme? {
        get { self[SettingsThemeKey.self] }
        set { self[SettingsThemeKey.self] = newValue }
    }
}
