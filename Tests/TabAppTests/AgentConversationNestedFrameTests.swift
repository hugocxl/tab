import AppKit
import Network
import TabCore
import TabProtocol
import WebKit
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationNestedFrameTests: XCTestCase {
    func testDeclaredNestedMcpOriginLoadsButForbiddenFramesAndAllSubframeBridgesAreBlocked() async throws {
        _ = NSApplication.shared
        let child = #"<!doctype html><script>let blocked=false;try{top.__nestedEscaped=true}catch{blocked=true};try{window.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'action',requestId:'nested',action:{kind:'copy',text:'untrusted'}})}catch{};top.postMessage({fixture:'nested-owned-frame',blocked},'*')</script>"#
        let allowed = try NestedFrameHTTPServer(html: child), forbidden = try NestedFrameHTTPServer(html: child)
        defer { allowed.close(); forbidden.close() }
        let allowedOrigin = try await allowed.start(), forbiddenOrigin = try await forbidden.start()
        let html = "<!doctype html><html><body><iframe src='\(allowedOrigin)/allowed'></iframe><iframe src='\(forbiddenOrigin)/forbidden'></iframe></body></html>"
        let bytes = Data(html.utf8)
        let output: [String: Any] = ["tabMcpApp": ["attachmentId": "owned", "server": "weather", "tool": "show", "resourceUri": "ui://weather/show", "csp": ["frameDomains": [allowedOrigin]]]]
        var activity = AgentToolActivity(name: "weather.show", output: String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self), status: .completed, presentation: .dynamicTool)
        activity.outputIsJSON = true
        let item = AgentChatItem(id: "tool", kind: .tool, text: "weather.show", tool: activity,
            attachments: [.init(id: "owned", name: "app.html", mimeType: "text/html", byteCount: bytes.count)])
        let surface = AgentPaneView(), host = surface.conversationWebView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { surface.disposeConversation(); window.close() }
        window.contentView = surface
        surface.frame = NSRect(x: 0, y: 0, width: 680, height: 700); surface.layoutSubtreeIfNeeded()
        surface.fetchAttachment = { _, _ in bytes }
        var acceptedSubframeActions = 0
        host.onAction = { [weak surface] kind, payload in
            if kind == "copy" { acceptedSubframeActions += 1; return true }
            guard let surface else { throw CancellationError() }
            return try await surface.handleConversationAction(kind, payload)
        }
        surface.render(.init(session: SessionId(), project: ProjectId(), provider: .codex, status: .idle, revision: 1, items: [item]))
        for _ in 0..<1000 where !host.isReady { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(host.isReady)
        guard host.isReady else { return }
        let match = try XCTUnwrap(AgentConversationMcpAsset.match(attachmentID: "owned", items: [item]))
        let url = try await host.prepareMcpAsset(match)
        let result = try await host.evaluate("return await new Promise(resolve=>{const listener=event=>{if(event.data?.fixture==='nested-owned-frame'){window.removeEventListener('message',listener);resolve({origin:event.origin,blocked:event.data.blocked,escaped:window.__nestedEscaped===true});}};window.addEventListener('message',listener);const frame=document.createElement('iframe');frame.sandbox='allow-scripts allow-forms';frame.src=url;document.body.append(frame);const direct=document.createElement('iframe');direct.src=directURL;document.body.append(direct);setTimeout(()=>resolve({timeout:true}),3000)})", arguments: ["url": url.absoluteString, "directURL": allowedOrigin + "/main-forbidden"], timeout: .seconds(5)) as? [String: Any]
        XCTAssertEqual(result?["origin"] as? String, "null", String(describing: result))
        XCTAssertEqual(result?["blocked"] as? Bool, true)
        XCTAssertEqual(result?["escaped"] as? Bool, false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(allowed.paths.contains("/allowed"))
        XCTAssertFalse(allowed.paths.contains("/main-forbidden"), "The privileged renderer must retain its self-only frame policy")
        XCTAssertTrue(forbidden.paths.isEmpty, "The exact source document CSP must block undeclared nested origins before any request")
        XCTAssertEqual(acceptedSubframeActions, 0, "Even allowed remote descendants must never cross the native main-frame bridge")
    }
}

/// Real loopback HTTP is necessary: URLProtocol mocks do not service WK's network process.
private final class NestedFrameHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tab.test.nested-frame-http")
    private let lock = NSLock()
    private let html: Data
    private var received: [String] = []
    private var startup: CheckedContinuation<String, Error>?
    private var deadline: Task<Void, Never>?
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return received }
    init(html: String) throws {
        self.html = Data(html.utf8)
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
    }
    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); startup = continuation; lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port { self.finish(.success("http://127.0.0.1:\(port.rawValue)")) }
                case .failed(let error): self.finish(.failure(error))
                case .cancelled: self.finish(.failure(CancellationError()))
                default: break
                }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.finish(.failure(ModelError("Loopback fixture did not start")))
            }
            listener.start(queue: queue)
        }
    }
    private func finish(_ result: Result<String, Error>) {
        lock.lock(); let continuation = startup; startup = nil; lock.unlock()
        guard let continuation else { return }
        deadline?.cancel(); continuation.resume(with: result)
    }
    func close() { listener.cancel(); deadline?.cancel() }
    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let line = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            self.lock.lock(); self.received.append(path); self.lock.unlock()
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(self.html.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(self.html)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
