import TabProtocol
import XCTest

final class AgentChatProtocolTests: XCTestCase {
    func testAgentRequestsSnapshotsAndRevisionEventsRoundTrip() throws {
        let session = SessionId()
        let project = ProjectId()
        let requests: [AgentChatRequest] = [
            .create(session: session, project: project, provider: .claude), .read(session: session),
            .send(session: session, text: "Hello", model: "model"),
            .send(session: session, text: "Selected", model: "gpt-6.1-sol", reasoningEffort: .xhigh, provider: .codex),
            .setAccess(session: session, mode: .fullAccess),
            .approve(session: session, request: "permission", allow: false),
            .interrupt(session: session), .close(session: session)
        ]
        let snapshot = AgentChatSnapshot(session: session, project: project, provider: .codex,
                                         providerSession: "resume", reasoningEffort: .high, status: .waiting, revision: 12,
                                         items: [AgentChatItem(id: "permission", kind: .approval,
                                                              text: "Run command?", isComplete: false)])
        let messages = requests.map { Message.request(RequestId(1), .agentChat($0)) } + [
            .reply(RequestId(1), .agentChat(snapshot)),
            .event(.agentChatChanged(session: session, revision: 12))
        ]
        for message in messages {
            let encoded = try WireJSON.encode(message)
            XCTAssertEqual(try WireJSON.decode(Message.self, from: encoded), message)
            try message.validate()
        }
    }

    func testPromptAndModelLimits() throws {
        let session = SessionId()
        XCTAssertThrowsError(try AgentChatRequest.send(session: session, text: " ", model: nil).validate())
        XCTAssertThrowsError(try AgentChatRequest.send(session: session, text: String(repeating: "x", count: 65537),
                                                       model: nil).validate())
        XCTAssertThrowsError(try AgentChatRequest.send(session: session, text: "hello", model: "bad\0model").validate())
        XCTAssertThrowsError(try AgentChatRequest.approve(session: session, request: "", allow: true).validate())
    }

    func testModelEffortCapabilitiesMatchT3ProfilesWithoutInventingCustomCapabilities() throws {
        for model in ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5", "claude-haiku-5-5"] {
            XCTAssertEqual(AgentReasoningEffort.supported(provider: .claude, model: model), AgentReasoningEffort.allCases)
        }
        XCTAssertEqual(AgentReasoningEffort.supported(provider: .claude, model: nil), [.low, .medium, .high])
        XCTAssertEqual(AgentReasoningEffort.supported(provider: .claude, model: "custom"), [.low, .medium, .high])
        XCTAssertEqual(AgentReasoningEffort.supported(provider: .claude, model: "claude-haiku-4-5"), [])
        XCTAssertEqual(AgentReasoningEffort.supported(provider: .claude, model: "claude-opus-4-6"), [.low, .medium, .high, .max])
        XCTAssertEqual(AgentReasoningEffort.supported(provider: .codex, model: "gpt-6.1-sol"), [.low, .medium, .high, .xhigh])
        XCTAssertEqual(AgentReasoningEffort.xhigh.title, "Extra high")
        XCTAssertThrowsError(try AgentChatRequest.send(session: SessionId(), text: "hello", model: nil,
                                                       reasoningEffort: .max, provider: .codex).validate())
    }

    func testLegacySnapshotAndSendWithoutAddedOptionalFieldsRemainDecodable() throws {
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude)
        let legacySnapshot = try WireJSON.encode(snapshot)
        XCTAssertFalse(String(decoding: legacySnapshot, as: UTF8.self).contains("reasoningEffort"))
        let decoded = try WireJSON.decode(AgentChatSnapshot.self, from: legacySnapshot)
        XCTAssertNil(decoded.reasoningEffort)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: legacySnapshot) as? [String: Any])
        legacy.removeValue(forKey: "accessMode")
        let restored = try WireJSON.decode(AgentChatSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.accessMode, .standard)
        XCTAssertNil(restored.turns)
        XCTAssertEqual(AgentAccessMode.standard.title, "Auto")
        XCTAssertEqual(AgentAccessMode.ask.title, "Ask every time")
        XCTAssertEqual(AgentAccessMode.fullAccess.title, "Full access")
        let legacySend = """
        {"send":{"session":"\(snapshot.session)","text":"legacy","model":"old-model"}}
        """
        XCTAssertEqual(try WireJSON.decode(AgentChatRequest.self, from: Data(legacySend.utf8)),
                       .send(session: snapshot.session, text: "legacy", model: "old-model"))
    }

    func testTurnsAndStructuredToolMetadataRoundTripAndMetadataCountsAgainstBudget() throws {
        let user = AgentChatItem(kind: .user, text: "run a command")
        let start = Date(timeIntervalSince1970: 1000)
        let tool = AgentChatItem(kind: .tool, text: "Bash", detail: "output", tool: .init(
            name: "Bash", category: .command, input: "{\"command\":\"pwd\"}", output: "output", status: .completed,
            startedAt: start, completedAt: start.addingTimeInterval(1)))
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude,
                                         turns: [.init(userItemID: user.id, startedAt: start,
                                                       completedAt: start.addingTimeInterval(2), status: .idle)],
                                         items: [user, tool])
        let decoded = try WireJSON.decode(AgentChatSnapshot.self, from: WireJSON.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        try decoded.validate()
        var oversized = snapshot
        oversized.items[1].tool?.output = String(repeating: "x", count: 512 * 1024)
        XCTAssertThrowsError(try oversized.validate(), "Hidden metadata must consume the transcript budget")
        var invalidTurn = snapshot
        invalidTurn.turns?[0].completedAt = start.addingTimeInterval(-1)
        XCTAssertThrowsError(try invalidTurn.validate())
    }
}
