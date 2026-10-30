import AppKit
@testable import TabCore
import XCTest
@testable import TabApp

@MainActor
final class ThemeTests: XCTestCase {
    private func catalog() -> ThemeCatalog {
        ThemeCatalog(entries: [
            ThemeEntry(name: "Night", scheme: ColorScheme.parse("background = #101010\nforeground = #eeeeee\npalette = 4=#3366ff")),
            ThemeEntry(name: "Day", scheme: ColorScheme.parse("background = #fafafa\nforeground = #222222\npalette = 4=#aa3300")),
        ])
    }

    func testPaletteFollowsSystemAppearance() {
        let theme = AppTheme(catalog: catalog(), darkTheme: "Night", lightTheme: "Day", systemIsDark: true)
        XCTAssertEqual(TabCore.RGBColor(theme.bg), TabCore.RGBColor(0x101010))
        XCTAssertFalse(theme.palette.isLight)
        XCTAssertEqual(theme.currentThemeName, "Night")

        theme.setSystemDark(false)
        XCTAssertEqual(TabCore.RGBColor(theme.bg), TabCore.RGBColor(0xFAFAFA))
        XCTAssertEqual(TabCore.RGBColor(theme.accent), TabCore.RGBColor(0xAA3300))
        XCTAssertTrue(theme.palette.isLight)
        XCTAssertEqual(theme.nsAppearance?.name, .aqua)
    }

    func testChangingThemesRepublishesPalette() {
        let theme = AppTheme(catalog: catalog(), darkTheme: "Night", lightTheme: "Day", systemIsDark: true)
        var published: [ChromePalette] = []
        let observation = theme.$palette.dropFirst().sink { published.append($0) }
        theme.setThemes(dark: "Day", light: "Day")
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(TabCore.RGBColor(theme.bg), TabCore.RGBColor(0xFAFAFA))
        observation.cancel()
    }

    func testUnknownThemeFallsBackToDefaults() {
        let theme = AppTheme(catalog: ThemeCatalog(entries: []), darkTheme: "Missing", lightTheme: "Missing", systemIsDark: true)
        XCTAssertEqual(TabCore.RGBColor(theme.bg), TabCore.RGBColor(0x111111))
        XCTAssertEqual(TabCore.RGBColor(theme.fg), TabCore.RGBColor(0xD5CEC7))
    }

    func testCardBlendsMatchStyleGuide() {
        let palette = AppTheme(catalog: ThemeCatalog(entries: []), systemIsDark: true).palette
        let card = AppTheme.card(palette)
        // 2.5% of #d5cec7 over #111111 is about #161616.
        XCTAssertEqual(card.red * 255, 22, accuracy: 1)
        XCTAssertEqual(card.alpha, 1)
        XCTAssertEqual(AppTheme.chrome(palette), palette.bg)
    }

    func testLightThemesKeepCardsOnTheBackgroundAndDarkenTheChrome() {
        let palette = AppTheme(catalog: catalog(), darkTheme: "Night", lightTheme: "Day", systemIsDark: false).palette
        XCTAssertEqual(AppTheme.card(palette), palette.bg)
        // Cards must stand above the sidebar and window, not sink below them.
        XCTAssertLessThan(AppTheme.chrome(palette).lightness, AppTheme.card(palette).lightness)
    }

    func testVibrancyOffUnderAccessibilityOptions() {
        XCTAssertTrue(AccessibilityOptions().allowsVibrancy)
        XCTAssertFalse(AccessibilityOptions(reduceTransparency: true).allowsVibrancy)
        XCTAssertFalse(AccessibilityOptions(increaseContrast: true).allowsVibrancy)
    }

    func testEveryIconHasAnImage() {
        for icon in AppIcon.allCases {
            XCTAssertNotNil(icon.image(), "\(icon) has neither a symbol nor a bundled image")
        }
    }
}

@MainActor
final class ThemeTerminalIntegrationTests: XCTestCase {
    func testVibrancyAndAppPreferencesReachExistingTerminalPanes() async throws {
        let dirs = try ModelFixtures.profile()
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(server: identity, home: home.id, revision: 1, projects: [home]))
        let model = ModelFixtures.model(dirs, server: server)
        model.start()
        defer { model.connection(.local)?.disconnect() }
        _ = await ModelFixtures.wait { model.state.serverIdentity(.local) != nil }
        model.newHomeTerminal()
        let id = try XCTUnwrap(model.activePane)
        let pane = try XCTUnwrap(model.controller(for: id) as? TerminalPane)
        let created = await ModelFixtures.wait { pane.session != nil }
        XCTAssertTrue(created)
        var terminal = TerminalSettings()
        terminal.options.backgroundOpacity = 0.5
        terminal.options.backgroundVibrancy = 60
        model.apply(terminalSettings: terminal)
        let view = try XCTUnwrap(pane.session?.view)
        let expected = model.theme.accessibility.allowsVibrancy ? 0.2 : 0.5
        XCTAssertEqual(view.palette.backgroundOpacity, expected, accuracy: 0.0001)
        var settings = model.settings
        settings.clipboard.copyOnSelect = true
        settings.keymap = try Keymap.fromOverrides([ShortcutId.copy.rawValue: "cmd-shift-c"])
        model.apply(settings: settings)
        XCTAssertEqual(view.settings.options.copyOnSelect, true)
        XCTAssertEqual(view.shortcuts[try KeyChord("cmd-shift-c")], .copy)
        XCTAssertNil(view.shortcuts[try KeyChord("cmd-c")])
        terminal.options.copyOnSelect = false
        model.apply(terminalSettings: terminal)
        XCTAssertEqual(view.settings.options.copyOnSelect, false, "the terminal override wins over the app preference")
    }
}
