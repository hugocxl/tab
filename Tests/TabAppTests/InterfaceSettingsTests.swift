import AppKit
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class InterfaceSettingsTests: XCTestCase {
    func testForcedAppearanceSurvivesSystemChangesAndAutoRestoresThem() {
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: true)
        var appearance = Appearance()
        appearance.colorScheme = .light
        theme.setInterface(appearance)
        XCTAssertTrue(theme.isLight)
        theme.setSystemDark(false)
        appearance.colorScheme = .dark
        theme.setInterface(appearance)
        XCTAssertFalse(theme.isLight)
        appearance.colorScheme = .auto
        theme.setInterface(appearance)
        XCTAssertTrue(theme.isLight)
    }

    func testInterfaceEditsPreserveConcurrentSidebarChangesAndUnknownKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        try Data(#"{"appearance":{"futureOption":42},"futureSection":{"keep":true}}"#.utf8).write(to: file)
        let original = try Appearance.load(file)
        var sidebar = original
        sidebar.sidebarExpanded = false
        try sidebar.saveChanges(since: original, to: file)
        var interface = original
        interface.interfaceStyle = .glass
        interface.glassPanes = false
        interface.animationStyle = .snappy
        interface.colorScheme = .dark
        interface.preservePaneWidth = true
        interface.sidebarGesture = .swipe
        let saved = try interface.saveChanges(since: original, to: file)
        XCTAssertFalse(saved.sidebarExpanded)
        XCTAssertEqual(saved.interfaceStyle, .glass)
        XCTAssertFalse(saved.glassPanes)
        XCTAssertEqual(saved.animationStyle, .snappy)
        XCTAssertEqual(saved.colorScheme, .dark)
        XCTAssertTrue(saved.preservePaneWidth)
        XCTAssertEqual(saved.sidebarGesture, .swipe)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((document["appearance"] as? [String: Any])?["futureOption"] as? Int, 42)
        XCTAssertEqual((document["futureSection"] as? [String: Bool])?["keep"], true)
    }

    func testGlassMakesAllNativeBackgroundsTranslucentAndClassicRestoresThem() throws {
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: true)
        var appearance = Appearance()
        appearance.interfaceStyle = .glass
        theme.setInterface(appearance)
        guard !theme.accessibility.reduceTransparency else { throw XCTSkip("Reduce Transparency intentionally keeps opaque backgrounds") }
        for color in [theme.bg, theme.chrome, theme.card, theme.surface, theme.raised, theme.floating, NativeStyle.panel(theme)] {
            XCTAssertLessThan(color.alphaComponent, 1)
        }
        XCTAssertEqual(theme.paneBackground.alphaComponent, 0)
        appearance.glassPanes = false
        theme.setInterface(appearance)
        XCTAssertEqual(theme.card.alphaComponent, 1)
        XCTAssertLessThan(theme.chrome.alphaComponent, 1)
        appearance.interfaceStyle = .classic
        theme.setInterface(appearance)
        for color in [theme.bg, theme.chrome, theme.card, theme.raised, NativeStyle.panel(theme)] {
            XCTAssertEqual(color.alphaComponent, 1)
        }
    }

    func testOffRemovesAnExistingTransition() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.wantsLayer = true
        window.contentView?.addSubview(view)
        InterfaceMotion.animate(view, from: nil, style: .natural)
        InterfaceMotion.animate(view, from: nil, style: .off)
        XCTAssertNil(view.layer?.animation(forKey: "interface"))
    }
}
