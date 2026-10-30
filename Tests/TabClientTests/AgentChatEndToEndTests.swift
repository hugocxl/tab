import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabClient

/// Exercises the real daemon and provider pipes, without installed CLIs or accounts.
final class AgentChatEndToEndTests: XCTestCase {
    private var root: URL!
    private var daemon: Process?
    private var clients: [ServerClient] = []

    override func setUpWithError() throws {
        // Keep the Unix socket below SUN_LEN, including on machines with long temp paths.
        root = URL(fileURLWithPath: "/tmp/tab-ae-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, body) in [("claude", Self.claude), ("codex", Self.codex)] {
            let file = bin.appendingPathComponent(name)
            let source = """
            #!/bin/sh
            set -eu
            log="$TAB_DIR/\(name).jsonl"
            printf '%s\\n' "$*" >> "$TAB_DIR/\(name).args"
            take() { IFS= read -r line || exit 0; printf '%s\\n' "$line" >> "$log"; }
            emit() { printf '%s\\n' "$1"; }
            hold() { while IFS= read -r line; do :; done; }
            \(body)
            """
            try source.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
    }

    override func tearDown() async throws {
        if daemon?.isRunning == true, let client = clients.last {
            _ = try? await client.stopServer(force: true)
        }
        for client in clients { client.close() }
        if let daemon {
            for _ in 0..<100 where daemon.isRunning {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private enum Failure: Error { case timeout(String) }

    private func connect() async throws -> ServerClient {
        let client = try await LocalServer(dirs: TabDirs(root: root)).connect(kind: .desktop, start: false)
        clients.append(client)
        return client
    }

    private func start() async throws -> ServerClient {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let executable = ProcessInfo.processInfo.environment["TAB_SERVER_BIN"].map { URL(fileURLWithPath: $0) }
            ?? products.appendingPathComponent("tabd")
        guard Executable.isExecutableFile(executable) else {
            throw XCTSkip("Build tabd before running AgentChatEndToEndTests (or set TAB_SERVER_BIN)")
        }
        let process = Process()
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["TAB_DIR"] = root.path
        // Only the child receives this PATH. Both provider names are shadowed even
        // when real agents are installed, and the scripts never execute agent tools.
        environment["PATH"] = root.appendingPathComponent("bin").path + ":/usr/bin:/bin"
        environment.removeValue(forKey: "TAB_SESSION_ID")
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        daemon = process
        var lastError: Error?
        for _ in 0..<200 {
            do { return try await connect() }
            catch {
                lastError = error
                if !process.isRunning { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        let log = (try? String(contentsOf: root.appendingPathComponent("server.log"), encoding: .utf8)) ?? ""
        throw Failure.timeout("tabd failed to serve: \(String(describing: lastError)); \(log)")
    }

    /// Reads are driven by real coalesced socket events, not transcript polling.
    private func changed(_ client: ServerClient, session: SessionId,
                         until predicate: @escaping @Sendable (AgentChatSnapshot) -> Bool) async throws -> AgentChatSnapshot {
        try await withThrowingTaskGroup(of: AgentChatSnapshot.self) { group in
            group.addTask {
                for await event in client.events {
                    guard case .agentChatChanged(let id, let revision) = event, id == session else { continue }
                    let snapshot = try await client.agentChat(.read(session: id))
                    XCTAssertEqual(snapshot.session, session)
                    XCTAssertGreaterThanOrEqual(snapshot.revision, revision)
                    if predicate(snapshot) { return snapshot }
                }
                throw Failure.timeout("connection ended waiting for \(session)")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw Failure.timeout("agent change for \(session)")
            }
            defer { group.cancelAll() }
            let result = try await group.next()
            return try XCTUnwrap(result)
        }
    }

    private func messages(_ provider: String) throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("\(provider).jsonl"), encoding: .utf8)
            .split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
    }

    func testBothProvidersApprovalReconnectInterruptAndDaemonPersistence() async throws {
        let first = try await start()
        let home = try await first.catalogPage().home
        let claude = SessionId()
        let codex = SessionId()
        for (session, provider) in [(claude, AgentChatProvider.claude), (codex, .codex)] {
            _ = try await first.agentChat(.create(session: session, project: home, provider: provider))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("claude.args").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("codex.args").path))

        _ = try await first.agentChat(.send(session: claude, text: "Claude prompt", model: "offline-model"))
        let claudeWaiting = try await changed(first, session: claude) { $0.status == .waiting }
        _ = try await first.agentChat(.send(session: codex, text: "Codex prompt", model: "offline-model"))
        let codexWaiting = try await changed(first, session: codex) { $0.status == .waiting }
        XCTAssertEqual(claudeWaiting.providerSession, "offline-claude")
        XCTAssertEqual(codexWaiting.providerSession, "offline-codex")
        for snapshot in [claudeWaiting, codexWaiting] {
            XCTAssertEqual(snapshot.items.filter { $0.kind == .approval && !$0.isComplete }.map(\.id), ["shared-approval"])
            XCTAssertTrue(snapshot.items.contains { $0.kind == .assistant && !$0.isComplete })
        }

        // Both processes remain blocked on stdin while the original socket goes away.
        first.close()
        let reconnected = try await connect()
        let claudeRestored = try await reconnected.agentChat(.read(session: claude))
        let codexRestored = try await reconnected.agentChat(.read(session: codex))
        XCTAssertEqual(claudeRestored, claudeWaiting)
        XCTAssertEqual(codexRestored, codexWaiting)

        // Deliberately reuse the permission ID across providers, but choose opposite
        // decisions: neither the approval lookup nor the outbox may cross sessions.
        _ = try await reconnected.agentChat(.approve(session: codex, request: "shared-approval", allow: false))
        let codexDone = try await changed(reconnected, session: codex) { $0.status == .idle }
        let stillWaiting = try await reconnected.agentChat(.read(session: claude))
        XCTAssertEqual(stillWaiting, claudeWaiting)
        _ = try await reconnected.agentChat(.approve(session: claude, request: "shared-approval", allow: true))
        let claudeDone = try await changed(reconnected, session: claude) { $0.status == .idle }
        for (snapshot, answer, decision) in [(claudeDone, "Claude answer", "Approved"), (codexDone, "Codex answer", "Declined")] {
            XCTAssertEqual(snapshot.items.filter { $0.kind == .assistant }.map(\.text), [answer])
            XCTAssertEqual(snapshot.items.first { $0.id == "shared-approval" }?.text, decision)
            XCTAssertTrue(snapshot.items.allSatisfy(\.isComplete))
            XCTAssertEqual(snapshot.model, "offline-model")
        }

        // Keep the selection unchanged: this scenario tests an established live
        // process. Selection resets/restarts have separate subprocess regressions.
        for session in [claude, codex] {
            _ = try await reconnected.agentChat(.send(session: session, text: "Interrupt me", model: "offline-model"))
            _ = try await changed(reconnected, session: session) {
                $0.status == .working && $0.items.contains { $0.id == "second-answer" }
            }
            _ = try await reconnected.agentChat(.interrupt(session: session))
            _ = try await changed(reconnected, session: session) { $0.status == .idle }
        }
        let closedClaude = try await reconnected.agentChat(.close(session: claude))
        XCTAssertEqual(closedClaude.status, .closed)
        _ = try await reconnected.agentChat(.close(session: codex))
        // Retiring either runtime must not allow its asynchronous stop callback to
        // mutate a closed snapshot or the other provider's transcript.
        try await reconnected.ping()
        let savedClaude = try await reconnected.agentChat(.read(session: claude))
        let savedCodex = try await reconnected.agentChat(.read(session: codex))
        XCTAssertEqual(savedClaude, closedClaude)
        XCTAssertFalse(savedClaude.items.contains { $0.text.contains("Codex") })
        XCTAssertFalse(savedCodex.items.contains { $0.text.contains("Claude") })

        try assertWireMessages()
        _ = try await reconnected.stopServer(force: true)
        reconnected.close()
        let oldDaemon = try XCTUnwrap(daemon)
        for _ in 0..<200 where oldDaemon.isRunning { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertFalse(oldDaemon.isRunning, "daemon must flush checkpoints and stop")
        guard !oldDaemon.isRunning else { return }
        oldDaemon.waitUntilExit()
        let restarted = try await start()
        let persistedClaude = try await restarted.agentChat(.read(session: claude))
        let persistedCodex = try await restarted.agentChat(.read(session: codex))
        XCTAssertEqual(persistedClaude, savedClaude)
        XCTAssertEqual(persistedCodex, savedCodex)
        // Reading persisted conversations must not launch a replacement process.
        for provider in ["claude", "codex"] {
            let launches = try String(contentsOf: root.appendingPathComponent("\(provider).args"), encoding: .utf8)
            XCTAssertEqual(launches.split(separator: "\n").count, 1)
        }
    }

    private func assertWireMessages() throws {
        let claude = try messages("claude")
        XCTAssertEqual(claude.count, 5)
        XCTAssertEqual((claude[0]["request"] as? [String: Any])?["subtype"] as? String, "initialize")
        XCTAssertEqual((claude[1]["message"] as? [String: Any])?["content"] as? String, "Claude prompt")
        let approval = try XCTUnwrap(claude[2]["response"] as? [String: Any])
        XCTAssertEqual(approval["request_id"] as? String, "shared-approval")
        let decision = try XCTUnwrap(approval["response"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertEqual(decision["toolUseID"] as? String, "tool-1")
        XCTAssertEqual((decision["updatedInput"] as? [String: Any])?["command"] as? String, "pwd")
        XCTAssertEqual((claude[4]["request"] as? [String: Any])?["subtype"] as? String, "interrupt")
        let codex = try messages("codex")
        XCTAssertEqual(codex.compactMap { $0["method"] as? String },
                       ["initialize", "initialized", "thread/start", "turn/start", "turn/start", "turn/interrupt"])
        XCTAssertEqual((codex[3]["params"] as? [String: Any])?["model"] as? String, "offline-model")
        XCTAssertEqual(codex[4]["id"] as? String, "shared-approval")
        XCTAssertEqual((codex[4]["result"] as? [String: Any])?["decision"] as? String, "decline")
        let interrupt = try XCTUnwrap(codex.last?["params"] as? [String: Any])
        XCTAssertEqual(interrupt["threadId"] as? String, "offline-codex")
        XCTAssertEqual(interrupt["turnId"] as? String, "turn-2")
    }

    // Synthetic protocol peers use only shell builtins and block on each client
    // message. Each result is gated by an actual approval/interrupt roundtrip.
    private static let claude = """
    take
    emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
    take
    emit '{"type":"system","subtype":"init","session_id":"offline-claude"}'
    emit '{"type":"stream_event","event":{"type":"message_start","message":{"id":"answer"}}}'
    emit '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Claude "}}}'
    emit '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"answer"}}}'
    emit '{"type":"control_request","request_id":"shared-approval","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"tool-1","input":{"command":"pwd"}}}'
    take
    emit '{"type":"assistant","message":{"id":"answer","content":[{"type":"text","text":"Claude answer"}]}}'
    emit '{"type":"result","subtype":"success","is_error":false,"result":"Claude answer"}'
    take
    emit '{"type":"stream_event","event":{"type":"message_start","message":{"id":"second-answer"}}}'
    emit '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Interrupted Claude"}}}'
    take
    emit '{"type":"control_response","response":{"subtype":"success","request_id":"2","response":{}}}'
    emit '{"type":"result","subtype":"success","is_error":false,"result":"Interrupted Claude"}'
    hold
    """

    private static let codex = """
    take
    emit '{"id":1,"result":{}}'
    take
    take
    emit '{"id":2,"result":{"thread":{"id":"offline-codex"}}}'
    take
    emit '{"id":3,"result":{"turn":{"id":"turn-1"}}}'
    emit '{"method":"turn/started","params":{"turn":{"id":"turn-1"}}}'
    emit '{"method":"item/agentMessage/delta","params":{"itemId":"answer","delta":"Codex "}}'
    emit '{"method":"item/agentMessage/delta","params":{"itemId":"answer","delta":"answer"}}'
    emit '{"id":"shared-approval","method":"item/commandExecution/requestApproval","params":{"itemId":"tool-1","command":"pwd","availableDecisions":["accept","decline"]}}'
    take
    emit '{"method":"item/completed","params":{"item":{"id":"answer","type":"agentMessage","text":"Codex answer"}}}'
    emit '{"method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}'
    take
    emit '{"id":4,"result":{"turn":{"id":"turn-2"}}}'
    emit '{"method":"turn/started","params":{"turn":{"id":"turn-2"}}}'
    emit '{"method":"item/agentMessage/delta","params":{"itemId":"second-answer","delta":"Interrupted Codex"}}'
    take
    emit '{"id":5,"result":{}}'
    emit '{"method":"turn/completed","params":{"turn":{"id":"turn-2","status":"interrupted"}}}'
    hold
    """
}
