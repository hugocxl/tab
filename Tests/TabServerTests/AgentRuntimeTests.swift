import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabServer

final class AgentRuntimeTests: XCTestCase {
    func testCodexResumedAutoEffortFindsSelectedModelOnLaterCatalogPage() async throws {
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "later-page selection completed")
        recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"resumed"}}}'
        take
        emit '{"id":3,"result":{"config":{}}}'
        take
        emit '{"id":4,"result":{"data":[{"model":"first","isDefault":true}],"nextCursor":"next"}}'
        take
        emit '{"id":5,"result":{"data":[{"model":"later-page","defaultReasoningEffort":"ultra"}]}}'
        take
        emit '{"id":6,"result":{"turn":{"id":"turn"}}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"turn","status":"completed"}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder, resume: "resumed")
        defer { runtime.stop() }
        try await runtime.send(text: "Hello", model: "later-page")
        await fulfillment(of: [idle], timeout: 5)
        let sent = try fixture.messages()
        XCTAssertEqual((sent[5]["params"] as? [String: Any])?["cursor"] as? String, "next")
        XCTAssertEqual((sent[6]["params"] as? [String: Any])?["effort"] as? String, "ultra")
        XCTAssertEqual((sent[6]["params"] as? [String: Any])?["model"] as? String, "later-page")
    }

    func testDynamicFutureReasoningPassesThroughBothProviderRuntimes() async throws {
        for provider in AgentChatProvider.allCases {
            let recorder = AgentRuntimeRecorder()
            let body = provider == .claude ? """
            take
            emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
            take
            emit '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
            hold
            """ : """
            take
            emit '{"id":1,"result":{}}'
            take
            take
            emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
            take
            emit '{"id":3,"result":{"turn":{"id":"turn"}}}'
            emit '{"method":"turn/completed","params":{"turn":{"id":"turn","status":"completed"}}}'
            hold
            """
            let fixture = try AgentRuntimeFixture(body)
            defer { fixture.remove() }
            let idle = expectation(description: "\(provider) future effort")
            recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
            let runtime = fixture.runtime(provider, recorder: recorder)
            defer { runtime.stop() }
            try await runtime.send(text: "Hello", model: "future-model", reasoningEffort: .init(rawValue: "future-effort"))
            await fulfillment(of: [idle], timeout: 5)
            if provider == .claude {
                XCTAssertTrue(try fixture.launches()[0].contains("--effort\nfuture-effort\n"))
            } else {
                let sent = try fixture.messages()
                XCTAssertEqual((sent.last?["params"] as? [String: Any])?["effort"] as? String, "future-effort")
            }
        }
    }

    // Protocol replays are synthetic, derived from the T3 reference paths cited in the
    // provider implementations; no authentication, CLI install or billable request is used.
    func testClaudeStreamingApprovalToolResultAndNoDuplicateAnswer() async throws {
        let recorder = AgentRuntimeRecorder()
        let approval = expectation(description: "approval")
        let idle = expectation(description: "idle")
        recorder.observe = { event in
            if case .item(let item) = event, item.id == "permission-1", !item.isComplete { approval.fulfill() }
            if case .status(.idle) = event { idle.fulfill() }
        }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        emit '{"type":"system","subtype":"init","session_id":"claude-session","model":"test-model"}'
        emit '{"type":"stream_event","event":{"type":"message_start","message":{"id":"message-1","model":"test-model","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}}}}'
        emit '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello "}}}'
        printf '%s' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"'
        printf '\\303'
        printf '\\251'
        printf '%s\\n' '"}}}'
        emit '{"type":"assistant","message":{"id":"message-1","content":[{"type":"text","text":"Hello é"},{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"pwd"}}]}}'
        emit '{"type":"control_request","request_id":"permission-1","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"tool-1","input":{"command":"pwd"}}}'
        take
        emit '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"/project"}]}}'
        emit '{"type":"result","subtype":"success","is_error":false,"result":"Hello é","modelUsage":{"test-model":{"inputTokens":9000,"contextWindow":200000}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.claude, recorder: recorder, resume: "prior-session")
        defer { runtime.stop() }
        // Lazy: constructing a runtime must not start even a fake executable.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
        try await runtime.send(text: "Hi", model: "test-model")
        await fulfillment(of: [approval], timeout: 5)
        try await runtime.approve(request: "permission-1", allow: true)
        await fulfillment(of: [idle], timeout: 5)
        let state = recorder.transcript
        XCTAssertEqual(state["message-1"]?.text, "Hello é")
        XCTAssertEqual(state.values.filter { $0.kind == .assistant }.count, 1)
        XCTAssertEqual(state["tool-1"]?.detail, "/project")
        XCTAssertEqual(state["tool-1"]?.isComplete, true)
        XCTAssertEqual(state["permission-1"]?.text, "Approved")
        let sent = try fixture.messages()
        XCTAssertEqual((sent[0]["request"] as? [String: Any])?["subtype"] as? String, "initialize")
        XCTAssertEqual((sent[1]["message"] as? [String: Any])?["content"] as? String, "Hi")
        let response = sent[2]["response"] as? [String: Any]
        XCTAssertEqual(response?["request_id"] as? String, "permission-1")
        let decision = response?["response"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
        XCTAssertEqual(decision?["toolUseID"] as? String, "tool-1")
        XCTAssertEqual((decision?["updatedInput"] as? [String: Any])?["command"] as? String, "pwd")
        XCTAssertTrue(recorder.sessions.contains("claude-session"))
        XCTAssertEqual(recorder.contextUsage.last, .init(usedTokens: 130, contextWindow: 200_000))
        XCTAssertEqual(recorder.resolvedModels, ["test-model"])
    }

    func testCodexResumeNumericZeroApprovalAndEarlyNotifications() async throws {
        let recorder = AgentRuntimeRecorder()
        let waiting = expectation(description: "waiting")
        let idle = expectation(description: "idle")
        recorder.observe = { event in
            if case .status(.waiting) = event { waiting.fulfill() }
            if case .status(.idle) = event { idle.fulfill() }
        }
        let fixture = try AgentRuntimeFixture("""
        take
        dd if=/dev/zero bs=65536 count=4 >&2 2>/dev/null
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread-1"}}}'
        take
        emit '{"id":3,"result":{"config":{}}}'
        take
        emit '{"id":4,"result":{"data":[{"id":"test-model","model":"test-model","isDefault":true,"defaultReasoningEffort":"medium"}]}}'
        take
        emit '{"method":"turn/started","params":{"turn":{"id":"turn-1"}}}'
        emit '{"method":"thread/tokenUsage/updated","params":{"threadId":"thread-1","tokenUsage":{"last":{"totalTokens":1234},"total":{"totalTokens":999999},"modelContextWindow":258400}}}'
        emit '{"method":"thread/tokenUsage/updated","params":{"threadId":"child-thread","tokenUsage":{"last":{"totalTokens":9999},"modelContextWindow":1000000}}}'
        emit '{"method":"item/agentMessage/delta","params":{"itemId":"answer","delta":"Done"}}'
        emit '{"id":0,"method":"item/commandExecution/requestApproval","params":{"itemId":"command-1","command":"pwd","availableDecisions":["accept","decline"]}}'
        emit '{"id":5,"result":{"turn":{"id":"turn-1"}}}'
        take
        emit '{"method":"item/completed","params":{"item":{"id":"command-1","type":"commandExecution","command":"pwd","aggregatedOutput":"/project","exitCode":0}}}'
        emit '{"method":"item/completed","params":{"item":{"id":"answer","type":"agentMessage","text":"Done"}}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder, resume: "old-thread")
        defer { runtime.stop() }
        try await runtime.send(text: "Hello", model: "test-model")
        await fulfillment(of: [waiting], timeout: 5)
        try await runtime.approve(request: "0", allow: false)
        await fulfillment(of: [idle], timeout: 5)
        let sent = try fixture.messages()
        XCTAssertEqual(sent[0]["method"] as? String, "initialize")
        let clientInfo = (sent[0]["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
        XCTAssertEqual(clientInfo?["version"] as? String, Release.version)
        XCTAssertEqual(sent[1]["method"] as? String, "initialized")
        XCTAssertEqual(sent[2]["method"] as? String, "thread/resume")
        XCTAssertEqual((sent[2]["params"] as? [String: Any])?["threadId"] as? String, "old-thread")
        XCTAssertEqual(sent[3]["method"] as? String, "config/read")
        XCTAssertEqual(sent[4]["method"] as? String, "model/list")
        XCTAssertEqual(sent[5]["method"] as? String, "turn/start")
        XCTAssertEqual((sent[5]["params"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertEqual(sent[6]["id"] as? Int, 0)
        XCTAssertEqual((sent[6]["result"] as? [String: Any])?["decision"] as? String, "decline")
        XCTAssertEqual(recorder.transcript["answer"]?.text, "Done")
        XCTAssertEqual(recorder.transcript["command-1"]?.isComplete, true)
        XCTAssertEqual(recorder.transcript["0"]?.text, "Declined")
        XCTAssertEqual(recorder.sessions, ["thread-1"])
        XCTAssertEqual(recorder.contextUsage, [.init(usedTokens: 1234, contextWindow: 258_400)],
                       "Subagent thread notifications must not overwrite root context usage")
    }

    func testCodexInterruptWaitsForCompletionAndUsesTurnID() async throws {
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "interrupted")
        recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"turn"}}}'
        take
        emit '{"id":4,"result":{}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"turn","status":"interrupted"}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "hello", model: nil)
        XCTAssertFalse(recorder.statuses.contains(.idle))
        do {
            try await runtime.send(text: "concurrent", model: nil)
            XCTFail("Busy turn must not be submitted twice")
        } catch { XCTAssertTrue(error.localizedDescription.contains("current turn")) }
        try await runtime.interrupt()
        await fulfillment(of: [idle], timeout: 5)
        let message = try XCTUnwrap(fixture.messages().last)
        XCTAssertEqual(message["method"] as? String, "turn/interrupt")
        let params = message["params"] as? [String: Any]
        XCTAssertEqual(params?["threadId"] as? String, "thread")
        XCTAssertEqual(params?["turnId"] as? String, "turn")
    }

    func testClaudeInterruptCancelApprovalAndErrorResult() async throws {
        let recorder = AgentRuntimeRecorder()
        let waiting = expectation(description: "waiting")
        let failed = expectation(description: "error result")
        recorder.observe = { event in
            if case .status(.waiting) = event { waiting.fulfill() }
            if case .status(.failed) = event { failed.fulfill() }
        }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1"}}'
        take
        emit '{"type":"control_request","request_id":"cancel-me","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}'
        take
        emit '{"type":"control_cancel_request","request_id":"cancel-me"}'
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"2"}}'
        emit '{"type":"result","subtype":"success","is_error":true,"errors":["fixture failure"]}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "hello", model: nil)
        await fulfillment(of: [waiting], timeout: 5)
        try await runtime.interrupt()
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(recorder.transcript["cancel-me"]?.text, "Cancelled")
        XCTAssertEqual(recorder.failures, ["fixture failure"])
        let message = try XCTUnwrap(fixture.messages().last)
        XCTAssertEqual((message["request"] as? [String: Any])?["subtype"] as? String, "interrupt")
    }

    func testStartupTimeoutAndStopCancelPendingSend() async throws {
        for provider in AgentChatProvider.allCases {
            let recorder = AgentRuntimeRecorder()
            let fixture = try AgentRuntimeFixture("take\nhold")
            defer { fixture.remove() }
            let runtime = fixture.runtime(provider, recorder: recorder, timeout: 0.15)
            do {
                try await runtime.send(text: "never sent", model: nil)
                XCTFail("Handshake must time out")
            } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
            XCTAssertEqual(recorder.statuses.last, .failed)
            runtime.stop()
        }
        let fixture = try AgentRuntimeFixture("take\nhold")
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let working = expectation(description: "startup reserved")
        recorder.observe = { event in if case .status(.working) = event { working.fulfill() } }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        let send = Task { try await runtime.send(text: "never sent", model: nil) }
        await fulfillment(of: [working], timeout: 5)
        runtime.stop()
        do { try await send.value; XCTFail("Stop must cancel handshake") }
        catch { XCTAssertTrue(error.localizedDescription.contains("stopped")) }
    }

    func testExitReportsDrainedStderrAndMalformedJSONFails() async throws {
        for script in ["take\nprintf 'Sign in with codex login' >&2\nexit 7", "take\nemit 'not-json'\nhold"] {
            let fixture = try AgentRuntimeFixture(script)
            defer { fixture.remove() }
            let recorder = AgentRuntimeRecorder()
            let runtime = fixture.runtime(.codex, recorder: recorder)
            defer { runtime.stop() }
            do { try await runtime.send(text: "hello", model: nil); XCTFail("Expected startup failure") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains(script.contains("exit 7") ? "Sign in with codex login" : "Invalid Codex protocol"))
            }
            XCTAssertEqual(recorder.failures.count, 1)
        }
    }

    func testMissingExecutableIsActionableAndInheritedPATHPreserved() throws {
        XCTAssertThrowsError(try AgentProcess.resolve("codex", environment: ["PATH": "/missing-provider-directory"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("Install Codex"))
            XCTAssertTrue(error.localizedDescription.contains("PATH"))
        }
        let environment = AgentProcess.environment()
        XCTAssertTrue(environment["PATH"]?.contains("/.local/bin") == true)
        if let inherited = ProcessInfo.processInfo.environment["PATH"], !inherited.isEmpty {
            XCTAssertTrue(environment["PATH"]?.hasPrefix(inherited) == true)
        }
    }

    func testClaudeModelAndEffortChangesRestartSameRuntimeWithResumeAndNilReloadsDefaults() async throws {
        let fixture = try AgentRuntimeFixture(#"""
        take
        id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"request_id":"([^"]+)".*/\1/')
        emit "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\",\"response\":{}}}"
        take
        emit '{"type":"system","subtype":"init","session_id":"stable-session"}'
        emit '{"type":"assistant","message":{"id":"answer","content":[{"type":"text","text":"Done"}]}}'
        emit '{"type":"result","subtype":"success","is_error":false,"result":"Done"}'
        hold
        """#)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let runtime = fixture.runtime(.claude, recorder: recorder, resume: "original-session")
        defer { runtime.stop() }
        let choices: [(String?, AgentReasoningEffort?)] = [
            ("claude-opus-5-5", .low), ("claude-sonnet-5-5", .medium), (nil, nil)
        ]
        for (model, effort) in choices {
            let idle = expectation(description: "turn completed")
            recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
            try await runtime.send(text: "continue", model: model, reasoningEffort: effort)
            await fulfillment(of: [idle], timeout: 5)
        }
        let launches = try fixture.launches()
        XCTAssertEqual(launches.count, 3)
        guard launches.count == 3 else { return }
        XCTAssertTrue(launches[0].contains("--model\nclaude-opus-5-5\n"))
        XCTAssertTrue(launches[0].contains("--effort\nlow\n"))
        XCTAssertTrue(launches[0].contains("--resume\noriginal-session\n"))
        XCTAssertTrue(launches[1].contains("--model\nclaude-sonnet-5-5\n"))
        XCTAssertTrue(launches[1].contains("--effort\nmedium\n"))
        for launch in launches.dropFirst() { XCTAssertTrue(launch.contains("--resume\nstable-session\n")) }
        XCTAssertFalse(launches[2].contains("--effort"))
        XCTAssertFalse(launches[2].contains("--model"))
        let users = try fixture.messages().filter { $0["type"] as? String == "user" }
        XCTAssertEqual(users.count, 3)
        for user in users.dropFirst() { XCTAssertEqual(user["session_id"] as? String, "stable-session") }
        XCTAssertTrue(recorder.failures.isEmpty, "Retired process exit must not fail the replacement process")
    }

    func testCodexEffortReachesTurnStartAndNilResetsReadRealDefaultsWithoutLosingThread() async throws {
        let fixture = try AgentRuntimeFixture(#"""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"same-thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"one"}}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"one","status":"completed"}}}'
        take
        emit '{"id":4,"result":{"config":{"model":"provider-default","model_reasoning_effort":"medium"}}}'
        take
        emit '{"id":5,"result":{"data":[{"id":"provider-default","model":"provider-default","isDefault":true,"defaultReasoningEffort":"low"}]}}'
        take
        emit '{"id":6,"result":{"turn":{"id":"two"}}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"two","status":"completed"}}}'
        hold
        """#)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        let first = expectation(description: "first turn")
        recorder.observe = { event in if case .status(.idle) = event { first.fulfill() } }
        try await runtime.send(text: "first", model: "gpt-6.1-sol", reasoningEffort: .xhigh)
        await fulfillment(of: [first], timeout: 5)
        let second = expectation(description: "default turn")
        recorder.observe = { event in if case .status(.idle) = event { second.fulfill() } }
        try await runtime.send(text: "default", model: nil, reasoningEffort: nil)
        await fulfillment(of: [second], timeout: 5)
        let messages = try fixture.messages()
        let turns = messages.filter { $0["method"] as? String == "turn/start" }.compactMap { $0["params"] as? [String: Any] }
        XCTAssertEqual(turns.count, 2)
        guard turns.count == 2 else { return }
        XCTAssertEqual(turns[0]["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(turns[0]["effort"] as? String, "xhigh")
        XCTAssertEqual(turns[1]["model"] as? String, "provider-default")
        XCTAssertEqual(turns[1]["effort"] as? String, "medium")
        XCTAssertEqual(turns[0]["threadId"] as? String, turns[1]["threadId"] as? String)
        XCTAssertEqual(try fixture.launches().count, 1, "Codex selections apply per turn without discarding its thread")
    }

    func testMalformedEffortIsRejectedBeforeLaunchingProvider() async throws {
        let fixture = try AgentRuntimeFixture("take\nhold")
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        do {
            try await runtime.send(text: "not sent", model: nil, reasoningEffort: .init(rawValue: "bad\nvalue"))
            XCTFail("Malformed reasoning must not reach the provider")
        } catch { XCTAssertTrue(error.localizedDescription.contains("does not support")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
        XCTAssertTrue(recorder.statuses.isEmpty)
    }

    func testClaudePerBlockAssistantFramesRetainAllStreamedText() {
        let recorder = AgentRuntimeRecorder()
        let normalizer = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        normalizer.beginTurn()
        normalizer.receive(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "message"]]])
        normalizer.receive(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Before"]]])
        normalizer.receive(["type": "assistant", "message": ["id": "message", "content": [["type": "text", "text": "Before"]]]])
        normalizer.receive(["type": "assistant", "message": ["id": "message", "content": [["type": "tool_use", "id": "tool", "name": "Read", "input": [:]]]]])
        XCTAssertEqual(recorder.transcript["message"]?.text, "Before")
        normalizer.receive(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": " after"]]])
        normalizer.receive(["type": "assistant", "message": ["id": "message", "content": [["type": "text", "text": " after"]]]])
        normalizer.receive(["type": "result", "result": "Before after"])
        XCTAssertEqual(recorder.transcript["message"]?.text, "Before after")
        XCTAssertEqual(recorder.transcript["message"]?.isComplete, true)
        XCTAssertEqual(recorder.transcript["tool"]?.isComplete, true)
    }

    func testUnsupportedCodexInteractionReceivesRPCErrorUsingStringID() async throws {
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "idle after rejecting unsupported interaction")
        recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"turn"}}}'
        emit '{"id":"question-1","method":"item/tool/requestUserInput","params":{"itemId":"not-the-rpc-id","questions":[]}}'
        take
        emit '{"method":"turn/completed","params":{"turn":{"id":"turn","status":"completed"}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "hello", model: nil)
        await fulfillment(of: [idle], timeout: 5)
        let response = try XCTUnwrap(fixture.messages().last)
        XCTAssertEqual(response["id"] as? String, "question-1")
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertTrue(recorder.transcript.values.contains { $0.kind == .notice })
    }

    func testLargePromptCannotBlockStopWhenChildStopsReading() async throws {
        for provider in AgentChatProvider.allCases {
            let handshake = provider == .claude ? """
            take
            emit '{"type":"control_response","response":{"subtype":"success","request_id":"1"}}'
            """ : """
            take
            emit '{"id":1,"result":{}}'
            take
            take
            emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
            """
            // Replacing the shell avoids descendants inheriting stdout and keeping
            // transport reader threads alive after the fake child is terminated.
            let fixture = try AgentRuntimeFixture(handshake + "\nexec /bin/sleep 30")
            defer { fixture.remove() }
            let recorder = AgentRuntimeRecorder()
            let closed = expectation(description: "stop is not trapped behind a full pipe: \(provider)")
            recorder.observe = { event in if case .status(.closed) = event { closed.fulfill() } }
            let runtime = fixture.runtime(provider, recorder: recorder)
            let started = Date()
            let submission = Task { try await runtime.send(text: String(repeating: "x", count: 2 * 1_024 * 1_024), model: nil) }
            // Give the local handshake time to finish and the write to fill stdin.
            try await Task.sleep(nanoseconds: 200_000_000)
            runtime.stop()
            do { try await submission.value; XCTFail("A full pipe must fail within the write deadline") }
            catch { XCTAssertTrue(error.localizedDescription.contains("stopped reading input")) }
            await fulfillment(of: [closed], timeout: 1)
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
            XCTAssertEqual(recorder.statuses.last, .closed)
        }
    }

    func testInterruptDuringCodexTurnStartTerminatesStartup() async throws {
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        hold
        """)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let threadReady = expectation(description: "thread ready, but no turn ID")
        recorder.observe = { event in if case .providerSession = event { threadReady.fulfill() } }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        let submission = Task { try await runtime.send(text: "hello", model: nil) }
        await fulfillment(of: [threadReady], timeout: 5)
        try await runtime.interrupt()
        do { try await submission.value; XCTFail("Startup must be cancelled") }
        catch { XCTAssertTrue(error.localizedDescription.contains("stopped")) }
        XCTAssertEqual(recorder.statuses.last, .closed)
    }
}

final class AgentRuntimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentRuntimeEvent] = []
    var observe: (@Sendable (AgentRuntimeEvent) -> Void)?
    func receive(_ event: AgentRuntimeEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
        observe?(event)
    }
    private var snapshot: [AgentRuntimeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
    var statuses: [AgentChatStatus] { snapshot.compactMap { if case .status(let value) = $0 { return value }; return nil } }
    var failures: [String] { snapshot.compactMap { if case .failure(let value) = $0 { return value }; return nil } }
    var sessions: [String] { snapshot.compactMap { if case .providerSession(let value) = $0 { return value }; return nil } }
    var contextUsage: [AgentContextUsage] { snapshot.compactMap { if case .contextUsage(let value) = $0 { return value }; return nil } }
    var resolvedModels: [String] { snapshot.compactMap { if case .resolvedModel(let value) = $0 { return value }; return nil } }
    var transcript: [String: AgentChatItem] {
        var items: [String: AgentChatItem] = [:]
        for event in snapshot {
            switch event {
            case .item(let item): items[item.id] = item
            case .textDelta(let id, let text): items[id]?.text += text
            default: break
            }
        }
        return items
    }
}

struct AgentRuntimeFixture: Sendable {
    let directory: URL
    let script: URL
    let log: URL
    init(_ body: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tab-agent-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("peer.sh")
        log = directory.appendingPathComponent("input.jsonl")
        let source = """
        #!/bin/sh
        set -eu
        log="$1"
        shift
        printf '%s\\n' '---' >> "$log.args"
        printf '%s\\n' "$@" >> "$log.args"
        take() { IFS= read -r line || exit 0; printf '%s\\n' "$line" >> "$log"; }
        emit() { printf '%s\\n' "$1"; }
        hold() { while IFS= read -r line; do :; done; }
        \(body)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
    }
    func runtime(_ provider: AgentChatProvider, recorder: AgentRuntimeRecorder, resume: String? = nil,
                 timeout: TimeInterval = 3) -> AgentRuntime {
        AgentRuntime(provider: provider, directory: directory.path, resumeSession: resume,
                     launchBuilder: { arguments in
                         .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path, log.path] + arguments,
                               environment: AgentProcess.environment())
                     },
                     requestTimeout: timeout, onEvent: { recorder.receive($0) })
    }
    func messages() throws -> [[String: Any]] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
    func launches() throws -> [String] {
        try String(contentsOfFile: log.path + ".args", encoding: .utf8).components(separatedBy: "---\n")
            .filter { !$0.isEmpty }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
