import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentToolVirtualizationTests: XCTestCase {
    override func tearDown() async throws {
        await finishAgentNativeFixtureCleanup()
        try await super.tearDown()
    }

    func testFiveHundredToolsUseMainViewportAndBoundCache() throws {
        let document = makeDocument()
        XCTAssertEqual(document.entryCount, 500)
        XCTAssertGreaterThan(document.frame.height, 15_000)
        XCTAssertLessThan(document.mountedRowCount, 70)
        for index in stride(from: 0, through: 450, by: 30) {
            let target = try XCTUnwrap(document.frameForEntry("activity:tool-\(index)"))
            document.updateViewport(NSRect(x: 0, y: target.minY, width: 600, height: 360), followingEnd: false)
            XCTAssertLessThan(document.mountedRowCount, 70)
            XCTAssertLessThanOrEqual(document.retainedRowCount, document.mountedRowCount + 32)
        }
        let measured = document.measurementCount
        for _ in 0..<10 { document.reflow(viewportWidth: 600) }
        XCTAssertEqual(document.measurementCount, measured)
    }

    func testGroupStateMigrationAndOffscreenOutputUpdates() throws {
        let document = makeDocument()
        document.rowStates = ["activity:tool-0": AgentTimelineRowState(toolExpandedIDs: ["tool-0", "tool-400"])]
        XCTAssertEqual(document.rowStates["activity:tool-400"]?.toolExpandedIDs, ["tool-400"])
        let target = try XCTUnwrap(document.frameForEntry("activity:tool-200"))
        document.updateViewport(NSRect(x: 0, y: target.minY, width: 600, height: 360), followingEnd: false)
        let anchor = document.captureAnchor(at: document.viewportOrigin)
        let measurements = document.measurementCount
        var items = tools()
        items[0].detail = String(repeating: "Additional output\n", count: 1000)
        document.update(items, omittedCount: 0)
        XCTAssertEqual(document.measurementCount, measurements)
        XCTAssertEqual(document.captureAnchor(at: document.viewportOrigin).rowID, anchor.rowID)
        let restored = AgentTranscriptDocument(frame: .zero)
        restored.update(items, omittedCount: 0)
        restored.rowStates = document.rowStates
        XCTAssertEqual(restored.rowStates["activity:tool-400"]?.toolExpandedIDs, ["tool-400"])
    }

    func testFocusedToolSelectionSurvivesMainTimelineScrolling() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 360),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let document = makeDocument()
        window.contentView = document
        document.rowStates = ["activity:tool-0": AgentTimelineRowState(toolExpandedIDs: ["tool-0"])]
        document.reflow(viewportWidth: 600)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let text = try XCTUnwrap(descendants(document).compactMap { $0 as? NSTextView }.first { !$0.string.isEmpty })
        text.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertTrue(window.makeFirstResponder(text))
        for index in stride(from: 30, through: 450, by: 30) {
            let target = try XCTUnwrap(document.frameForEntry("activity:tool-\(index)"))
            document.updateViewport(NSRect(x: 0, y: target.minY, width: 600, height: 360), followingEnd: false)
            XCTAssertTrue(window.firstResponder === text)
            XCTAssertTrue(text.isDescendant(of: document))
            XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 4))
            XCTAssertLessThan(document.mountedRowCount, 70)
        }
        window.makeFirstResponder(nil)
    }

    private func makeDocument() -> AgentTranscriptDocument {
        let document = AgentTranscriptDocument(frame: .zero)
        document.update(tools(), omittedCount: 0)
        document.reflow(viewportWidth: 600)
        document.updateViewport(NSRect(x: 0, y: 0, width: 600, height: 360), followingEnd: false)
        return document
    }

    private func tools() -> [AgentChatItem] {
        (0..<500).map { .init(id: "tool-\($0)", kind: .tool, text: "Read", detail: "File \($0) contents") }
    }
}
