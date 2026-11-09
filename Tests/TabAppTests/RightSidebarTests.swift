import AppKit
import XCTest
import TabCore
@testable import TabApp

@MainActor
final class RightSidebarTests: XCTestCase {
    private func model() throws -> AppModel {
        let dirs = try ModelFixtures.profile()
        let model = AppModel(dirs: dirs, theme: AppTheme(systemIsDark: true)) { _, _ in nil }
        addTeardownBlock { try? FileManager.default.removeItem(at: dirs.root) }
        return model
    }

    func testPaneZoomTemporarilyHidesBothSidebars() throws {
        let model = try model()
        model.newHomeTerminal()
        XCTAssertNotNil(model.activePane)
        model.updateAppearance { $0.sidebarExpanded = true }
        model.selectRightPanel(.sourceControl)

        model.toggleZoom()
        XCTAssertNotNil(model.activeTab?.zoomed)
        XCTAssertFalse(model.sidebarExpanded)
        XCTAssertNil(model.rightPanel)
        XCTAssertTrue(model.appearance.sidebarExpanded)
        XCTAssertEqual(model.appearance.sidePanel, .sourceControl)

        model.toggleZoom()
        XCTAssertTrue(model.sidebarExpanded)
        XCTAssertEqual(model.rightPanel, .sourceControl)

        model.toggleSidebar()
        model.toggleRightSidebar()
        model.toggleZoom()
        model.toggleZoom()
        XCTAssertFalse(model.sidebarExpanded)
        XCTAssertNil(model.rightPanel)
    }

    func testOpeningEitherSidebarExitsPaneZoom() throws {
        let model = try model()
        model.newHomeTerminal()
        model.selectRightPanel(.files)
        model.toggleZoom()
        model.toggleRightPanel(.files)
        XCTAssertNil(model.activeTab?.zoomed)
        XCTAssertEqual(model.rightPanel, .files)

        model.toggleZoom()
        model.toggleSidebar()
        XCTAssertNil(model.activeTab?.zoomed)
        XCTAssertTrue(model.sidebarExpanded)
    }

    /// Turning the sidebar on in Settings shows it even over an expanded pane.
    func testShowingTheSidebarFromSettingsExitsPaneZoom() throws {
        let model = try model()
        model.newHomeTerminal()
        model.updateAppearance { $0.sidebarExpanded = false }
        model.toggleZoom()
        var settings = model.settings
        settings.appearance.sidebarExpanded = true
        model.apply(settings: settings)
        XCTAssertNil(model.activeTab?.zoomed)
        XCTAssertTrue(model.sidebarExpanded)
    }

    func testCollapsingAndShowingAgainReopensTheLastTab() throws {
        let model = try model()
        model.toggleRightSidebar()
        XCTAssertEqual(model.rightPanel, .files, "Files the first time")
        model.selectRightPanel(.sourceControl)
        model.toggleRightSidebar()
        XCTAssertNil(model.rightPanel)
        model.toggleRightSidebar()
        XCTAssertEqual(model.rightPanel, .sourceControl)
        XCTAssertEqual(try Appearance.load(model.dirs.settings).lastSidePanel, .sourceControl, "remembered across launches")
    }

    func testSelectingTheShownTabKeepsItOpenAndItsShortcutClosesIt() throws {
        let model = try model()
        model.selectRightPanel(.files)
        model.selectRightPanel(.files)
        XCTAssertEqual(model.rightPanel, .files)
        model.toggleRightPanel(.sourceControl)
        XCTAssertEqual(model.rightPanel, .sourceControl, "another tab's shortcut switches")
        model.toggleRightPanel(.sourceControl)
        XCTAssertNil(model.rightPanel)
    }
}
