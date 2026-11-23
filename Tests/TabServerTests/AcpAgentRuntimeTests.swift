import Foundation
import TabProtocol
import XCTest
@testable import TabServer

/// The ACP runtime against a scripted agent that answers each request by its order,
/// the way Gemini CLI and OpenCode answer: `initialize`, then a session, then prompts.
final class AcpAgentRuntimeTests: XCTestCase {
    private var fixture: AgentRuntimeFixture?

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
    }

    private func runtime(_ body: String, provider: AgentChatProvider = .openCode, resume: String? = nil,
                         recorder: AgentRuntimeRecorder) throws -> (AcpAgentRuntime, AgentRuntimeFixture) {
        let fixture = try AgentRuntimeFixture(body)
        self.fixture = fixture
        let launch = AgentProcess.Launch(executable: URL(fileURLWithPath: "/bin/sh"),
                                         arguments: [fixture.script.path, fixture.log.path], environment: AgentProcess.environment())
        let runtime = AcpAgentRuntime(provider: provider, directory: fixture.directory.path, resumeSession: resume,
                                      launch: launch, requestTimeout: 5, onEvent: { recorder.receive($0) })
        return (runtime, fixture)
    }

    private func wait(for recorder: AgentRuntimeRecorder, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out; statuses \(recorder.statuses), failures \(recorder.failures)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static let initialize = #"emit '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true}},"authMethods":[{"id":"login","name":"Login"}]}}'"#

    private static let options = #"[{"id":"model","category":"model","type":"select","currentValue":"m-default","options":[{"value":"m-default","name":"Default"},{"value":"m-fast","name":"Fast"}]},{"id":"effort","category":"thought_level","type":"select","currentValue":"default","options":[{"value":"low","name":"Low"},{"value":"high","name":"High"},{"value":"default","name":"Default"}]},{"id":"mode","category":"mode","type":"select","currentValue":"build","options":[{"value":"build","name":"Build"},{"value":"plan","name":"Plan"}]}]"#

    func testATurnStreamsThinkingToolsAndTextThenEnds() async throws {
        let recorder = AgentRuntimeRecorder()
        let (runtime, fixture) = try runtime("""
        take
        \(Self.initialize)
        take
        emit '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"ses-1","configOptions":\(Self.options)}}'
        emit '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses-1","update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"review","description":"Review changes","input":{"hint":"branch"}}]}}}'
        take
        emit '{"jsonrpc":"2.0","id":3,"result":{}}'
        take
        emit '{"jsonrpc":"2.0","id":4,"result":{}}'
        take
        emit '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses-1","update":{"sessionUpdate":"agent_thought_chunk","messageId":"r1","content":{"type":"text","text":"Reading the notes."}}}}'
        emit '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"other","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"another session"}}}}'
        emit '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses-1","update":{"sessionUpdate":"tool_call","toolCallId":"call-1","title":"read","kind":"read","status":"pending","rawInput":{}}}}'
        emit '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses-1","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"completed","locations":[{"path":"/tmp/notes.txt"}],"content":[{"type":"content","content":{"type":"text","text":"The secret word is pineapple."}}]}}}'
        emit '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses-1","update":{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"It is "}}}}'
        emit '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses-1","update":{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"pineapple."}}}}'
        emit '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses-1","update":{"sessionUpdate":"usage_update","used":14785,"size":1048576}}}'
        emit '{"jsonrpc":"2.0","id":5,"result":{"stopReason":"end_turn","usage":{"inputTokens":7013,"outputTokens":45}}}'
        hold
        """, recorder: recorder)
        runtime.prepare(AgentLaunch(instructions: "You run in Tab."))
        try await runtime.send(text: "What is the secret word?", model: "m-fast", reasoningEffort: .high)
        try await wait(for: recorder) { recorder.statuses.last == .idle }

        XCTAssertEqual(recorder.sessions, ["ses-1"])
        XCTAssertTrue(recorder.failures.isEmpty, "\(recorder.failures)")
        let sent = try fixture.messages()
        XCTAssertEqual(sent.map { $0["method"] as? String }, ["initialize", "session/new", "session/set_config_option",
                                                               "session/set_config_option", "session/prompt"])
        let model = try XCTUnwrap(sent[2]["params"] as? [String: Any])
        XCTAssertEqual(model["configId"] as? String, "model")
        XCTAssertEqual(model["value"] as? String, "m-fast")
        let effort = try XCTUnwrap(sent[3]["params"] as? [String: Any])
        XCTAssertEqual(effort["configId"] as? String, "effort")
        XCTAssertEqual(effort["value"] as? String, "high")
        let prompt = try XCTUnwrap((sent[4]["params"] as? [String: Any])?["prompt"] as? [[String: Any]])
        XCTAssertEqual(prompt.count, 2, "a new session's first prompt carries Tab's instructions first")
        XCTAssertTrue((prompt[0]["text"] as? String)?.contains("You run in Tab.") == true)
        XCTAssertEqual(prompt[1]["text"] as? String, "What is the secret word?")

        let items = recorder.transcript.values
        let answer = try XCTUnwrap(items.first { $0.kind == .assistant })
        XCTAssertEqual(answer.text, "It is pineapple.", "chunks of one message join; another session's are ignored")
        XCTAssertTrue(answer.isComplete)
        let tool = try XCTUnwrap(items.first { $0.id == "acp-tool:call-1" })
        XCTAssertEqual(tool.tool?.category, .read)
        XCTAssertEqual(tool.tool?.status, .completed)
        XCTAssertEqual(tool.tool?.filePaths, ["/tmp/notes.txt"])
        XCTAssertEqual(tool.tool?.output, "The secret word is pineapple.")
        let thought = try XCTUnwrap(items.first { $0.workContext?.itemType == "reasoning" })
        XCTAssertEqual(thought.detail, "Reading the notes.")
        XCTAssertEqual(recorder.contextUsage.last, AgentContextUsage(usedTokens: 14785, contextWindow: 1_048_576))
        XCTAssertEqual(recorder.resolvedModels.last, "m-fast")
        XCTAssertEqual(recorder.statuses, [.working, .idle])
    }

    func testPermissionRequestsAskThenSendTheChosenOption() async throws {
        let recorder = AgentRuntimeRecorder()
        let (runtime, fixture) = try runtime("""
        take
        \(Self.initialize)
        take
        emit '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"ses-1"}}'
        take
        emit '{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{"sessionId":"ses-1","toolCall":{"toolCallId":"t1","title":"rm -rf build","kind":"execute","rawInput":{"command":"rm -rf build"}},"options":[{"optionId":"yes","name":"Allow","kind":"allow_once"},{"optionId":"always","name":"Always allow","kind":"allow_always"},{"optionId":"no","name":"Reject","kind":"reject_once"}]}}'
        take
        emit '{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"ses-1","toolCall":{"toolCallId":"t2","title":"Read notes","kind":"read"},"options":[{"optionId":"ok","name":"Allow","kind":"allow_once"}]}}'
        take
        emit '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
        hold
        """, recorder: recorder)
        try await runtime.setAccess(.standard)
        try await runtime.send(text: "Clean up", model: nil, reasoningEffort: nil)
        try await wait(for: recorder) { recorder.statuses.last == .waiting }
        let row = try XCTUnwrap(recorder.transcript["acp-permission:perm-1"])
        XCTAssertEqual(row.approval?.decisions.map(\.kind), [.allowOnce, .allowForSession, .decline])
        XCTAssertTrue(row.approval?.requested.contains { $0.label == "Command" && $0.value == "rm -rf build" } == true)

        try await runtime.decide(request: "acp-permission:perm-1", decision: "always", answers: nil)
        try await wait(for: recorder) { recorder.statuses.last == .idle }
        let answers = try fixture.messages().filter { $0["method"] == nil }
        XCTAssertEqual(answers.count, 2)
        XCTAssertEqual(answers[0]["id"] as? String, "perm-1", "a string ID goes back as a string")
        XCTAssertEqual((answers[0]["result"] as? [String: Any])?["outcome"] as? [String: String],
                       ["outcome": "selected", "optionId": "always"])
        XCTAssertEqual(answers[1]["id"] as? Int, 7)
        XCTAssertEqual((answers[1]["result"] as? [String: Any])?["outcome"] as? [String: String],
                       ["outcome": "selected", "optionId": "ok"], "Auto access allows reading without asking")
        XCTAssertEqual(recorder.transcript["acp-permission:7"]?.approval?.outcome?.source, .automatic)
        XCTAssertEqual(recorder.transcript["acp-permission:perm-1"]?.approval?.outcome?.kind, .allowForSession)
    }

    func testResumingLoadsTheSessionWithoutReplayingItsHistory() async throws {
        let recorder = AgentRuntimeRecorder()
        let (runtime, fixture) = try runtime("""
        take
        \(Self.initialize)
        take
        emit '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses-old","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"an old answer"}}}}'
        emit '{"jsonrpc":"2.0","id":2,"result":{"models":{"availableModels":[{"modelId":"auto","name":"Auto"}],"currentModelId":"auto"},"modes":{"availableModes":[{"id":"default","name":"Default"},{"id":"yolo","name":"YOLO"}],"currentModeId":"default"}}}'
        take
        emit '{"jsonrpc":"2.0","id":3,"result":null}'
        take
        emit '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses-old","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"a new answer"}}}}'
        emit '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
        hold
        """, provider: .gemini, resume: "ses-old", recorder: recorder)
        try await runtime.setAccess(.fullAccess)
        try await runtime.send(text: "Go on", model: nil, reasoningEffort: nil)
        try await wait(for: recorder) { recorder.statuses.last == .idle }
        let sent = try fixture.messages()
        XCTAssertEqual(sent.map { $0["method"] as? String }, ["initialize", "session/load", "session/set_mode", "session/prompt"])
        XCTAssertEqual((sent[1]["params"] as? [String: Any])?["sessionId"] as? String, "ses-old")
        XCTAssertEqual((sent[2]["params"] as? [String: Any])?["modeId"] as? String, "yolo", "Full access uses the agent's own mode")
        let prompt = try XCTUnwrap((sent[3]["params"] as? [String: Any])?["prompt"] as? [[String: Any]])
        XCTAssertEqual(prompt.count, 1, "a resumed session already has Tab's instructions")
        XCTAssertEqual(recorder.sessions, ["ses-old"])
        XCTAssertEqual(recorder.transcript.values.filter { $0.kind == .assistant }.map(\.text), ["a new answer"])
    }

    func testASignedOutAgentSaysHowToSignIn() async throws {
        let recorder = AgentRuntimeRecorder()
        let (runtime, _) = try runtime("""
        take
        \(Self.initialize)
        take
        emit '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication required."}}'
        hold
        """, provider: .gemini, recorder: recorder)
        do {
            try await runtime.send(text: "Hello", model: nil, reasoningEffort: nil)
            XCTFail("a session that can't sign in fails")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't signed in"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("gemini"), error.localizedDescription)
        }
        XCTAssertEqual(recorder.statuses.last, .failed)
    }

    func testPlanModeNeedsTheAgentsOwnPlanMode() async throws {
        let recorder = AgentRuntimeRecorder()
        let (runtime, fixture) = try runtime("""
        take
        \(Self.initialize)
        take
        emit '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"ses-1","configOptions":\(Self.options)}}'
        take
        emit '{"jsonrpc":"2.0","id":3,"result":{}}'
        take
        emit '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses-1","update":{"sessionUpdate":"plan","entries":[{"content":"Read the code","status":"completed"},{"content":"Write the plan","status":"in_progress"}]}}}'
        emit '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
        hold
        """, recorder: recorder)
        try await runtime.setPlan(true)
        try await runtime.send(text: "Plan it", model: nil, reasoningEffort: nil)
        try await wait(for: recorder) { recorder.statuses.last == .idle }
        let sent = try fixture.messages()
        XCTAssertEqual((sent[2]["params"] as? [String: Any])?["value"] as? String, "plan")
        let plan = try XCTUnwrap(recorder.transcript.values.first { $0.workContext?.itemType == "todo_list" })
        XCTAssertTrue(plan.detail?.contains("Write the plan") == true)
    }
}

extension AcpAgentRuntimeTests {
    private static let antigravityInitialize = #"emit '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"resume":{},"load":{},"close":{}},"_meta":{"antigravity":{"systemPrompt":{"append":true}}}},"authMethods":[{"id":"oauth-personal","name":"Log in with Google"},{"id":"gemini-api-key","name":"Gemini API key"}]}}'"#

    func testAntigravitySignsInWithItsKeychainAccountAndTakesTabsInstructionsAsASystemPrompt() async throws {
        let recorder = AgentRuntimeRecorder()
        let (runtime, fixture) = try runtime("""
        take
        \(Self.antigravityInitialize)
        take
        emit '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication required"}}'
        take
        emit '{"jsonrpc":"2.0","id":3,"result":{}}'
        take
        emit '{"jsonrpc":"2.0","id":4,"result":{"sessionId":"agy-1"}}'
        take
        emit '{"jsonrpc":"2.0","id":5,"result":{"stopReason":"end_turn"}}'
        hold
        """, provider: .antigravity, recorder: recorder)
        runtime.prepare(AgentLaunch(instructions: "You run in Tab."))
        try await runtime.send(text: "Hello", model: nil, reasoningEffort: nil)
        try await wait(for: recorder) { recorder.statuses.last == .idle }
        let sent = try fixture.messages()
        XCTAssertEqual(sent.map { $0["method"] as? String }, ["initialize", "session/new", "authenticate", "session/new", "session/prompt"])
        XCTAssertEqual((sent[2]["params"] as? [String: Any])?["methodId"] as? String, "oauth-personal")
        let meta = (sent[3]["params"] as? [String: Any])?["_meta"] as? [String: Any]
        XCTAssertEqual(((meta?["antigravity"] as? [String: Any])?["systemPrompt"] as? [String: Any])?["append"] as? String, "You run in Tab.")
        let prompt = try XCTUnwrap((sent[4]["params"] as? [String: Any])?["prompt"] as? [[String: Any]])
        XCTAssertEqual(prompt.count, 1, "the instructions went with the session, not the prompt")
    }

    func testAntigravityResumesWithoutReplayingAndAskingForABrowserFailsAtOnce() async throws {
        let recorder = AgentRuntimeRecorder()
        let (runtime, fixture) = try runtime("""
        take
        \(Self.antigravityInitialize)
        take
        emit '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication required"}}'
        take
        emit 'Open the following link to authenticate the ACP server: https://accounts.google.com/o/oauth2/v2/auth?state=x'
        hold
        """, provider: .antigravity, resume: "agy-old", recorder: recorder)
        do {
            try await runtime.send(text: "Go on", model: nil, reasoningEffort: nil)
            XCTFail("a sign-in in a browser can't happen in a pane")
        } catch {}
        try await wait(for: recorder) { recorder.statuses.last == .failed }
        XCTAssertTrue(recorder.failures.first?.contains("Run `agy` in a terminal") == true, "\(recorder.failures)")
        XCTAssertEqual(try fixture.messages()[1]["method"] as? String, "session/resume")
    }
}

final class AcpSessionOptionsTests: XCTestCase {
    func testGeminiModelsAndOpenCodeOptionsBothListModels() throws {
        let gemini = AcpSessionOptions([
            "models": ["availableModels": [["modelId": "auto", "name": "Auto"], ["modelId": "gemini-pro", "name": "Gemini Pro"]],
                       "currentModelId": "auto"],
            "modes": ["availableModes": [["id": "default", "name": "Default"], ["id": "autoEdit", "name": "Auto Edit"],
                                         ["id": "yolo", "name": "YOLO"], ["id": "plan", "name": "Plan"]], "currentModeId": "default"],
        ])
        XCTAssertEqual(gemini.descriptors().map(\.id), ["auto", "gemini-pro"])
        XCTAssertEqual(gemini.descriptors().first?.isDefault, true)
        XCTAssertEqual(gemini.planMode, "plan")
        XCTAssertEqual(gemini.fullAccessMode, "yolo")

        let data = Data(#"{"configOptions":[{"id":"model","category":"model","type":"select","currentValue":"openai/gpt","options":[{"value":"openai/gpt","name":"GPT"},{"value":"opencode/free","name":"Free"}]},{"id":"effort","category":"thought_level","type":"select","currentValue":"default","options":[{"value":"low","name":"Low"},{"value":"max","name":"Max"},{"value":"default","name":"Default"}]},{"id":"mode","category":"mode","type":"select","currentValue":"build","options":[{"value":"build","name":"Build"},{"value":"plan","name":"Plan"}]}]}"#.utf8)
        let openCode = AcpSessionOptions(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
        let models = openCode.descriptors()
        XCTAssertEqual(models.map(\.id), ["openai/gpt", "opencode/free"])
        XCTAssertEqual(models[0].reasoningEfforts, [.low, .max], "the agent's own default isn't a level to choose")
        XCTAssertEqual(openCode.planMode, "plan")
        XCTAssertNil(openCode.fullAccessMode)
    }
}
