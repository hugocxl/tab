import Foundation
import TabProtocol
import XCTest
@testable import TabServer

private final class ToolImageRuntime: AgentSessionRuntime, @unchecked Sendable {
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    let image: AgentChatAttachment
    let followingEvents: Int
    init(image: AgentChatAttachment, followingEvents: Int = 0, callback: @escaping @Sendable (AgentRuntimeEvent) -> Void) {
        self.image = image; self.followingEvents = followingEvents; self.callback = callback
    }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
        let tool = AgentToolActivity(name: "image", output: "", status: .completed, presentation: .dynamicTool)
        callback(.toolItem(.init(id: "../native/tool", kind: .tool, text: "image", tool: tool, attachments: [image.descriptor]), images: [image]))
        for index in 0..<followingEvents { callback(.item(.init(id: "after-\(index)", kind: .notice, text: "Following output"))) }
        callback(.status(.idle))
    }
    func approve(request: String, allow: Bool) async throws {}
    func setAccess(_ mode: AgentAccessMode) async throws {}
    func interrupt() async throws {}
    func stop() {}
}

final class AgentToolImagesTests: XCTestCase {
    func testSlowImageStorageDoesNotBlockOtherSessionsAndPreservesEventOrder() async throws {
        try await exerciseBlockedStorage(followingEvents: 1)
    }

    func testSlowImageStorageBoundsDeferredProviderEventsAndFailsExplicitly() async throws {
        try await exerciseBlockedStorage(followingEvents: 600)
    }

    func testClosingDuringStorageRejectsItsOldGenerationAndBufferedEvents() async throws {
        try await exerciseBlockedStorage(followingEvents: 1, closeBeforeRelease: true)
    }

    private func exerciseBlockedStorage(followingEvents: Int, closeBeforeRelease: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-image-staging-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = AgentChatAttachment(name: "Image", mimeType: "image/png", data: Data([1, 2, 3]))
        let store = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            ToolImageRuntime(image: image, followingEvents: followingEvents, callback: callback)
        })
        let gate = DispatchSemaphore(value: 0)
        let staging = expectation(description: "Storage reached blocking worker")
        let stored = expectation(description: "Storage worker finished")
        store.stageToolImages = { images, directory in
            defer { stored.fulfill() }
            staging.fulfill()
            gate.wait()
            let staged = try AgentAttachments.stageToolImages(images, root: directory)
            try AgentAttachments.record(staged, root: directory)
        }
        defer { gate.signal(); store.shutdown() }
        let session = SessionId(), other = SessionId(), project = ProjectId()
        _ = try await store.handle(.create(session: session, project: project, provider: .codex))
        _ = try await store.handle(.create(session: other, project: project, provider: .codex))
        let sending = Task { try await store.handle(.send(session: session, text: "image", model: nil)) }
        await fulfillment(of: [staging], timeout: 2)
        let responsive = expectation(description: "Independent session read while media worker is blocked")
        let probe = Task {
            let snapshot = try await store.handle(.read(session: other))
            XCTAssertEqual(snapshot.session, other)
            let pending = try await store.handle(.read(session: session))
            XCTAssertEqual(pending.status, .working, "Completion must not overtake durable image storage")
            XCTAssertFalse(pending.items.contains { $0.id == "../native/tool" || $0.id.hasPrefix("after-") })
            if closeBeforeRelease {
                let closed = try await store.handle(.close(session: session))
                XCTAssertEqual(closed.status, .closed)
            }
            responsive.fulfill()
        }
        await fulfillment(of: [responsive], timeout: 2)
        gate.signal()
        _ = try await probe.value
        _ = try await sending.value
        await fulfillment(of: [stored], timeout: 2)
        var snapshot = try await store.handle(.read(session: session))
        for _ in 0..<100 where snapshot.status == .working {
            try await Task.sleep(for: .milliseconds(10))
            snapshot = try await store.handle(.read(session: session))
        }
        if closeBeforeRelease {
            for _ in 0..<20 {
                await Task.yield()
                snapshot = try await store.handle(.read(session: session))
                XCTAssertEqual(snapshot.status, .closed)
                XCTAssertFalse(snapshot.items.contains { $0.id == "../native/tool" || $0.id.hasPrefix("after-") })
            }
            do {
                _ = try await store.attachment(.init(session: session, item: "../native/tool", attachment: image.id))
                XCTFail("Unpublished old-generation storage must not become a current attachment")
            } catch {}
            return
        } else if followingEvents < 512 {
            XCTAssertEqual(snapshot.status, .idle)
            XCTAssertEqual(Array(snapshot.items.dropFirst()).map(\.id), ["../native/tool", "after-0"])
        } else {
            XCTAssertEqual(snapshot.status, .failed)
            XCTAssertTrue(snapshot.items.last?.text.contains("pending media limit") == true)
            XCTAssertFalse(snapshot.items.contains { $0.id.hasPrefix("after-") })
        }
        let fetched = try await store.attachment(.init(session: session, item: "../native/tool", attachment: image.id))
        XCTAssertEqual(fetched.attachment, image)
    }

    func testProviderTransportAcceptsLargeImageResultLine() async throws {
        let environment = AgentProcess.environment()
        let python = try AgentProcess.resolve("python3", environment: environment)
        let line = expectation(description: "large result delivered")
        let exit = expectation(description: "process exited")
        let process = try AgentProcess(launch: .init(executable: python,
            arguments: ["-c", "import sys; sys.stdout.write('x' * (18 * 1024 * 1024) + '\\n')"], environment: environment),
            directory: NSTemporaryDirectory(), onLine: { data in
                XCTAssertEqual(data.count, 18 * 1024 * 1024)
                line.fulfill()
            }, onExit: { status, _ in XCTAssertEqual(status, 0); exit.fulfill() })
        defer { process.stop() }
        await fulfillment(of: [line, exit], timeout: 20)
        XCTAssertLessThan(8 * ((AgentChatAttachment.maxPayloadBytes + 2) / 3) * 4 + 1024 * 1024, AgentProcess.maxLineBytes)
    }

    func testClaudeAndCodexPublishImageMetadataWithoutEmbeddingBlobInText() throws {
        let recorder = AgentRuntimeRecorder()
        let data = Data("provider raster fixture".utf8).base64EncodedString()
        let claude = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        claude.beginTurn()
        claude.receive(["type": "assistant", "message": ["id": "message", "content": [
            ["type": "tool_use", "id": "claude-image", "name": "Screenshot", "input": [:]],
        ]]])
        claude.receive(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "claude-image", "content": [
                ["type": "text", "text": "Screenshot captured"],
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": data]],
            ]],
        ]]])
        let codex = CodexAgentRuntime(onEvent: { recorder.receive($0) })
        codex.receive(["method": "item/completed", "params": ["item": [
            "type": "dynamicToolCall", "id": "codex-image", "tool": "js", "namespace": "cua_repl", "success": true,
            "contentItems": [["type": "text", "text": "Screenshot captured"], ["type": "image", "mimeType": "image/png", "data": data]],
        ]]])
        for id in ["claude-image", "codex-image"] {
            let item = try XCTUnwrap(recorder.transcript[id])
            XCTAssertEqual(item.attachments?.count, 1)
            XCTAssertEqual(item.tool?.outputIsJSON, true)
            XCTAssertTrue(item.tool?.output?.contains("Screenshot captured") == true)
            XCTAssertFalse(item.tool?.output?.contains(data) == true)
            XCTAssertFalse(item.detail?.contains(data) == true)
        }
    }

    func testRasterExtractionOrderLimitAndBlobRemoval() throws {
        let data = Data("image fixture".utf8)
        let blocks: [[String: Any]] = (0..<9).map { index in
            index % 2 == 0 ? ["type": "image", "mimeType": "IMAGE/PNG", "data": data.base64EncodedString()]
                : ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
        }
        let result = AgentToolImages.project(["content": blocks])
        XCTAssertEqual(result.images.count, 8)
        XCTAssertEqual(result.images.map(\.data), Array(repeating: data, count: 8))
        XCTAssertEqual(result.images.first?.mimeType, "image/png")
        XCTAssertEqual(Set(result.images.map(\.id)).count, 8)
        let output = try XCTUnwrap((result.output as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(output[0]["type"] as? String, "text")
        XCTAssertNil(output[0]["data"])
        XCTAssertEqual(output[8]["type"] as? String, "image")
        XCTAssertNil(output[8]["data"])
        XCTAssertTrue(AgentToolImages.project(["type": "image", "mimeType": "image/svg+xml", "data": "data"]).images.isEmpty)
        XCTAssertTrue(AgentToolImages.project(["type": "image", "source": ["type": "url", "media_type": "image/png"]]).images.isEmpty)
        XCTAssertEqual(AgentToolImages.project(["type": "image", "mimeType": "image/png"]).images.first?.data, Data())
        XCTAssertFalse(AgentToolImages.directoryName(item: "../native/tool").contains("/"))
    }

    func testProviderItemImagesPersistAndStayOwnedByMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-tool-images-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = AgentChatAttachment(name: "Tool output image", mimeType: "image/png", data: Data(repeating: 17, count: AgentChatAttachment.maxPayloadBytes))
        let store = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in ToolImageRuntime(image: image, callback: callback) })
        let session = SessionId()
        _ = try await store.handle(.create(session: session, project: ProjectId(), provider: .codex))
        _ = try await store.handle(.send(session: session, text: "image", model: nil))
        var snapshot = try await store.handle(.read(session: session))
        for _ in 0..<100 where snapshot.status == .working {
            try await Task.sleep(for: .milliseconds(10))
            snapshot = try await store.handle(.read(session: session))
        }
        XCTAssertEqual(snapshot.items.last?.attachments, [image.descriptor])
        let reply = try await store.attachment(.init(session: session, item: "../native/tool", attachment: image.id))
        XCTAssertEqual(reply.attachment, image)
        try reply.validate()
        XCTAssertLessThan(try WireJSON.encode(reply).count, Limits.maxFrame)
        store.shutdown()
        let restored = try AgentSessions(root: root, projectDirectory: { _ in root.path })
        defer { restored.shutdown() }
        let fetched = try await restored.attachment(.init(session: session, item: "../native/tool", attachment: image.id))
        XCTAssertEqual(fetched.attachment, image)
        do {
            _ = try await restored.attachment(.init(session: session, item: "unrelated", attachment: image.id))
            XCTFail("Images must remain scoped to the message")
        } catch {}
        let saved = try Data(contentsOf: root.appendingPathComponent(session.description + ".json"))
        XCTAssertLessThan(saved.count, 100_000)
    }
}
