import XCTest
import TabCore
import TabProtocol
@testable import TabApp

/// `tab pane` names panes the way agents get them from `tab pane list` and
/// from what the user says: a wrong match closes or moves the wrong pane.
final class PaneSelectorTests: XCTestCase {
    private let agent = PaneSelector.Candidate(id: PaneId(), session: SessionId(), title: "Agent")
    private let server = PaneSelector.Candidate(id: PaneId(), session: SessionId(), title: "npm run dev")
    private let page = PaneSelector.Candidate(id: PaneId(), session: nil, title: "localhost:3000")

    private func selector(caller: PaneId?, focused: PaneId? = nil) -> PaneSelector {
        let (agent, server, page) = (agent.id, server.id, page.id)
        return PaneSelector(candidates: [self.agent, self.server, self.page], caller: caller, focused: focused) { pane, direction in
            switch (pane, direction) {
            case (agent, .right): server
            case (server, .left): agent
            case (server, .down): page
            case (page, .up): server
            default: nil
            }
        }
    }

    func testWordsAreRelativeToTheCallersPane() throws {
        let mine = selector(caller: agent.id, focused: page.id)
        XCTAssertEqual(try mine.resolve(nil), agent.id, "a missing pane is the caller's")
        XCTAssertEqual(try mine.resolve("self"), agent.id)
        XCTAssertEqual(try mine.resolve("Right"), server.id)
        XCTAssertEqual(try mine.resolve("focused"), page.id)
        XCTAssertThrowsError(try mine.resolve("left")) { error in
            XCTAssertEqual(error.localizedDescription, "no pane is left of yours")
        }
        // Outside a pane, directions start from the focused pane, and self means nothing.
        let outside = selector(caller: nil, focused: server.id)
        XCTAssertEqual(try outside.resolve("down"), page.id)
        XCTAssertThrowsError(try outside.resolve(nil))
        XCTAssertThrowsError(try selector(caller: nil).resolve("up"))
    }

    func testIDsSessionsNamesAndTitles() throws {
        let any = selector(caller: nil)
        XCTAssertEqual(try any.resolve(server.id.description), server.id)
        XCTAssertEqual(try any.resolve(server.id.description.uppercased()), server.id)
        XCTAssertEqual(try any.resolve(server.session?.description), server.id, "the terminal's session names its pane")
        XCTAssertEqual(try any.resolve(String(page.id.description.prefix(8))), page.id)
        XCTAssertEqual(try any.resolve(server.session.map(SessionName.of)), server.id)
        XCTAssertEqual(try any.resolve("NPM run dev"), server.id)
        XCTAssertThrowsError(try any.resolve(SessionId().description), "a session no pane shows")
        XCTAssertThrowsError(try any.resolve("the server"))
    }

    func testAmbiguousNamesAreRefused() {
        let twin = PaneSelector.Candidate(id: PaneId(), session: nil, title: "npm run dev")
        let both = PaneSelector(candidates: [server, twin], caller: nil, focused: nil) { _, _ in nil }
        XCTAssertThrowsError(try both.resolve("npm run dev")) { error in
            XCTAssertTrue(error.localizedDescription.contains("more than one pane"))
        }
        let sharedStart = String(server.id.description.prefix(4))
        let lookalike = PaneSelector.Candidate(id: PaneId(uuid: UUID(uuidString: sharedStart + String(page.id.description.dropFirst(4)))!),
                                               session: nil, title: "x")
        let similar = PaneSelector(candidates: [server, lookalike], caller: nil, focused: nil) { _, _ in nil }
        XCTAssertThrowsError(try similar.resolve(sharedStart))
    }

    func testPositionsReadAsPeopleSayThem() {
        XCTAssertEqual(PaneSelector.position(.unit), "whole")
        XCTAssertEqual(PaneSelector.position(UnitRect(x: 0, y: 0, width: 0.5, height: 1)), "left")
        XCTAssertEqual(PaneSelector.position(UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5)), "top right")
        XCTAssertEqual(PaneSelector.position(UnitRect(x: 0, y: 0.5, width: 1, height: 0.5)), "bottom")
        XCTAssertEqual(PaneSelector.position(UnitRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)), "center")
        XCTAssertEqual(PaneSelector.position(UnitRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)), "middle")
    }
}
