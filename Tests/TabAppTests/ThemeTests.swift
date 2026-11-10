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
        XCTAssertEqual(TabCore.RGBColor(theme.bg), TabCore.RGBColor(0x232721))
        XCTAssertEqual(TabCore.RGBColor(theme.fg), TabCore.RGBColor(0xCED0C6))
    }

    func testCardBlendsMatchStyleGuide() {
        let palette = AppTheme(catalog: ThemeCatalog(entries: []), systemIsDark: true).palette
        let card = AppTheme.card(palette)
        // 2.5% of #ced0c6 over #232721 is #272b25.
        XCTAssertEqual(TabCore.RGBColor(card.nsColor), TabCore.RGBColor(0x272B25))
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

    /// Editor, diff and panel controllers color plain AppKit labels once, so
    /// they must hear of a theme change, including one made while hidden.
    func testViewsReportColorChangesToTheirControllers() async throws {
        let theme = AppTheme(catalog: catalog(), darkTheme: "Night", lightTheme: "Day", systemIsDark: true)
        let view = ThemedView()
        view.theme = theme
        var changes = 0
        view.onColorsChange = { changes += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: true)
        window.contentView?.addSubview(view)
        XCTAssertEqual(changes, 0, "showing a view is not a change")

        theme.setSystemDark(false)
        for _ in 0..<200 where changes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(changes, 1)

        view.removeFromSuperview()
        theme.setSystemDark(true)
        window.contentView?.addSubview(view)
        XCTAssertEqual(changes, 2)
        view.removeFromSuperview()
        window.contentView?.addSubview(view)
        XCTAssertEqual(changes, 2)
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

/// Tab's own themes: readable text on every surface, and the copies the app
/// falls back to before the catalog loads.
final class BuiltInThemeTests: XCTestCase {
    private func builtIn(dark: Bool) throws -> (scheme: ColorScheme, palette: ChromePalette) {
        let catalog = ThemeCatalog.load(customDirectory: nil)
        let name = dark ? ThemeCatalog.defaultDark : ThemeCatalog.defaultLight
        let scheme = try XCTUnwrap(catalog.find(name)).scheme
        return (scheme, ChromePalette(scheme: scheme))
    }

    private func contrast(_ text: ChromeColor, on surface: ChromeColor) -> Double {
        let opaque = text.blended(over: surface, amount: text.alpha)
        return TerminalPalette.contrast(TerminalPalette.luminance(TabCore.RGBColor(opaque.nsColor).value),
                                        TerminalPalette.luminance(TabCore.RGBColor(surface.nsColor).value))
    }

    func testFallbackColorsMatchTheBundledThemes() throws {
        for dark in [true, false] {
            let (scheme, _) = try builtIn(dark: dark)
            let fallback = TerminalPalette(dark: dark)
            let themed = TerminalPalette(scheme: scheme, dark: dark)
            XCTAssertEqual(fallback.background, themed.background, "dark: \(dark)")
            XCTAssertEqual(fallback.foreground, themed.foreground, "dark: \(dark)")
            XCTAssertEqual(fallback.colors, themed.colors, "dark: \(dark)")
        }
        let (scheme, palette) = try builtIn(dark: true)
        let fallback = ChromePalette(scheme: ColorScheme())
        for role in [\ChromePalette.bg, \.fg, \.accent, \.accentForeground, \.warning, \.danger, \.diffAdd] {
            XCTAssertEqual(fallback[keyPath: role], palette[keyPath: role])
        }
        XCTAssertEqual(SyntaxColors(scheme: ColorScheme(), palette: palette).foreground, scheme.foreground)
    }

    func testTextStaysLegibleOnPanesAndChrome() throws {
        for dark in [true, false] {
            let (scheme, palette) = try builtIn(dark: dark)
            for surface in [AppTheme.card(palette), AppTheme.chrome(palette)] {
                let context = "dark: \(dark), surface: \(TabCore.RGBColor(surface.nsColor))"
                XCTAssertGreaterThanOrEqual(contrast(palette.fg, on: surface), 7, context)
                XCTAssertGreaterThanOrEqual(contrast(palette.fgMuted, on: surface), 4.5, context)
                XCTAssertGreaterThanOrEqual(contrast(palette.accent, on: surface), 4.5, context)
            }
            XCTAssertGreaterThanOrEqual(contrast(palette.accentForeground, on: palette.accent), 4.5, "dark: \(dark)")
            // No yellow reaches 4.5 on paper and still reads as yellow.
            let card = AppTheme.card(palette)
            for index in 1...14 where index != 7 {
                let color = ChromeColor(try XCTUnwrap(scheme.paletteColor(index)))
                let minimum = index >= 8 ? 3 : dark ? 4.5 : 3.9
                XCTAssertGreaterThanOrEqual(contrast(color, on: card), minimum, "dark: \(dark), color \(index)")
            }
            let selection = try XCTUnwrap(scheme.selectionBackground).resolve(foreground: palette.fg.rgb, background: card.rgb)
            let selected = try XCTUnwrap(scheme.selectionForeground).resolve(foreground: palette.fg.rgb, background: card.rgb)
            XCTAssertGreaterThanOrEqual(contrast(ChromeColor(selected), on: ChromeColor(selection)), 7, "dark: \(dark)")
            XCTAssertGreaterThanOrEqual(contrast(ChromeColor(selection), on: card), 1.25, "dark: \(dark)")
        }
    }

    /// Status dots differ only by color: connected, connecting and failing
    /// servers draw in the accent, the warning and the danger color.
    func testAccentWarningAndDangerStayApart() throws {
        for dark in [true, false] {
            let (_, palette) = try builtIn(dark: dark)
            let colors = [palette.accent, palette.warning, palette.danger].map { $0.rgb.value }
            for (first, second) in [(0, 1), (0, 2), (1, 2)] {
                XCTAssertGreaterThanOrEqual(TerminalPalette.distance(colors[first], colors[second]).squareRoot(), 85,
                                            "dark: \(dark), \(first) and \(second)")
            }
        }
    }
}

private extension ChromeColor {
    var rgb: TabCore.RGBColor { TabCore.RGBColor(nsColor) }
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
