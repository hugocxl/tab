import TabProtocol
import XCTest
@testable import TabClient

final class AgentChatClientTests: XCTestCase {
    func testTypedAttachmentFetchPreservesMessageScopeAndPayload() async throws {
        let request = AgentAttachmentRequest(session: SessionId(), item: UUID().uuidString, attachment: "image")
        let payload = AgentAttachmentReply(attachment: .init(id: "image", name: "image.png", mimeType: "image/png", data: Data([0, 1, 2])))
        let server = try FakeServer { id, body, server in
            if case .agentAttachment(let received) = body {
                XCTAssertEqual(received, request)
                server.reply(id, .agentAttachment(payload))
            } else { FakeServer.standard(id, body, server) }
        }
        let client = try await server.connect()
        defer { client.close() }
        let reply = try await client.agentAttachment(request)
        XCTAssertEqual(reply, payload)
    }

    func testSetAccessCarriesExplicitModeAndReturnsAuthoritativeSnapshot() async throws {
        let session = SessionId()
        let snapshot = AgentChatSnapshot(session: session, project: ProjectId(), provider: .claude,
                                         accessMode: .standard, status: .waiting)
        let server = try FakeServer { id, body, server in
            if case .agentChat(.setAccess(let received, let mode)) = body {
                XCTAssertEqual(received, session)
                XCTAssertEqual(mode, .standard)
                server.reply(id, .agentChat(snapshot))
            } else { FakeServer.standard(id, body, server) }
        }
        let client = try await server.connect()
        defer { client.close() }
        let changed = try await client.agentChat(.setAccess(session: session, mode: .standard))
        XCTAssertEqual(changed, snapshot)
    }

    func testTypedSendPreservesProviderModelAndEffortSelection() async throws {
        let session = SessionId()
        let request = AgentChatRequest.send(session: session, text: "Selected", model: "gpt-6.1-sol",
                                             reasoningEffort: .xhigh, provider: .codex)
        let snapshot = AgentChatSnapshot(session: session, project: ProjectId(), provider: .codex,
                                         model: "gpt-6.1-sol", reasoningEffort: .xhigh, status: .working)
        let server = try FakeServer { id, body, server in
            if case .agentChat(let received) = body {
                XCTAssertEqual(received, request)
                server.reply(id, .agentChat(snapshot))
            } else { FakeServer.standard(id, body, server) }
        }
        let client = try await server.connect()
        defer { client.close() }
        let received = try await client.agentChat(request)
        XCTAssertEqual(received, snapshot)
    }

    func testTypedReadAndChangedEvent() async throws {
        let session = SessionId()
        let snapshot = AgentChatSnapshot(session: session, project: ProjectId(), provider: .claude, revision: 7)
        let server = try FakeServer { id, body, server in
            if case .agentChat(.read(let requested)) = body, requested == session {
                server.reply(id, .agentChat(snapshot))
                server.event(.agentChatChanged(session: session, revision: 8))
            } else { FakeServer.standard(id, body, server) }
        }
        let client = try await server.connect()
        defer { client.close() }
        let read = try await client.agentChat(.read(session: session))
        XCTAssertEqual(read, snapshot)
        var events = client.events.makeAsyncIterator()
        let changed = await events.next()
        XCTAssertEqual(changed, .agentChatChanged(session: session, revision: 8))
    }
}
