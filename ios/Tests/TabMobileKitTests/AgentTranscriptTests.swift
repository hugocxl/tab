import TabProtocol
import XCTest
@testable import TabMobileKit

final class AgentTranscriptTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func snapshot(_ items: [AgentChatItem], turns: [AgentChatTurn], status: AgentChatStatus = .idle) -> AgentChatSnapshot {
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude, status: status,
                                         revision: 1, items: items)
        snapshot.turns = turns
        return snapshot
    }

    func testFinishedTurnFoldsItsToolStepsIntoOneRow() {
        let user = AgentChatItem(id: "u", kind: .user, text: "fix it")
        let items = [user, AgentChatItem(id: "t1", kind: .tool, text: "Bash"),
                     AgentChatItem(id: "a", kind: .assistant, text: "Looking"),
                     AgentChatItem(id: "t2", kind: .tool, text: "Edit"),
                     AgentChatItem(id: "done", kind: .assistant, text: "Fixed")]
        let turn = AgentChatTurn(userItemID: "u", startedAt: start, completedAt: start.addingTimeInterval(72), status: .idle)
        let rows = AgentTranscript.rows(snapshot(items, turns: [turn]), expanded: [])
        XCTAssertEqual(rows.map(\.id), ["u", "work-u", "a", "done"])
        XCTAssertEqual(rows[1], .work(turn: "u", steps: 2, duration: 72, expanded: false))
    }

    func testExpandedTurnShowsItsStepsUnderTheFold() {
        let items = [AgentChatItem(id: "u", kind: .user, text: "go"), AgentChatItem(id: "t1", kind: .tool, text: "Bash")]
        let turn = AgentChatTurn(userItemID: "u", startedAt: start, completedAt: start.addingTimeInterval(5), status: .idle)
        let rows = AgentTranscript.rows(snapshot(items, turns: [turn]), expanded: ["u"])
        XCTAssertEqual(rows.map(\.id), ["u", "work-u", "t1"])
        XCTAssertEqual(rows[1], .work(turn: "u", steps: 1, duration: 5, expanded: true))
    }

    func testRunningTurnStaysOpenAndShowsWorking() {
        let items = [AgentChatItem(id: "u", kind: .user, text: "go"),
                     AgentChatItem(id: "t1", kind: .tool, text: "Bash", isComplete: false)]
        let turn = AgentChatTurn(userItemID: "u", startedAt: start)
        let rows = AgentTranscript.rows(snapshot(items, turns: [turn], status: .working), expanded: [])
        XCTAssertEqual(rows.map(\.id), ["u", "t1", "working"])
        XCTAssertEqual(rows.last, .working(since: start))
    }

    /// An answered approval keeps its id but needs a different cell; the
    /// pane reloads it instead of reconfiguring, which used to crash.
    func testAnsweredApprovalBecomesANoticeWithTheSameId() {
        let pending = AgentChatItem(id: "p", kind: .approval, text: "Bash", isComplete: false)
        var answered = pending
        answered.isComplete = true
        answered.text = "Approved"
        let before = AgentTranscript.rows(snapshot([pending], turns: []), expanded: [])
        let after = AgentTranscript.rows(snapshot([answered], turns: []), expanded: [])
        XCTAssertEqual(before.first?.id, after.first?.id)
        XCTAssertNotEqual(before.first?.kind, after.first?.kind)
    }

    func testErrorsAreNeverFolded() {
        var error = AgentChatItem(id: "e", kind: .tool, text: "Failed")
        error.workContext = AgentChatWorkContext(itemType: "error")
        let items = [AgentChatItem(id: "u", kind: .user, text: "go"), error]
        let turn = AgentChatTurn(userItemID: "u", startedAt: start, completedAt: start, status: .failed)
        let rows = AgentTranscript.rows(snapshot(items, turns: [turn]), expanded: [])
        XCTAssertEqual(rows, [.user(items[0]), .notice(error, isError: true)])
    }
}
