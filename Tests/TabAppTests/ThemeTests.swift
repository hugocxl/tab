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
        XCTAssertEqual(TabCore.RGBColor(theme.bg), TabCore.RGBColor(0x1A1A19))
        XCTAssertEqual(TabCore.RGBColor(theme.fg), TabCore.RGBColor(0xCECDC8))
    }

    func testCardBlendsMatchStyleGuide() {
        let palette = AppTheme(catalog: ThemeCatalog(entries: []), systemIsDark: true).palette
        let card = AppTheme.card(palette)
        // 2.5% of #cecdc8 over #1a1a19 is about #1f1f1e.
        XCTAssertEqual(card.red * 255, 31, accuracy: 1)
        XCTAssertEqual(card.alpha, 1)
        XCTAssertEqual(AppTheme.chrome(palette), palette.bg)
    }

    func testLightThemesKeepCardsOnTheBackgroundAndDarkenTheChrome() {
        let palette = AppTheme(catalog: catalog(), darkTheme: "Night", lightTheme: "Day", systemIsDark: false).palette
        XCTAssertEqual(AppTheme.card(palette), palette.bg)
        // Cards must stand above the sidebar and window, not sink below them.
        XCTAssertLessThan(AppTheme.chrome(palette).lightness, AppTheme.card(palette).lightness)
    }

    func testIconHuesFollowThemeBrightness() {
        let theme = AppTheme(catalog: catalog(), darkTheme: "Night", lightTheme: "Day", systemIsDark: true)
        let hues: [(AppTheme.IconHue, String, String)] = [
            (.gray, "#adadb1", "#6c6c71"),
            (.red, "#ff6762", "#d52c36"),
            (.vermilion, "#ff8c5b", "#d5512f"),
            (.orange, "#ffa359", "#d47628"),
            (.yellow, "#ffd452", "#d5a910"),
            (.green, "#5ecc71", "#199f43"),
            (.mint, "#61d5c0", "#16a994"),
            (.teal, "#64d1db", "#17a5af"),
            (.cyan, "#68cdf2", "#1ca1c7"),
            (.blue, "#69b1ff", "#1a85d4"),
            (.indigo, "#9d6afb", "#693acf"),
            (.purple, "#d568ea", "#a631be"),
            (.pink, "#ff678d", "#d32a61"),
            (.brown, "#c3987b", "#956b4f"),
        ]
        XCTAssertEqual(Set(hues.map { $0.0 }), Set(AppTheme.IconHue.allCases))
        for (hue, dark, light) in hues {
            theme.setSystemDark(true)
            XCTAssertEqual(theme.iconHex(hue), dark)
            theme.setSystemDark(false)
            XCTAssertEqual(theme.iconHex(hue), light)
        }
        // Palette brightness, rather than system appearance, chooses the shade.
        theme.setThemes(dark: "Day", light: "Day")
        theme.setSystemDark(true)
        XCTAssertEqual(theme.iconHex(.gray), "#6c6c71")
    }

    func testEveryIconHasAnImage() {
        for icon in AppIcon.allCases {
            XCTAssertNotNil(icon.image(), "\(icon.rawValue).svg did not load")
        }
    }

    func testEveryBundledSVGHasAnIconCase() throws {
        let folder = try XCTUnwrap(BundledImage.tabIconURL("folder")).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let names = Set(files.filter { $0.pathExtension == "svg" }.map { $0.deletingPathExtension().lastPathComponent })
        XCTAssertEqual(names, Set(AppIcon.allCases.map(\.rawValue)))
    }

    /// Wide and narrow icons come back on the same square canvas as the rest,
    /// so rows and buttons lay them out alike; the glyph is centered in it.
    func testIconsShareASquareCanvas() throws {
        for icon in [AppIcon.folder, .foldVertical, .history, .check] {
            let image = try XCTUnwrap(icon.image(size: 16))
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16), "\(icon.rawValue)")
            let ink = image.inkBounds
            XCTAssertEqual(ink.midX, 8, accuracy: 1, "\(icon.rawValue) is off center")
            XCTAssertEqual(ink.midY, 8, accuracy: 1, "\(icon.rawValue) is off center")
        }
        let folder = try XCTUnwrap(AppIcon.folder.image(size: 16))
        XCTAssertTrue(folder.isTemplate)
        XCTAssertTrue(folder === AppIcon.folder.image(size: 16))
        let tinted = try XCTUnwrap(AppIcon.folder.image(size: 16, color: .systemBlue))
        XCTAssertEqual(tinted.size, folder.size)
        XCTAssertFalse(tinted.isTemplate)
        XCTAssertTrue(tinted === AppIcon.folder.image(size: 16, color: .systemBlue))
    }
}

@MainActor
final class ThemeTerminalIntegrationTests: XCTestCase {
    func testTerminalAndAppPreferencesReachExistingTerminalPanes() async throws {
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
        terminal.cursorStyle = .underline
        terminal.improveContrast = false
        model.apply(terminalSettings: terminal)
        let view = try XCTUnwrap(pane.session?.view)
        XCTAssertEqual(view.palette.cursorStyle, .underline)
        XCTAssertEqual(view.palette.minimumContrast, 1)
        var settings = model.settings
        settings.keymap = try Keymap.fromOverrides([ShortcutId.copy.rawValue: "cmd-shift-c"])
        model.apply(settings: settings)
        XCTAssertEqual(view.shortcuts[try KeyChord("cmd-shift-c")], .copy)
        XCTAssertNil(view.shortcuts[try KeyChord("cmd-c")])
    }
}
