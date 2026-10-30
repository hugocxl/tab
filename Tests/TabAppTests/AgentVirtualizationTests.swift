import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentVirtualizationTests: XCTestCase {
    private func makeDocument(_ items: [AgentChatItem]) -> AgentTranscriptDocument {
        let document = AgentTranscriptDocument(frame: .zero)
        document.reflow(viewportWidth: 720)
        document.update(items, omittedCount: 0)
        document.updateViewport(NSRect(x: 0, y: 0, width: 720, height: 600), followingEnd: false)
        return document
    }

    private func messages(_ count: Int) -> [AgentChatItem] {
        (0..<count).map { index in
            AgentChatItem(id: "message-\(index)", kind: .assistant,
                          text: "### Finding \(index)\n\nA selectable answer with **important context** and a [link](https://example.com).")
        }
    }

    func testThousandsOfMessagesDoNotCreateOrMeasureThousandsOfViews() {
        let document = makeDocument(messages(5_000))
        XCTAssertEqual(document.entryCount, 5_000)
        XCTAssertGreaterThan(document.mountedRowCount, 0)
        XCTAssertLessThan(document.mountedRowCount, 50)
        XCTAssertLessThan(document.retainedRowCount, 90)
        XCTAssertLessThan(document.measurementCount, 100)
        print("Agent virtualization: \(document.entryCount) entries; \(document.mountedRowCount) mounted rows; \(document.retainedRowCount) retained views; \(document.measurementCount) initial measurements")

        for fraction in [0.1, 0.4, 0.8, 0.99, 0.5, 0.0] {
            let y = max(0, document.frame.height - 600) * fraction
            document.updateViewport(NSRect(x: 0, y: y, width: 720, height: 600), followingEnd: false)
            XCTAssertGreaterThan(document.mountedRowCount, 0, "Jumping must mount the destination viewport")
            XCTAssertLessThan(document.mountedRowCount, 50)
            XCTAssertLessThan(document.retainedRowCount, 90, "Detached TextKit views must be evicted")
        }
        XCTAssertLessThan(document.measurementCount, 400, "Visiting a few viewports must not lay out all history")
    }

    func testStreamingRemeasuresOnlyChangedTailAndKeepsItsTextView() throws {
        var items = messages(2_000)
        items[items.count - 1].isComplete = false
        let document = makeDocument(items)
        document.updateViewport(NSRect(x: 0, y: max(0, document.frame.height - 600), width: 720, height: 600), followingEnd: true)
        let last = try XCTUnwrap(descendants(document).compactMap { $0 as? AgentRichTextView }
            .first { $0.string.contains("Finding 1999") })
        let before = document.measurementCount
        for _ in 0..<20 {
            items[items.count - 1].text += " streamed"
            document.update(items, omittedCount: 0)
            document.updateViewport(NSRect(x: 0, y: max(0, document.frame.height - 600), width: 720, height: 600), followingEnd: true)
        }
        XCTAssertTrue(last.isDescendant(of: document))
        XCTAssertTrue(last.string.hasSuffix("streamed"))
        XCTAssertLessThan(document.measurementCount - before, 80,
                          "Streaming must not trigger TextKit measurement for unchanged history")
        XCTAssertLessThan(document.retainedRowCount, 90)
    }

    func testCachedViewportAndOffscreenUpdatesDoNotPerformTextLayout() throws {
        var items = messages(1_000)
        let document = makeDocument(items)
        let first = try XCTUnwrap(descendants(document).compactMap { $0 as? AgentRichTextView }
            .first { $0.string.contains("Finding 0\n") })
        let originalText = first.string
        let before = document.measurementCount
        for _ in 0..<50 {
            document.updateViewport(NSRect(x: 0, y: 0, width: 720, height: 600), followingEnd: false)
        }
        XCTAssertEqual(document.measurementCount, before)
        document.updateViewport(NSRect(x: 0, y: max(0, document.frame.height - 600), width: 720, height: 600), followingEnd: true)
        let atEnd = document.measurementCount
        items[0].text += "\n\nAn offscreen change."
        document.update(items, omittedCount: 0)
        XCTAssertEqual(document.measurementCount, atEnd)
        XCTAssertEqual(first.string, originalText, "Detached cached rows should defer rich-text work until mounted")
        document.updateViewport(NSRect(x: 0, y: 0, width: 720, height: 600), followingEnd: false)
        XCTAssertTrue(descendants(document).compactMap { $0 as? AgentRichTextView }
            .contains { $0.string.contains("An offscreen change.") })
    }

    func testDisclosureStateSurvivesRowEviction() throws {
        var items = messages(500)
        items[0] = AgentChatItem(id: "long-user", kind: .user, text: String(repeating: "A line of user context.\n", count: 50))
        let document = makeDocument(items)
        let original = try XCTUnwrap(document.subviews.compactMap { $0 as? AgentMessageRow }
            .first { descendants($0).compactMap { $0 as? NSTextView }.contains { $0.string.contains("user context") } })
        let showMore = try XCTUnwrap(descendants(original).compactMap { $0 as? PillButton }.first { $0.title == "Show more" })
        showMore.onPress?()
        XCTAssertTrue(original.captureState().expanded)
        for index in 1...20 {
            let y = max(0, document.frame.height - 600) * CGFloat(index) / 20
            document.updateViewport(NSRect(x: 0, y: y, width: 720, height: 600), followingEnd: false)
        }
        XCTAssertNil(original.superview)
        document.updateViewport(NSRect(x: 0, y: 0, width: 720, height: 600), followingEnd: false)
        let restored = try XCTUnwrap(document.subviews.compactMap { $0 as? AgentMessageRow }
            .first { descendants($0).compactMap { $0 as? NSTextView }.contains { $0.string.contains("user context") } })
        XCTAssertFalse(restored === original, "The old row should be evicted, rather than retained forever")
        XCTAssertTrue(restored.captureState().expanded)
    }

    func testCollapsedCompletedWorkDoesNotConstructItsHistory() {
        let row = AgentCompletedWorkRow(frame: .zero)
        row.update(messages(1_000))
        XCTAssertEqual(row.preferredHeight(for: 700), 24)
        XCTAssertTrue(descendants(row).compactMap { $0 as? AgentMessageRow }.isEmpty)
    }

    func testEvictedNativeRowIsActuallyReleased() {
        var document: AgentTranscriptDocument?
        weak var discarded: AgentTimelineRow?
        autoreleasepool {
            let current = makeDocument(messages(1_000))
            document = current
            discarded = current.subviews.compactMap { $0 as? AgentTimelineRow }.first
            XCTAssertNotNil(discarded)
            for index in 1...20 {
                current.updateViewport(NSRect(x: 0, y: max(0, current.frame.height - 600) * CGFloat(index) / 20,
                                              width: 720, height: 600), followingEnd: false)
            }
        }
        XCTAssertNil(discarded, "Eviction must release native views and their TextKit storage, not just hide them")
        XCTAssertLessThan(document?.retainedRowCount ?? .max, 90)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
