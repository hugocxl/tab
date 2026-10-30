import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentToolDetailTests: XCTestCase {
    func testRecordedCommandOutputUsesTerminalColorsAndCarriageReturn() {
        let theme = AppTheme(systemIsDark: true)
        let text = AgentToolText.terminalText("\u{1b}[32mstream line 2\u{1b}[0m\nprogress 50%\rprogress 100%\n", theme: theme, terminal: true)
        XCTAssertEqual(text.string, "stream line 2\nprogress 100%\n")
        XCTAssertEqual(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemGreen)
        XCTAssertNotNil(text.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testInputOutputDiffAndFileLinksArePresentedTogether() {
        let theme = AppTheme(systemIsDark: true)
        var item = AgentChatItem(id: "edit", kind: .tool, text: "Edit")
        item.tool = AgentToolActivity(name: "Edit", category: .edit, input: #"{"file_path":"Sources/main.swift"}"#,
                                      output: "Updated", status: .completed, filePaths: ["Sources/main.swift"],
                                      fileChanges: [.init(path: "Sources/main.swift", diff: "-old\n+new", kind: "update")])
        let text = AgentToolText.content(item, theme: theme)
        XCTAssertTrue(text.string.contains("Input"))
        XCTAssertTrue(text.string.contains("Updated"))
        let added = (text.string as NSString).range(of: "+new")
        XCTAssertEqual(text.attribute(.foregroundColor, at: added.location, effectiveRange: nil) as? NSColor, .systemGreen)
        let removed = (text.string as NSString).range(of: "-old")
        XCTAssertEqual(text.attribute(.foregroundColor, at: removed.location, effectiveRange: nil) as? NSColor, .systemRed)
        let path = (text.string as NSString).range(of: "Sources/main.swift")
        XCTAssertEqual((text.attribute(.link, at: path.location, effectiveRange: nil) as? URL)?.scheme, "agent-file")
    }

    func testDisclosureTriggersParentReflowAndMeasuresExpandedContent() async throws {
        let view = AgentToolDetailView(items: [.init(kind: .tool, text: "Read", detail: "File contents")], theme: AppTheme(systemIsDark: true))
        let collapsed = view.height(for: 500)
        view.frame = NSRect(x: 0, y: 0, width: 500, height: collapsed)
        view.layoutSubtreeIfNeeded()
        var disclosures = 0
        view.onDisclosure = { disclosures += 1 }
        let button = try XCTUnwrap(descendants(view).compactMap { $0 as? PillButton }.first)
        button.onPress?()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertGreaterThan(disclosures, 0)
        XCTAssertGreaterThan(view.height(for: 500), collapsed)
        let beforeCollapse = disclosures
        button.onPress?()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertGreaterThan(disclosures, beforeCollapse)
        XCTAssertEqual(view.height(for: 500), collapsed)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
