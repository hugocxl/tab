import AppKit
import TabProtocol
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentFileChangePanelTests: XCTestCase {
    func testWorkspacePathsAndPatchLinesThatResembleHeaders() {
        XCTAssertEqual(AgentFileChangePanel.displayPath("/work/project/Sources/file.swift:12:4", root: "/work/project/"), "project/Sources/file.swift:12:4")
        XCTAssertEqual(AgentFileChangePanel.displayPath("./Sources/file.swift", root: "/work/project"), "project/Sources/file.swift")
        XCTAssertEqual(AgentFileChangePanel.displayPath("/C:/WORK/Project/src/a.ts", root: "C:\\work\\project"), "project/src/a.ts")
        XCTAssertEqual(AgentFileChangePanel.displayPath("/elsewhere/a.ts", root: "/work/project"), "/elsewhere/a.ts")
        XCTAssertEqual(AgentFileChangePanel.displayPath("/work/project:0012:04", root: "/work/project"), "project:12:4")
        XCTAssertEqual(AgentFileChangePanel.displayPath("/work/project:0:4", root: "/work/project"), "project")
        let diff = AgentToolDiff.parse("--- a/file\n+++ b/file\n@@ -2,2 +2,2 @@\n--- previous\n+++ next\n context\n")
        XCTAssertEqual(diff.additions, 1); XCTAssertEqual(diff.deletions, 1)
        XCTAssertEqual(diff.rows[1].oldText, "-- previous")
        XCTAssertEqual(diff.rows[2].newText, "++ next")
        XCTAssertEqual(diff.rows.last?.oldLineNumber, 3)
        XCTAssertEqual(diff.rows.last?.newLineNumber, 3)
    }

    func testUnknownPatchCountDoesNotBecomeAVisibleZero() {
        let panel = AgentFileChangePanel(frame: .zero)
        var activity = AgentToolActivity(name: "Change", category: .edit)
        activity.fileChangeDetails = .init(fileName: "file.swift", additions: nil, deletions: 3)
        panel.update(activity, root: nil, theme: AppTheme(systemIsDark: false))
        let text = panel.subviews.compactMap { $0 as? AgentRichTextView }.map(\.string)
        XCTAssertTrue(text.contains("-3"))
        XCTAssertFalse(text.contains { $0.contains("+0") })
    }

    func testSuccessfulPanelIsCompactAndDiffActionUsesToolIdentity() throws {
        _ = NSApplication.shared
        var activity = AgentToolActivity(name: "fileChange", category: .edit, status: .completed, filePaths: ["src/a.ts"], presentation: .fileChange)
        activity.fileChangeDetails = .init(fileName: "/work/project/src/a.ts", diff: "-before\n+after", additions: 2, deletions: 1,
            operations: [.init(operation: "update", path: "src/a.ts", oldPath: "src/old.ts", fileType: "text", mimeType: "text/plain")])
        let row = AgentToolDisclosure(frame: .zero)
        row.workspaceRoot = "/work/project"
        var opened: (String, AgentToolActivity)?
        row.onOpenToolDiff = { opened = ($0, $1) }
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            row.update(.init(id: "tool-123", kind: .tool, text: "src/a.ts", tool: activity), expanded: true, theme: theme)
            row.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            row.wantsLayer = true; row.layer?.backgroundColor = theme.bg.cgColor
            for width: CGFloat in [420, 240] {
                row.frame.size = NSSize(width: width, height: row.height(for: width)); row.layoutSubtreeIfNeeded()
                let panel = try XCTUnwrap(row.subviews.compactMap { $0 as? AgentFileChangePanel }.first)
                XCTAssertEqual(panel.frame.minY, 28)
                XCTAssertFalse(panel.isHidden)
                XCTAssertEqual(panel.frame.height, width == 240 ? 80 : 48)
                XCTAssertTrue(panel.subviews.compactMap { $0 as? NSScrollView }.allSatisfy(\.isHidden))
                let button = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSButton }.first)
                XCTAssertEqual(button.title, "Open diff")
                button.performClick(nil)
                XCTAssertEqual(opened?.0, "tool-123"); XCTAssertEqual(opened?.1, activity)
                if let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
                    row.cacheDisplay(in: row.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory + "/file-change-\(dark ? "dark" : "light")-\(Int(width)).png"))
                }
            }
        }
    }

    func testFailedOutputIsBoundedAndRetainsScrollPosition() throws {
        let panel = AgentFileChangePanel(frame: .zero)
        var activity = AgentToolActivity(status: .failed, presentation: .fileChange)
        activity.fileChangeDetails = .init(fileName: "file.txt", diff: String(repeating: "failure detail\n", count: 100))
        panel.update(activity, root: nil, theme: AppTheme(systemIsDark: false))
        let height = panel.arrange(width: 300, apply: true)
        XCTAssertEqual(height, 352)
        let scroll = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSScrollView }.first)
        XCTAssertFalse(scroll.isHidden)
        XCTAssertEqual(scroll.frame.height, 320)
        panel.restoreOutputScrollPosition(NSPoint(x: 0, y: 200))
        panel.arrange(width: 300, apply: true)
        XCTAssertEqual(panel.outputScrollPosition.y, 200)
        panel.compactControls = false
        XCTAssertEqual(panel.arrange(width: 300, apply: true), 356)
    }

    func testToolDiffWindowUsesRecordedPatch() async throws {
        _ = NSApplication.shared
        var activity = AgentToolActivity(presentation: .fileChange)
        activity.fileChangeDetails = .init(fileName: "file.swift", diff: "@@ -1,1 +1,1 @@\n-before\n+recorded\n")
        let controller = AgentToolDiff.makeWindow(session: SessionId(), activity: activity, theme: AppTheme(systemIsDark: false))
        defer { controller.close() }
        activity.fileChangeDetails?.diff = "+later change"
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let root = try XCTUnwrap(controller.window?.contentView)
        let diff = try XCTUnwrap(descendants(root).compactMap { $0 as? DiffRowsView }.first)
        for _ in 0..<100 where diff.document == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(diff.document?.rows.last?.text, "+recorded")
        XCTAssertEqual(controller.window?.title, "Tool changes")
    }
}
