import AppKit
import Darwin
import TabClient
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

/// No provider/account is used: the child emits partial messages, then cannot finish
/// until this test has observed them through the real app's sole event consumer.
@MainActor
final class AgentStreamingIntegrationTests: XCTestCase {
    private var root: URL!
    private var daemon: Process?
    private var admin: ServerClient?
    private var model: AppModel?
    private var window: NSWindow?

    private struct Connector: ServerConnector {
        let dirs: TabDirs
        func connect() async throws -> ServerAPI {
            try await LocalServer(dirs: dirs).connect(kind: .desktop, start: false)
        }
    }

    private enum Failure: Error { case timeout(String) }

    override func setUp() async throws {
        _ = NSApplication.shared
        // The approved long macOS temp path would exceed the Unix socket SUN_LEN.
        root = URL(fileURLWithPath: "/tmp/tab-as-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["claude", "codex"] {
            let file = bin.appendingPathComponent(name)
            // Shadow BOTH names so an accidental provider change cannot run a real CLI.
            try (name == "claude" ? Self.providerScript : "#!/bin/sh\nexit 97\n")
                .write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let executable = ProcessInfo.processInfo.environment["TAB_SERVER_BIN"].map { URL(fileURLWithPath: $0) }
            ?? products.appendingPathComponent("tabd")
        guard Executable.isExecutableFile(executable) else {
            throw XCTSkip("Build tabd before running AgentStreamingIntegrationTests (or set TAB_SERVER_BIN)")
        }
        let process = Process()
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["TAB_DIR"] = root.path
        environment["PATH"] = bin.path + ":/usr/bin:/bin"
        environment.removeValue(forKey: "TAB_SESSION_ID")
        environment.removeValue(forKey: "CLAUDECODE")
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        daemon = process
        let dirs = TabDirs(root: root)
        for _ in 0..<200 {
            do {
                admin = try await LocalServer(dirs: dirs).connect(kind: .desktop, start: false)
                break
            } catch {
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        guard admin != nil else { throw Failure.timeout("tabd startup; \(serverLog)") }
        let appRoot = root.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
        model = AppModel(dirs: TabDirs(root: appRoot),
                         connectorFactory: { id, _ in id.isLocal ? Connector(dirs: dirs) : nil })
        model?.start()
        try await wait("app catalog and both connections") {
            self.model?.state.serverIdentity(.local) != nil && self.model?.connectionState(.local).isReady == true
        }
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        if let model {
            for (_, controller) in model.panes.all { controller.dispose() }
            model.connection(.local)?.disconnect()
        }
        model = nil
        if let admin { _ = try? await admin.stopServer(force: true); admin.close() }
        admin = nil
        if let daemon {
            for _ in 0..<100 where daemon.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
            if daemon.isRunning { daemon.terminate() }
            for _ in 0..<100 where daemon.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
            if daemon.isRunning { Darwin.kill(daemon.processIdentifier, SIGKILL) }
            daemon.waitUntilExit()
        }
        daemon = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testPartialAssistantIsLaidOutAndUpdatesSameTextViewBeforeProviderCanFinish() async throws {
        let model = try XCTUnwrap(model)
        let id = try XCTUnwrap(model.newAgent())
        let pane = try XCTUnwrap(model.controller(for: id) as? AgentPaneController)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane.view
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        self.window = window
        try await wait("initial agent snapshot") { pane.snapshot?.status == .idle }
        pane.surface.composer.string = "Exercise streaming, not the final answer"
        pane.selectModel(provider: .claude, model: "claude-sonnet-5-5")
        pane.selectEffort(.medium)
        pane.send()

        // Do not call refresh(), render(), layoutSubtreeIfNeeded(), or consume a second
        // events iterator: real daemon events and the app's normal AppKit loop must do it.
        do {
            try await wait("first delta in controller") {
                pane.snapshot?.items.contains { $0.id == "stream-answer" && $0.text == "FIRST-PARTIAL" && !$0.isComplete } == true
            }
        } catch {
            // A diagnostic read on another socket must never drive the app's refresh.
            let stored = try? await admin?.agentChat(.read(session: pane.session))
            XCTFail("Daemon snapshot: \(String(describing: stored)); controller: \(String(describing: pane.snapshot)); UI error: \(pane.errorMessage ?? "none")")
            throw error
        }
        let firstRevision = try XCTUnwrap(pane.snapshot?.revision)
        XCTAssertEqual(pane.snapshot?.status, .working)
        XCTAssertFalse(exists("final-emitted"))
        XCTAssertFalse(exists("allow-second"))
        let first = try await assistantTextView(pane, text: "FIRST-PARTIAL")

        try Data().write(to: root.appendingPathComponent("allow-second"))
        let expanded = "FIRST-PARTIAL SECOND-PARTIAL"
        try await wait("second delta in controller") {
            pane.snapshot?.items.contains { $0.id == "stream-answer" && $0.text == expanded && !$0.isComplete } == true
        }
        XCTAssertGreaterThan(try XCTUnwrap(pane.snapshot?.revision), firstRevision)
        XCTAssertEqual(pane.snapshot?.status, .working)
        XCTAssertFalse(exists("final-emitted"))
        XCTAssertFalse(exists("allow-final"))
        let second = try await assistantTextView(pane, text: expanded)
        XCTAssertTrue(second === first, "The second partial must update the still-mounted text view in place")

        // Only after BOTH interim displays are proven can the subprocess emit its
        // assembled assistant/result frames. A final-message-only UI cannot pass.
        try Data().write(to: root.appendingPathComponent("allow-final"))
        try await wait("final assistant") {
            pane.snapshot?.status == .idle && pane.snapshot?.items.contains {
                $0.id == "stream-answer" && $0.text == expanded && $0.isComplete
            } == true
        }
        XCTAssertTrue(exists("final-emitted"))
        XCTAssertEqual(pane.snapshot?.items.filter { $0.kind == .assistant }.count, 1)
        let final = try await assistantTextView(pane, text: expanded)
        XCTAssertTrue(final === first, "Completing the message must keep its text view")
    }

    /// The desktop may be locked. This checks the transcript's mounted, laid-out
    /// text views, not an on-screen screenshot or the stored snapshot string.
    private func assistantTextView(_ pane: AgentPaneController, text: String) async throws -> NSTextView {
        var matches: [NSTextView] = []
        for _ in 0..<400 {
            let document = pane.surface.transcriptScroll.documentView ?? pane.surface
            matches = descendants(document).compactMap { $0 as? NSTextView }.filter { view in
                view.string.contains("FIRST-PARTIAL") && view.window != nil && !view.isHiddenOrHasHiddenAncestor &&
                    view.frame.width > 0 && view.frame.height > 0
            }
            if matches.count == 1, matches[0].string.contains(text) { return matches[0] }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Partial text never reached one laid-out transcript text view: \(text); views: \(matches.map(\.string)); daemon log: \(serverLog)")
        throw Failure.timeout("partial text in the native transcript")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    private var serverLog: String { (try? String(contentsOf: root.appendingPathComponent("server.log"), encoding: .utf8)) ?? "" }

    private func wait(_ description: String, until condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out: \(description); daemon log: \(serverLog)")
        throw Failure.timeout(description)
    }

    private static let providerScript = """
    #!/bin/sh
    set -eu
    emit() { printf '%s\\n' "$1"; }
    take() { IFS= read -r line || exit 0; }
    gate() { while [ ! -f "$TAB_DIR/$1" ]; do /bin/sleep 0.02; done; }
    take
    emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
    take
    emit '{"type":"system","subtype":"init","session_id":"offline-streaming"}'
    emit '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"message_start","message":{"id":"stream-answer"}}}'
    emit '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"FIRST-PARTIAL"}}}'
    gate allow-second
    emit '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" SECOND-PARTIAL"}}}'
    gate allow-final
    : > "$TAB_DIR/final-emitted"
    emit '{"type":"assistant","message":{"id":"stream-answer","content":[{"type":"text","text":"FIRST-PARTIAL SECOND-PARTIAL"}]}}'
    emit '{"type":"result","subtype":"success","is_error":false,"result":"FIRST-PARTIAL SECOND-PARTIAL"}'
    while IFS= read -r line; do :; done
    """
}
