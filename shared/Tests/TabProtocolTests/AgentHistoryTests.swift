import Foundation
import TabProtocol
import XCTest

final class AgentHistoryTests: XCTestCase {
    func testRequestsAndReplyRoundTrip() throws {
        let project = ProjectId()
        let entry = AgentHistoryEntry(provider: .codex, providerSession: "01a190d2-3c4e-7890-94e2-b9340531c38d",
                                      title: "Tighten the server header", updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let messages: [Message] = [
            .request(RequestId(1), .agentHistory(.init(project: project))),
            .request(RequestId(2), .importAgentHistory(.init(session: SessionId(), project: project, provider: .claude,
                                                             providerSession: "3de6746e-518a-4660-9c84-a6a4bd87917c"))),
            .reply(RequestId(1), .agentHistory(.init(entries: [entry], truncated: true))),
        ]
        for message in messages {
            try message.validate()
            XCTAssertEqual(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message)), message)
        }
    }

    /// Provider session IDs name files on the server.
    func testRejectsProviderSessionsThatAreNotPlainIdentifiers() {
        for id in ["", "../escape", "a/b", "id.jsonl", "id with space", String(repeating: "a", count: 129)] {
            let request = AgentHistoryImport(session: SessionId(), project: ProjectId(), provider: .claude, providerSession: id)
            XCTAssertThrowsError(try RequestBody.importAgentHistory(request).validate(), id)
        }
    }
}
