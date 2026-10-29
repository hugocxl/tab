import XCTest
@testable import TabProtocol

final class MessageTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let data = try WireJSON.encode(value)
            let decoded = try WireJSON.decode(T.self, from: data)
            XCTAssertEqual(decoded, value, String(decoding: data, as: UTF8.self), file: file, line: line)
            // A plain JSONDecoder reads it too.
            XCTAssertEqual(try JSONDecoder().decode(T.self, from: data), value, file: file, line: line)
        } catch {
            XCTFail("\(value): \(error)", file: file, line: line)
        }
    }

    private func types<T: Encodable>(_ values: [T]) throws -> Set<String> {
        Set(try values.map { value in
            let object = try JSONSerialization.jsonObject(with: try WireJSON.encode(value)) as? [String: Any]
            return object?["type"] as? String ?? ""
        })
    }

    func testEveryRequestRoundTrips() throws {
        for (index, body) in Samples.requests.enumerated() {
            roundTrip(Message.request(RequestId(UInt32(index)), body))
        }
        XCTAssertEqual(try types(Samples.requests).count, 45, "add a sample for every RequestBody case")
    }

    func testEveryReplyRoundTrips() throws {
        for (index, body) in Samples.replies.enumerated() {
            roundTrip(Message.reply(RequestId(UInt32(index)), body))
        }
        XCTAssertEqual(try types(Samples.replies).count, 42, "add a sample for every ReplyBody case")
    }

    func testEveryEventRoundTrips() throws {
        for body in Samples.events { roundTrip(Message.event(body)) }
        XCTAssertEqual(try types(Samples.events).count, 9, "add a sample for every EventBody case")
    }

    func testEverySessionMessageRoundTrips() throws {
        for message in Samples.sessionMessages { roundTrip(message) }
        XCTAssertEqual(try types(Samples.sessionMessages).count, 11, "add a sample for every SessionMessage case")
    }

    func testEveryGitActionAndReplyRoundTrips() throws {
        for action in Samples.gitActions {
            roundTrip(Message.request(RequestId(1), .git(GitRequest(project: Samples.project, action: action))))
        }
        for reply in Samples.gitReplies { roundTrip(Message.reply(RequestId(1), .git(reply))) }
        XCTAssertEqual(try types(Samples.gitActions).count, 40, "add a sample for every GitAction case")
        XCTAssertEqual(try types(Samples.gitReplies).count, 21, "add a sample for every GitReply case")
    }

    func testEveryFilesActionAndReplyRoundTrips() throws {
        for action in Samples.filesActions {
            roundTrip(Message.request(RequestId(1), .files(FilesRequest(project: Samples.project, action: action))))
        }
        for reply in Samples.filesReplies { roundTrip(Message.reply(RequestId(1), .files(reply))) }
        XCTAssertEqual(try types(Samples.filesActions).count, 14, "add a sample for every FilesAction case")
        XCTAssertEqual(try types(Samples.filesReplies).count, 9, "add a sample for every FilesReply case")
    }

    func testWireShapeUsesTypeDiscriminator() throws {
        let data = try WireJSON.encode(Message.request(RequestId(3), .attach(session: Samples.session,
                                                                            size: Size(cols: 80, rows: 24))))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "request")
        XCTAssertEqual(object["id"] as? Int, 3)
        let body = try XCTUnwrap(object["body"] as? [String: Any])
        XCTAssertEqual(body["type"] as? String, "attach")
        XCTAssertEqual(body["session"] as? String, "03000000-0000-4000-8000-000000000003")
    }

    // MARK: Tolerance

    func testUnknownFieldsAreIgnored() throws {
        let json = """
        {"type":"request","id":4,"addedLater":[1,2],"body":{"type":"attach","size":{"cols":80,"rows":24,"dpi":2},
         "session":"03000000-0000-4000-8000-000000000003","priority":"high"}}
        """
        let message = try WireJSON.decode(Message.self, from: Data(json.utf8))
        XCTAssertEqual(message, .request(RequestId(4), .attach(session: Samples.session, size: Size(cols: 80, rows: 24))))
    }

    func testUnknownReplyAndEventTypesDecodeAsUnknown() throws {
        let reply = try WireJSON.decode(Message.self, from: Data(#"{"type":"reply","id":1,"body":{"type":"teleported","where":"mars"}}"#.utf8))
        XCTAssertEqual(reply, .reply(RequestId(1), .unknown("teleported")))
        let event = try WireJSON.decode(Message.self, from: Data(#"{"type":"event","body":{"type":"solarFlare"}}"#.utf8))
        XCTAssertEqual(event, .event(.unknown("solarFlare")))
        let message = try WireJSON.decode(Message.self, from: Data(#"{"type":"broadcast"}"#.utf8))
        XCTAssertEqual(message, .unknown("broadcast"))
    }

    func testRequestWithUnreadableBodyKeepsItsIdForTheErrorReply() throws {
        let json = #"{"type":"request","id":8,"body":{"type":"git","request":{"project":"03000000-0000-4000-8000-000000000003","action":{"type":"rebaseInteractive"}}}}"#
        let message = try WireJSON.decode(Message.self, from: Data(json.utf8))
        XCTAssertEqual(message, .request(RequestId(8), .unknown("git")))
    }

    func testMissingFieldsTakeEmptyDefaults() throws {
        let stop = try WireJSON.decode(RequestBody.self, from: Data(#"{"type":"stopServer"}"#.utf8))
        XCTAssertEqual(stop, .stopServer(force: false))
        let summary = try WireJSON.decode(GitSummary.self, from: Data(#"{"branch":"main"}"#.utf8))
        XCTAssertEqual(summary, GitSummary(branch: "main"))
        let state = try WireJSON.decode(RemoteAccessState.self, from: Data(#"{"settings":{"port":7419},"status":{"type":"listening"}}"#.utf8))
        XCTAssertEqual(state, RemoteAccessState(revision: 0, settings: RemoteAccessSettings(enabled: false, port: 7419),
                                                status: .listening))
        let nested = try WireJSON.decode(Message.self, from: Data(#"{"type":"reply","id":2,"body":{"type":"exec","result":{"exitCode":3}}}"#.utf8))
        XCTAssertEqual(nested, .reply(RequestId(2), .exec(ExecResult(exitCode: 3))))
    }

    func testMissingRequiredIdentifierFails() {
        XCTAssertThrowsError(try WireJSON.decode(RequestBody.self, from: Data(#"{"type":"endSession"}"#.utf8)))
    }

    func testOpenEnumsKeepValuesFromNewerBuilds() throws {
        let reply = try WireJSON.decode(ErrorReply.self, from: Data(#"{"code":"quotaExceeded","message":"m"}"#.utf8))
        XCTAssertEqual(reply.code, .unknown("quotaExceeded"))
        XCTAssertFalse(reply.code.isKnown)
        XCTAssertEqual(String(decoding: try WireJSON.encode(reply), as: UTF8.self),
                       #"{"code":"quotaExceeded","message":"m"}"#)
        let agent = try WireJSON.decode(AgentActivity.self, from: Data("""
            {"session":"03000000-0000-4000-8000-000000000003","project":"01000000-0000-4000-8000-000000000001",
             "provider":"newAgent","state":"thinking"}
            """.utf8))
        XCTAssertEqual(agent.provider, .unknown("newAgent"))
        XCTAssertEqual(agent.state, .unknown)
    }

    func testAgentProviderRawValuesAreStable() {
        XCTAssertEqual(AgentProvider.knownCases.map(\.rawValue), [
            "claude", "codex", "opencode", "cursor", "copilot", "droid", "pi", "grok", "kiro", "xal", "antigravity", "omp",
        ])
        for provider in AgentProvider.knownCases {
            XCTAssertEqual(AgentProvider(rawValue: provider.rawValue), provider)
        }
    }

    func testIdsEncodeAsLowercaseUUIDStrings() throws {
        XCTAssertEqual(String(decoding: try WireJSON.encode([Samples.project]), as: UTF8.self),
                       #"["01000000-0000-4000-8000-000000000001"]"#)
        XCTAssertEqual(ProjectId(string: "01000000-0000-4000-8000-000000000001"), Samples.project)
        XCTAssertNil(SessionId(string: "nope"))
    }

    func testProtocolVersionNegotiation() {
        XCTAssertEqual(ProtocolVersion.negotiate([.v1, ProtocolVersion(9)]), .v1)
        XCTAssertNil(ProtocolVersion.negotiate([ProtocolVersion(9)]))
    }

    func testFileChangesMergeTurnsIntoRescan() {
        var changes = FileChanges(paths: ["a"])
        changes.merge(FileChanges(paths: ["a", "b"]))
        XCTAssertEqual(changes.paths, ["a", "b"])
        changes.merge(FileChanges(paths: (0 ... Limits.maxFileChanges).map { ServerPath("f\($0)") }))
        XCTAssertTrue(changes.rescan)
        XCTAssertTrue(changes.paths.isEmpty)
    }

    func testDiffHunks() {
        let diff = GitDiff(rows: [GitDiffRow(kind: .hunk, text: "@@ 1"), GitDiffRow(kind: .context, text: " a"),
                                  GitDiffRow(kind: .hunk, text: "@@ 2"), GitDiffRow(kind: .addition, text: "+b")])
        XCTAssertEqual(diff.hunks.map(\.count), [2, 2])
    }
}
