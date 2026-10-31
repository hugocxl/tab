import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentFileSearchPanelTests: XCTestCase {
    func testTypedSearchGeometryAndPreservedPreviewWhitespace() throws {
        _ = NSApplication.shared
        var activity = AgentToolActivity(name: "File search", category: .search, presentation: .fileSearch)
        activity.fileSearchDetails = .init(pattern: "render.*message\nAgentTranscript", results: [
            .init(fileName: "/work/project/src/a.ts", line: 12, column: 4, preview: "first matching line\n  indented continuation"),
            .init(fileName: "src/b.ts", line: 8, preview: "A longer preview that wraps naturally inside the conversation."),
            .init(fileName: "README.md"),
        ])
        let row = AgentToolDisclosure(frame: .zero)
        row.workspaceRoot = "/work/project"
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            row.update(.init(id: "search", kind: .tool, text: "File search", tool: activity), expanded: true, theme: theme)
            row.wantsLayer = true; row.layer?.backgroundColor = theme.bg.cgColor
            row.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width: CGFloat in [420, 240] {
                row.frame.size = NSSize(width: width, height: row.height(for: width)); row.layoutSubtreeIfNeeded()
                let panel = try XCTUnwrap(row.subviews.compactMap { $0 as? AgentFileSearchPanel }.first)
                XCTAssertEqual(panel.frame.minY, 28)
                let texts = panel.subviews.compactMap { $0 as? NSTextView }
                XCTAssertEqual(texts[1].string, "project/src/a.ts:12:4")
                XCTAssertEqual(texts[2].string, "first matching line\n  indented continuation")
                XCTAssertEqual(texts[1].frame.minY - texts[0].frame.maxY, 8)
                XCTAssertEqual(texts[2].frame.minY - texts[1].frame.maxY, 2)
                XCTAssertEqual(texts[3].frame.minY - texts[2].frame.maxY, 4)
                XCTAssertTrue(texts.last!.isHidden)
                XCTAssertEqual(panel.frame.height, width == 420 ? 158.25 : 174.25)
                if let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
                    row.cacheDisplay(in: row.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory + "/file-search-\(dark ? "dark" : "light")-\(Int(width)).png"))
                }
            }
        }
    }
    func testEmptyPatternsAndOptionalPositions() {
        let panel = AgentFileSearchPanel(frame: .zero)
        panel.update(.init(pattern: " \n "), root: nil, theme: AppTheme.shared)
        XCTAssertFalse(panel.hasContent)
        panel.update(.init(results: [.init(fileName: "one\n file.swift", column: 5)]), root: nil, theme: AppTheme.shared)
        XCTAssertTrue(panel.hasContent)
        let texts = panel.subviews.compactMap { $0 as? NSTextView }
        XCTAssertEqual(texts[1].string, "one file.swift:5")
        XCTAssertEqual(panel.arrange(width: 400, apply: true), 16)
    }
}
