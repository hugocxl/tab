import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentTableHitTestingTests: XCTestCase {
    func testCopyGutterRoutesThroughActualTranscriptRowsAndRespectsViewport() throws {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let document = AgentTranscriptDocument(frame: .zero)
        scroll.documentView = document
        document.update([AgentChatItem(id: "table", kind: .assistant,
            text: "| Name | Value |\n| --- | --- |\n| Alpha | Beta |")], omittedCount: 0)
        document.reflow(viewportWidth: 400)
        document.updateViewport(NSRect(x: 0, y: 0, width: 400, height: 240), followingEnd: false)
        let row = try XCTUnwrap(document.subviews.compactMap { $0 as? AgentMessageRow }.first)
        let response = try XCTUnwrap(row.subviews.compactMap { $0 as? AgentResponseView }.first)
        let table = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseTable }.first)
        let local = NSPoint(x: table.copy.bounds.maxX - 1, y: table.copy.bounds.midY)
        let point = table.copy.convert(local, to: document)
        XCTAssertGreaterThan(point.x, response.convert(response.bounds, to: document).maxX, "The copy gutter lies outside the response")
        XCTAssertLessThan(point.x, document.bounds.maxX)
        XCTAssertTrue(table.hitTest(table.copy.convert(local, to: table.superview)) === table.copy)
        XCTAssertTrue(response.hitTest(table.copy.convert(local, to: response.superview)) === table.copy)
        XCTAssertTrue(document.hitTest(document.convert(point, to: document.superview)) === table.copy)

        table.copy.isHidden = true
        XCTAssertNil(AgentTableCopyHitTesting.hitTest(document.convert(point, to: document.superview), in: document))
        table.copy.isHidden = false
        table.copy.isEnabled = false
        XCTAssertNil(AgentTableCopyHitTesting.hitTest(document.convert(point, to: document.superview), in: document))
        table.copy.isEnabled = true

        scroll.setFrameSize(NSSize(width: 400, height: max(1, point.y - 1)))
        scroll.tile()
        XCTAssertFalse(scroll.contentView.bounds.contains(scroll.contentView.convert(point, from: document)))
        XCTAssertNil(AgentTableCopyHitTesting.hitTest(document.convert(point, to: document.superview), in: document),
                     "A gutter control outside the scroll viewport cannot intercept a hit")
    }
}
