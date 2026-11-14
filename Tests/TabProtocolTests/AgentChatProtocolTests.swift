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

    func testClaudeSlashCommandsCrossTheWireAndOlderSnapshotsStillDecode() throws {
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude)
        snapshot.commands = ["compact", "review"]
        let encoded = try WireJSON.encode(snapshot)
        XCTAssertEqual(try WireJSON.decode(AgentChatSnapshot.self, from: encoded).commands, ["compact", "review"])
        XCTAssertEqual(try WireJSON.decode(AgentChatSnapshot.self, from: encoded), snapshot)
        snapshot.commands = nil
        let older = try WireJSON.encode(snapshot)
        XCTAssertFalse(String(decoding: older, as: UTF8.self).contains("commands"))
        XCTAssertNil(try WireJSON.decode(AgentChatSnapshot.self, from: older).commands)
    }

    func testConversationRequestsRoundTripAndAnOlderPeerSeesAnUnknownRequest() throws {
        let session = SessionId()
        let steps = AgentSubagentSteps(toolUseID: "toolu_1", items: [AgentChatItem(id: "s", kind: .assistant, text: "DONE")])
        let messages: [Message] = [
            .request(RequestId(4), .agentConversation(.subagentSteps(session: session, toolUseID: "toolu_1"))),
            .reply(RequestId(4), .agentConversation(.subagentSteps(steps))),
        ]
        for message in messages {
            try message.validate()
            XCTAssertEqual(try WireJSON.decode(Message.self, from: WireJSON.encode(message)), message)
        }
        // A request body this build can't read becomes `unknown`, which servers answer `unsupported`.
        let future = #"{"type":"request","id":5,"body":{"type":"agentConversation","request":{"futureRequest":{"session":"\#(session)"}}}}"#
        guard case .request(_, .unknown(let type)) = try WireJSON.decode(Message.self, from: Data(future.utf8)) else {
            return XCTFail("An unreadable conversation request must decode as unknown")
        }
        XCTAssertEqual(type, "agentConversation")
        XCTAssertThrowsError(try AgentConversationRequest.subagentSteps(session: session, toolUseID: "").validate())
    }

    func testIncrementalReadRoundTripsAndAppliesOnlyToItsBase() throws {
        let session = SessionId(), project = ProjectId()
        var base = AgentChatSnapshot(session: session, project: project, provider: .claude, status: .working, revision: 5,
                                     items: [.init(id: "a", kind: .user, text: "A"), .init(id: "b", kind: .assistant, text: "B")])
        base.turns = [AgentChatTurn(userItemID: "a", startedAt: Date(timeIntervalSince1970: 1))]
        var now = base
        now.revision = 7
        now.items = [.init(id: "b", kind: .assistant, text: "B, more"), .init(id: "c", kind: .tool, text: "Read")]
        // Reordered: the server sends every ID in its current order.
        let delta = AgentChatDelta(snapshot: now, since: 5, itemIDs: ["b", "a", "c"])
        let messages: [Message] = [
            .request(RequestId(2), .agentConversation(.readSince(session: session, revision: 5))),
            .reply(RequestId(2), .agentConversation(.delta(delta))),
        ]
        for message in messages {
            try message.validate()
            XCTAssertEqual(try WireJSON.decode(Message.self, from: WireJSON.encode(message)), message)
        }
        let applied = try XCTUnwrap(delta.applied(to: base))
        XCTAssertEqual(applied.items.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(applied.items.map(\.text), ["B, more", "A", "Read"])
        XCTAssertEqual(applied.revision, 7)
        var stale = base
        stale.revision = 4
        XCTAssertNil(delta.applied(to: stale), "A delta applies only to the revision it was read against")
        let unknown = AgentChatDelta(snapshot: now, since: 5, itemIDs: ["a", "z"])
        XCTAssertNil(unknown.applied(to: base), "An ID without an item means a full read")
    }

    func testFinishedSubagentFieldsAreOptionalOnTheWire() throws {
        var agent = AgentSubagent(id: "a", toolUseID: "t", description: "Audit", status: .failed,
                                  startedAt: Date(timeIntervalSince1970: 10), finishedAt: Date(timeIntervalSince1970: 22), steps: 3)
        XCTAssertEqual(try WireJSON.decode(AgentSubagent.self, from: WireJSON.encode(agent)), agent)
        agent.finishedAt = nil; agent.steps = nil
        let older = String(decoding: try WireJSON.encode(agent), as: UTF8.self)
        XCTAssertFalse(older.contains("finishedAt"))
        XCTAssertFalse(older.contains("steps"))
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

    func testApprovalScopeAndReasonAreOptionalOnTheWire() throws {
        let session = SessionId()
        let always = AgentChatRequest.approve(session: session, request: "bash", allow: true, always: true)
        let denied = AgentChatRequest.approve(session: session, request: "bash", allow: false, reason: "Not now")
        for request in [always, denied] {
            let encoded = try WireJSON.encode(request)
            XCTAssertEqual(try WireJSON.decode(AgentChatRequest.self, from: encoded), request)
            try request.validate()
        }
        // What an older app sends, and what an older server sees, is the plain answer.
        let plain = try WireJSON.encode(AgentChatRequest.approve(session: session, request: "bash", allow: true))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("always"))
        XCTAssertThrowsError(try AgentChatRequest.approve(session: session, request: "bash", allow: false, always: true).validate())
        XCTAssertThrowsError(try AgentChatRequest.approve(session: session, request: "bash", allow: true, reason: "Why").validate())
        XCTAssertFalse(AgentApprovalScope.canAlwaysAllow("AskUserQuestion"))
        XCTAssertFalse(AgentApprovalScope.canAlwaysAllow("ExitPlanMode"))
        XCTAssertTrue(AgentApprovalScope.canAlwaysAllow("Bash"))
    }
}
