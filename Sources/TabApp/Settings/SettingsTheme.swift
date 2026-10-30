import SwiftUI

/// The app theme's colors as Settings draws them, so the window matches the
/// workspace instead of the system's grays.
struct SettingsTheme {
    var background: SwiftUI.Color
    var sidebar: SwiftUI.Color
    var card: SwiftUI.Color
    var text: SwiftUI.Color
    var secondaryText: SwiftUI.Color
    var accent: SwiftUI.Color
    var danger: SwiftUI.Color

    @MainActor
    init(_ theme: AppTheme) {
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
    var settingsTheme: SettingsTheme? {
        get { self[SettingsThemeKey.self] }
        set { self[SettingsThemeKey.self] = newValue }
    }
}
