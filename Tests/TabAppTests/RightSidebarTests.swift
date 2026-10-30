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
