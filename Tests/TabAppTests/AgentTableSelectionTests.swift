import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentTableSelectionTests: XCTestCase {
    func testSelectionSpansRowsAndSurvivesResizeAndStreamingAppend() throws {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: .zero)
        let source = "| Name | Value |\n| --- | ---: |\n| **Alpha** | 12 |\n| Beta | 34 |"
        response.setContent(source, theme: AppTheme(systemIsDark: false))
        _ = response.height(for: 400)
        let table = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseTable }.first)
        let text = table.text
        let value = text.string as NSString
        let start = value.range(of: "Alpha").location
        let end = NSMaxRange(value.range(of: "34"))
        let range = NSRange(location: start, length: end - start)
        text.setSelectedRange(range)
        XCTAssertEqual(text.attributedSubstring(forProposedRange: range, actualRange: nil)?.string, "Alpha\n12\nBeta\n34")
        let style = try XCTUnwrap(text.textStorage?.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)
        let block = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(block.table.numberOfColumns, 2)
        XCTAssertEqual(block.startingRow, 1)
        _ = response.height(for: 160)
        XCTAssertEqual(text.selectedRange(), range)
        response.setContent(source + "\n| Gamma | 56 |", theme: AppTheme(systemIsDark: false))
        _ = response.height(for: 160)
        XCTAssertEqual(text.selectedRange(), range)
        XCTAssertTrue(text.string.contains("Gamma"))
        XCTAssertEqual(table.copyText(.csv), "Name,Value\nAlpha,12\nBeta,34\nGamma,56")
    }

    func testTableCopyFeedbackResets() async throws {
        let restoreClipboard = preserveAgentTestClipboard()
        defer { restoreClipboard() }
        let table = AgentResponseTable(frame: .zero)
        table.copyToPasteboard(.csv)
        XCTAssertEqual(table.copy.toolTip, "Copied")
        try await Task.sleep(for: .milliseconds(1350))
        XCTAssertEqual(table.copy.toolTip, "Copy table")
        XCTAssertEqual(table.copy.title, "")
    }
}
