import TabProtocol
import XCTest
@testable import TabMobileKit

/// Tab Icons follow the desktop's names and rules, and every icon ships.
final class TabIconTests: XCTestCase {
    func testUnpublishedIconsRemainInTheAssetCatalog() throws {
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../App/Resources/Assets.xcassets/TabIcons").standardized
        let shipped = try Set(FileManager.default.contentsOfDirectory(atPath: catalog.path)
            .filter { $0.hasSuffix(".imageset") }.map { String($0.dropLast(".imageset".count)) })
        XCTAssertEqual(shipped, Set(["view-list", "view-tree"]))
    }

    func testTerminalsShowTheirCommand() {
        func icon(_ name: String, shell: Bool = false) -> TabIcon {
            TabIcon.command(ForegroundProcess(name: name, isShell: shell))
        }
        XCTAssertEqual(TabIcon.command(nil), .bash)
        XCTAssertEqual(icon("zsh", shell: true), .bash)
        XCTAssertEqual(icon("node"), .node)
        XCTAssertEqual(icon("/opt/homebrew/bin/pnpm"), .pnpm)
        XCTAssertEqual(icon("python3.12"), .python)
        XCTAssertEqual(icon("-zsh"), .bash)
        XCTAssertEqual(icon("vim"), .vim)
        XCTAssertEqual(icon("some-tool"), .terminal)
    }

    func testFilesShowTheirType() {
        XCTAssertEqual(TabIcon.file("Sources/App.swift"), .swift)
        XCTAssertEqual(TabIcon.file("package.json"), .npm)
        XCTAssertEqual(TabIcon.file("README"), .file)
    }

    func testAgentsShowTheirProvidersMark() {
        XCTAssertEqual(TabIcon.agent(.claude), .claude)
        XCTAssertEqual(TabIcon.agent(.unknown("new")), .brain)
        XCTAssertEqual(TabIcon.claude.signatureHue, .orange)
        XCTAssertNil(TabIcon.gitBranch.signatureHue, "UI glyphs take their surroundings' tint")
    }
}
