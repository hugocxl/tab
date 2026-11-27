import XCTest
import TabProtocol
@testable import TabServer

final class NativeAgentActivityTests: XCTestCase {
    func testNativeChatSharesCLIActivityAndUnreadLifecycle() {
        let activity = Activity()
        var chat = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex,
                                     status: .working, items: [.init(kind: .user, text: "Fix the sidebar")])
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().agents.first?.provider, .codex)
        XCTAssertEqual(activity.snapshot().agents.first?.title, "Fix the sidebar")
        XCTAssertEqual(activity.snapshot().agents.first?.state, .working)
        chat.status = .waiting
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().events.first?.kind, .attention)
        chat.status = .working
        activity.updateChat(chat)
        chat.status = .idle
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().events.count, 1)
        XCTAssertEqual(activity.snapshot().events.first?.kind, .completed)
        activity.acknowledge(activity.snapshot().events.map(\.id))
        XCTAssertTrue(activity.snapshot().events.isEmpty)
        chat.status = .closed
        activity.updateChat(chat)
        XCTAssertTrue(activity.snapshot().agents.isEmpty)
    }

    func testBackgroundAgentsKeepTheChatWorkingAndItFinishesOnceAfterTheirAnswer() {
        let activity = Activity(settleDelay: 0.2)
        var chat = claudeChat(status: .working)
        activity.updateChat(chat)
        let since = activity.snapshot().agents.first?.workingSince
        XCTAssertNotNil(since)
        // The turn ends with two agents still running in the background.
        chat.subagents = [agent("a"), agent("b")]
        chat.status = .idle
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().agents.first?.state, .working)
        XCTAssertEqual(activity.snapshot().agents.first?.workingSince, since)
        XCTAssertTrue(activity.snapshot().events.isEmpty, "the turn's end is not the conversation's")
        // Both finish; Claude answers them in a turn it starts itself.
        chat.subagents = [agent("a", .completed), agent("b", .completed)]
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().agents.first?.state, .working)
        chat.status = .working
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().agents.first?.workingSince, since, "one job, one elapsed time")
        chat.status = .idle
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().agents.first?.state, .idle)
        XCTAssertEqual(activity.snapshot().events.map(\.kind), [.completed])
        // The settle timer that started before the answer changes nothing.
        let revision = activity.currentRevision
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(activity.currentRevision, revision)
        XCTAssertEqual(activity.snapshot().events.count, 1)
    }

    func testFinishedBackgroundAgentsSettleIntoOneCompletionWithoutAnAnswer() {
        let activity = Activity(settleDelay: 0.1)
        var chat = claudeChat(status: .working)
        activity.updateChat(chat)
        chat.subagents = [agent("a")]
        chat.status = .idle
        activity.updateChat(chat)
        chat.subagents = [agent("a", .completed)]
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().agents.first?.state, .working)
        let settled = expectation(description: "settled")
        activity.onChange = { _ in settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(activity.snapshot().agents.first?.state, .idle)
        XCTAssertEqual(activity.snapshot().events.map(\.kind), [.completed])
    }

    func testStoppedWorkIsNotReportedAsFinished() {
        let activity = Activity(settleDelay: 0.05)
        var chat = claudeChat(status: .working)
        activity.updateChat(chat)
        // Stopping the provider while only background agents run clears them.
        chat.subagents = [agent("a")]
        chat.status = .idle
        activity.updateChat(chat)
        chat.subagents = nil
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().agents.first?.state, .idle)
        XCTAssertTrue(activity.snapshot().events.isEmpty)
        // An interrupted turn didn't finish either.
        chat.status = .working
        chat.turns = [AgentChatTurn(userItemID: "turn", startedAt: Date())]
        activity.updateChat(chat)
        chat.status = .idle
        chat.turns = [AgentChatTurn(userItemID: "turn", startedAt: Date(), completedAt: Date(), status: .idle, outcome: .interrupted)]
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().agents.first?.state, .idle)
        XCTAssertTrue(activity.snapshot().events.isEmpty)
    }

    func testFailedTurnIsAnErrorRatherThanAWait() {
        let activity = Activity()
        var chat = claudeChat(status: .working)
        activity.updateChat(chat)
        chat.status = .waiting
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().events.map(\.kind), [.attention])
        chat.status = .failed
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().agents.first?.state, .blocked, "older apps still see it needs you")
        XCTAssertEqual(activity.snapshot().agents.first?.condition, .failed)
        XCTAssertEqual(activity.snapshot().events.map(\.kind), [.failed])
    }

    func testUsageLimitAndPausedQueueHoldTheChatUp() {
        let activity = Activity()
        var chat = claudeChat(status: .working)
        chat.activity = AgentChatActivity(kind: .rateLimited, resumesAt: Date().addingTimeInterval(600))
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().agents.first?.state, .working)
        XCTAssertEqual(activity.snapshot().agents.first?.condition, .paused)
        chat.activity = nil
        chat.status = .idle
        chat.queuePaused = true
        chat.queuedPrompts = [AgentQueuedPrompt(prompt: AgentPrompt(text: "Next", model: nil, effort: nil, provider: .claude,
                                                                    planMode: false))]
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().agents.first?.state, .idle)
        XCTAssertEqual(activity.snapshot().agents.first?.condition, .paused)
    }

    func testBackgroundShellsMarkAnIdleChatWithoutKeepingItWorking() {
        let activity = Activity(settleDelay: 0.05)
        var chat = claudeChat(status: .working)
        activity.updateChat(chat)
        chat.subagents = [AgentSubagent(id: "server", description: "npm run dev", agentType: "Shell", background: true)]
        chat.status = .idle
        activity.updateChat(chat)
        XCTAssertEqual(activity.snapshot().agents.first?.state, .idle)
        XCTAssertEqual(activity.snapshot().agents.first?.condition, .background)
        XCTAssertEqual(activity.snapshot().events.map(\.kind), [.completed])
    }

    func testConditionAndFailedEventsDecodeOnOlderAndNewerBuilds() throws {
        let agent = AgentActivity(session: SessionId(), project: ProjectId(), provider: .claude, state: .idle,
                                  condition: AgentCondition(rawValue: "sleeping"))
        let decoded = try JSONDecoder().decode(AgentActivity.self, from: JSONEncoder().encode(agent))
        XCTAssertEqual(decoded.condition?.rawValue, "sleeping", "a newer build's condition survives")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(agent)) as? [String: Any])
        object.removeValue(forKey: "condition")
        let older = try JSONDecoder().decode(AgentActivity.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(older.condition)
        let event = AgentEvent(id: 1, session: SessionId(), project: ProjectId(), provider: .claude, timestamp: 0, kind: .failed)
        XCTAssertEqual(try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(event)).kind, .failed)
    }

    func testRunningSubtasksReachTheSidebarWithoutProgressChurn() throws {
        let activity = Activity()
        var chat = claudeChat(status: .working)
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        var shell = AgentSubagent(id: "s", description: "Build the Debug app", agentType: "Shell", background: true, startedAt: started)
        chat.subagents = [shell, agent("a"), agent("done", .completed)]
        activity.updateChat(chat)
        let subtasks = try XCTUnwrap(activity.snapshot().agents.first?.subtasks)
        XCTAssertEqual(subtasks.map(\.id), ["s", "a"], "finished agents leave the list")
        XCTAssertEqual(subtasks.first, AgentSubtask(id: "s", title: "Build the Debug app", shell: true, startedAt: 1_800_000_000_000))
        // Progress inside a running agent doesn't change what the sidebar lists.
        let revision = activity.currentRevision
        shell.activity = "Linking"
        shell.toolUses = 3
        chat.subagents?[0] = shell
        activity.updateChat(chat)
        XCTAssertEqual(activity.currentRevision, revision)
        chat.subagents = []
        activity.updateChat(chat)
        XCTAssertNil(activity.snapshot().agents.first?.subtasks)
    }

    func testActivityFromAnOlderServerDecodesWithoutSubtasks() throws {
        let current = AgentActivity(session: SessionId(), project: ProjectId(), provider: .claude, state: .working,
                                    subtasks: [AgentSubtask(id: "x", title: "Build")])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        object["subtasks"] = nil
        let decoded = try JSONDecoder().decode(AgentActivity.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.subtasks)
        let task = try JSONDecoder().decode(AgentSubtask.self, from: Data(#"{"id":"x","future":1}"#.utf8))
        XCTAssertEqual(task, AgentSubtask(id: "x", title: ""))
    }

    private func claudeChat(status: AgentChatStatus) -> AgentChatSnapshot {
        AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude, status: status,
                          items: [.init(kind: .user, text: "Audit the app")])
    }

    private func agent(_ id: String, _ status: AgentSubagent.Status = .running) -> AgentSubagent {
        AgentSubagent(id: id, description: "Research", agentType: "Explore", background: true, status: status)
    }
}
