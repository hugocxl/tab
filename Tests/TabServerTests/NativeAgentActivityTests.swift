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
}
