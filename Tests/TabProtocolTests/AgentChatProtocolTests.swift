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
            .interrupt(session: session), .close(session: session),
            .fork(session: SessionId(), from: session), .fork(session: SessionId(), from: session, project: project),
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

    func testAForkWithoutAProjectReadsTheSameOnEitherSide() throws {
        let fork = SessionId(), source = SessionId()
        let encoded = try JSONEncoder().encode(AgentChatRequest.fork(session: fork, from: source))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("project"), "Older servers see what they know")
        let older = #"{"fork":{"session":"\#(fork)","from":"\#(source)"}}"#
        XCTAssertEqual(try JSONDecoder().decode(AgentChatRequest.self, from: Data(older.utf8)),
                       .fork(session: fork, from: source))
    }

    func testCheckpointWireMessagesAndInvalidIdentifiers() throws {
        let id = UUID().uuidString
        let session = SessionId()
        let messages: [Message] = [
            .request(RequestId(1), .agentCheckpoint(.init(session: session, checkpoint: id, path: "file\nname.swift"))),
            .reply(RequestId(1), .agentCheckpoint(.init(checkpoint: id,
                files: [.init(path: "file\nname.swift", additions: 1, deletions: 2)], totalFiles: 1,
                path: "file\nname.swift", diff: .init(rows: [.init(kind: .addition, text: "+new")], additions: 1))))
        ]
        for message in messages {
            try message.validate()
            XCTAssertEqual(try WireJSON.decode(Message.self, from: WireJSON.encode(message)), message)
        }
        XCTAssertThrowsError(try AgentCheckpointRequest(session: session, checkpoint: "../outside").validate())
        XCTAssertThrowsError(try AgentCheckpointRequest(session: session, checkpoint: id, offset: -1).validate())
    }

    func testTypedToolMetadataCountsTowardTranscriptLimit() throws {
        var tool = AgentToolActivity(presentation: .fileChange)
        let original = tool.transcriptByteCount
        tool.fileChangeDetails = .init(fileName: "file.txt", diff: String(repeating: "x", count: 1000), operations: [.init(operation: "update", path: "new.txt", oldPath: "old.txt")])
        tool.fileSearchDetails = .init(pattern: "query", results: [.init(fileName: "file.swift", line: 12, column: 3, preview: "match")])
        tool.searchPatterns = ["search query"]
        tool.webResults = [.init(title: "Title", url: "https://example.com", snippet: String(repeating: "y", count: 1000))]
        XCTAssertGreaterThan(tool.transcriptByteCount, original + 2000)
        XCTAssertEqual(try WireJSON.decode(AgentToolActivity.self, from: WireJSON.encode(tool)), tool)
    }

    func testPromptAndModelLimits() throws {
        let session = SessionId()
        XCTAssertThrowsError(try AgentChatRequest.send(session: session, text: " ", model: nil).validate())
        XCTAssertThrowsError(try AgentChatRequest.send(session: session, text: String(repeating: "x", count: 65537),
                                                       model: nil).validate())
        XCTAssertThrowsError(try AgentChatRequest.send(session: session, text: "hello", model: "bad\0model").validate())
        XCTAssertThrowsError(try AgentChatRequest.approve(session: session, request: "", allow: true).validate())
    }

    func testEffortValuesAreExtensibleAndRemainSingleValueStrings() throws {
        XCTAssertEqual(AgentReasoningEffort.xhigh.title, "Extra high")
        for provider in AgentChatProvider.allCases {
            for effort in [AgentReasoningEffort.max, .ultra, .init(rawValue: "future-effort")] {
                XCTAssertNoThrow(try AgentChatRequest.send(session: SessionId(), text: "hello", model: "future-model",
                                                         reasoningEffort: effort, provider: provider).validate())
                XCTAssertEqual(try WireJSON.decode(AgentReasoningEffort.self, from: WireJSON.encode(effort)), effort)
            }
        }
        XCTAssertEqual(String(decoding: try WireJSON.encode(AgentReasoningEffort.high), as: UTF8.self), "\"high\"")
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
        XCTAssertNil(restored.contextUsage)
        XCTAssertNil(restored.resolvedModel)
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

    func testContextUsageRoundTripsWithKnownAndUnknownCapacity() throws {
        for capacity in [nil, 200_000] as [Int?] {
            let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude,
                contextUsage: .init(usedTokens: 42_000, contextWindow: capacity), resolvedModel: "claude-sonnet-4-6")
            XCTAssertEqual(try WireJSON.decode(AgentChatSnapshot.self, from: WireJSON.encode(snapshot)), snapshot)
            try snapshot.validate()
        }
        var invalid = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex,
            contextUsage: .init(usedTokens: -1))
        XCTAssertThrowsError(try invalid.validate())
        invalid.contextUsage = .init(usedTokens: 0, contextWindow: 0)
        XCTAssertThrowsError(try invalid.validate())
    }
}
