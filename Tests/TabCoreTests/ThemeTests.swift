import XCTest
@testable import TabCore

final class ThemeTests: XCTestCase {
    func testThemeFilesParseColorsAndSkipWhatTheyDoNotUnderstand() {
        let scheme = ColorScheme.parse("""
        # a comment
        palette = 0=#262427
        palette = 15 = #FCFCFA
        palette = 300=#ffffff
        palette = 2=nonsense
        background = #111111
        foreground=d5cec7
        cursor-color = cell-foreground
        cursor-text = #000000
        selection-background = red
        unknown-key = 1
        """)
        XCTAssertEqual(scheme.palette, [0: RGBColor(0x262427), 15: RGBColor(0xFCFCFA)])
        XCTAssertEqual(scheme.background, RGBColor(0x111111))
        XCTAssertEqual(scheme.foreground, RGBColor(0xD5CEC7))
        XCTAssertEqual(scheme.cursorColor, .cellForeground)
        XCTAssertEqual(scheme.cursorText, .rgb(RGBColor(0)))
        XCTAssertNil(scheme.selectionBackground, "theme files take hex colors only")
    }

    func testTheBundledCatalogStartsWithTabsOwnThemes() throws {
        let catalog = ThemeCatalog.load(customDirectory: nil)
        XCTAssertGreaterThan(catalog.entries.count, 400)
        XCTAssertEqual(catalog.entries.prefix(2).map(\.name), ["Tab", "Tab Light"])
        XCTAssertTrue(catalog.errors.isEmpty, "\(catalog.errors)")
        let tab = try XCTUnwrap(catalog.find("Tab"))
        XCTAssertEqual(tab.scheme.background, RGBColor(0x111111))
        XCTAssertEqual(tab.scheme.foreground, RGBColor(0xD5CEC7))
        XCTAssertEqual(tab.scheme.swatches.count, 16)
        let rest = catalog.entries.dropFirst(2).map { $0.name.lowercased() }
        XCTAssertEqual(rest, rest.sorted())
    }

    func testCustomThemesReplaceBundledOnesAndInvalidOnesAreReported() throws {
        let directory = try TemporaryDirectory()
        try directory.write("Dracula.conf", "background = #000000\nforeground = #ffffff\npalette = 4=#0000ff\n")
        try directory.write("Broken", "background = #000000\n")
        try directory.write(".hidden", "background = nonsense")
        let catalog = ThemeCatalog.load(customDirectory: directory.url)
        XCTAssertEqual(catalog.find("Dracula")?.scheme.background, RGBColor(0))
        XCTAssertEqual(catalog.find("Dracula.conf")?.name, "Dracula")
        XCTAssertEqual(catalog.errors, ["Theme Broken needs valid background and foreground colors"])
        XCTAssertEqual(catalog.selected(darkTheme: "Dracula", lightTheme: "Missing", dark: true)?.name, "Dracula")
        XCTAssertEqual(catalog.selected(darkTheme: "Dracula", lightTheme: "Missing", dark: false)?.name, "Tab Light")
    }

    func testTheChromePaletteFollowsTheTheme() {
        let dark = ChromePalette(scheme: ColorScheme.parse("background = #111111\nforeground = #d5cec7\npalette = 4=#C370D3\npalette = 1=#EC4899\n"))
        XCTAssertFalse(dark.isLight)
        XCTAssertEqual(dark.bg, ChromeColor(RGBColor(0x111111)))
        XCTAssertEqual(dark.fgMuted.alpha, 0.65)
        XCTAssertEqual(dark.border.alpha, 1)
        XCTAssertEqual(dark.border.red, 0.12 * RGBColor(0xD5CEC7).red + 0.88 * RGBColor(0x111111).red, accuracy: 1e-9)
        XCTAssertEqual(dark.accent, ChromeColor(RGBColor(0xC370D3)))
        XCTAssertEqual(dark.accentForeground, ChromeColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(dark.diffRemove, dark.danger)
        XCTAssertEqual(dark.diffHunk, dark.accent, "no palette 6 falls back to the accent")
        let light = ChromePalette(scheme: ColorScheme.parse("background = #f0f0f5\nforeground = #1e1e2e\npalette = 4=#ffff00\n"))
        XCTAssertTrue(light.isLight)
        XCTAssertEqual(light.accentForeground, ChromeColor(red: 0, green: 0, blue: 0))
        XCTAssertEqual(ChromePalette(scheme: ColorScheme()).bg, ChromeColor(RGBColor(0x111111)))
    }

    func testColorsCodeAsHexStrings() throws {
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(RGBColor(0xABCDEF)), as: UTF8.self), ##""#abcdef""##)
        XCTAssertEqual(try JSONDecoder().decode(RGBColor.self, from: Data(#""grey""#.utf8)), RGBColor(0xBEBEBE))
        XCTAssertThrowsError(try JSONDecoder().decode(RGBColor.self, from: Data(##""#12345""##.utf8)))
        XCTAssertEqual(try roundTrip([CellColor.cellBackground, .rgb(RGBColor(1))]), [.cellBackground, .rgb(RGBColor(1))])
    }
}
