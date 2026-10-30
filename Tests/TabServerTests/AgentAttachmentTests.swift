import Foundation
import TabProtocol
import XCTest
@testable import TabServer

private final class AttachmentSessionRuntime: AgentSessionRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var staged: [StagedAgentAttachment] = []
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    let fail: Bool
    var attachments: [StagedAgentAttachment] { lock.withLock { staged } }

    init(fail: Bool = false, callback: @escaping @Sendable (AgentRuntimeEvent) -> Void = { _ in }) {
        self.fail = fail
        self.callback = callback
    }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {}
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?,
              attachments: [StagedAgentAttachment]) async throws {
        lock.withLock { staged = attachments }
        if fail { throw AgentRuntimeError("Synthetic attachment submission failed") }
        callback(.providerSession("attachment-resume"))
    }
    func approve(request: String, allow: Bool) async throws {}
    func setAccess(_ mode: AgentAccessMode) async throws {}
    func interrupt() async throws {}
    func stop() {}
}

final class AgentAttachmentTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tab-attachments-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testStagingNeverTrustsClientNamesOrIDsAsPathsAndKeepsFullContents() throws {
        let root = try root()
        let attachment = AgentChatAttachment(id: "../../outside", name: "../../outside.txt",
                                             mimeType: "text/plain", data: Data("remote project contents".utf8))
        let staged = try XCTUnwrap(AgentAttachments.stage([attachment], root: root).first)
        XCTAssertTrue(staged.url.path.hasPrefix(root.path + "/"))
        XCTAssertFalse(staged.url.path.contains("outside"))
        XCTAssertEqual(try Data(contentsOf: staged.url), attachment.data)
        let prompt = AgentAttachments.prompt(text: "Read", attachments: [staged])
        XCTAssertTrue(prompt.contains(staged.url.path))
        XCTAssertTrue(prompt.contains(attachment.name))
        let mode = try FileManager.default.attributesOfItem(atPath: staged.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertThrowsError(try AgentAttachments.stage([
            .init(name: "image.heic", mimeType: "image/heic", data: Data([1]))], root: root))
    }

    func testClaudeActualStdioSendsNativeImagePDFAndFilePath() async throws {
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        emit '{"type":"result","is_error":false}'
        hold
        """)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "complete")
        recorder.observe = { if case .status(.idle) = $0 { idle.fulfill() } }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        let files: [AgentChatAttachment] = [
            .init(name: "screen.png", mimeType: "image/png", data: Data(repeating: 255, count: 1024 * 1024)),
            .init(name: "doc.pdf", mimeType: "application/pdf", data: Data("%PDF-1.7 synthetic".utf8)),
            .init(name: "notes.txt", mimeType: "text/plain", data: Data("full remote contents".utf8))
        ]
        let staged = try AgentAttachments.stage(files, root: fixture.directory.appendingPathComponent("files"))
        try await runtime.send(text: "", model: nil, reasoningEffort: nil, attachments: staged)
        await fulfillment(of: [idle], timeout: 5)
        let message = try XCTUnwrap(fixture.messages().last?["message"] as? [String: Any])
        let blocks = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.compactMap { $0["type"] as? String }, ["text", "image", "document"])
        for index in 0..<2 {
            let source = try XCTUnwrap(blocks[index + 1]["source"] as? [String: Any])
            XCTAssertEqual(source["media_type"] as? String, files[index].mimeType)
            XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(source["data"] as? String)), files[index].data)
        }
        XCTAssertTrue((blocks[0]["text"] as? String)?.contains(staged[2].url.path) == true)
        XCTAssertEqual(try Data(contentsOf: staged[2].url), files[2].data)
    }

    func testCodexActualStdioSendsNativeImageDataURLAndGenericFilePath() async throws {
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"attachments-thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"attachments-turn"}}}'
        hold
        """)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        let image = AgentChatAttachment(name: "screenshot.jpg", mimeType: "image/jpeg",
                                        data: Data(repeating: 255, count: 1024 * 1024))
        let file = AgentChatAttachment(name: "doc.pdf", mimeType: "application/pdf", data: Data("%PDF".utf8))
        let staged = try AgentAttachments.stage([image, file], root: fixture.directory.appendingPathComponent("files"))
        try await runtime.send(text: "Read these", model: nil, reasoningEffort: nil, attachments: staged)
        let params = try XCTUnwrap(fixture.messages().last?["params"] as? [String: Any])
        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[1]["type"] as? String, "image")
        XCTAssertEqual(input[1]["url"] as? String, "data:image/jpeg;base64," + image.data.base64EncodedString())
        XCTAssertTrue((input[0]["text"] as? String)?.contains(staged[1].url.path) == true)
        XCTAssertEqual(try Data(contentsOf: staged[1].url), file.data)
    }

    func testSessionPersistsDescriptorsAndStagedFilesAcrossResumeAndRejectsBusySend() async throws {
        let root = try root()
        let runtime = AttachmentSessionRuntime()
        let store = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, _ in runtime })
        let id = SessionId(), project = ProjectId()
        _ = try await store.handle(.create(session: id, project: project, provider: .claude))
        let file = AgentChatAttachment(name: "remote.txt", mimeType: "text/plain", data: Data("bytes not a local path".utf8))
        let snapshot = try await store.handle(.send(session: id, text: "", model: nil, attachments: [file]))
        XCTAssertEqual(snapshot.items.first?.attachments, [file.descriptor])
        let path = try XCTUnwrap(runtime.attachments.first?.url)
        do {
            _ = try await store.handle(.send(session: id, text: "busy", model: nil, attachments: [file]))
            XCTFail("Busy sends must not stage files or add transcript rows")
        } catch {}
        XCTAssertEqual(runtime.attachments.count, 1)
        store.shutdown()
        let saved = try Data(contentsOf: root.appendingPathComponent(id.description + ".json"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(file.data.base64EncodedString()))
        let restored = try AgentSessions(root: root, projectDirectory: { _ in root.path })
        defer { restored.shutdown() }
        let resumed = try await restored.handle(.read(session: id))
        XCTAssertEqual(resumed.items.first?.attachments, [file.descriptor])
        XCTAssertEqual(try Data(contentsOf: path), file.data)
        _ = try await restored.handle(.close(session: id))
        XCTAssertEqual(try Data(contentsOf: path), file.data, "Closing must not break provider history references")
    }

    func testFailedSendRetainsAttachmentMetadataAndAllowsRetry() async throws {
        let root = try root()
        let runtime = AttachmentSessionRuntime(fail: true)
        let store = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, _ in runtime })
        defer { store.shutdown() }
        let id = SessionId()
        _ = try await store.handle(.create(session: id, project: ProjectId(), provider: .codex))
        let file = AgentChatAttachment(name: "retry.txt", mimeType: "text/plain", data: Data("kept".utf8))
        let first = try await store.handle(.send(session: id, text: "", model: nil, attachments: [file]))
        XCTAssertEqual(first.status, .failed)
        XCTAssertEqual(first.items.first?.attachments, [file.descriptor])
        let firstPath = try XCTUnwrap(runtime.attachments.first?.url)
        let retry = try await store.handle(.send(session: id, text: "", model: nil, attachments: [file]))
        XCTAssertEqual(retry.status, .failed)
        XCTAssertEqual(retry.items.filter { $0.kind == .user }.count, 2)
        XCTAssertNotEqual(runtime.attachments.first?.url, firstPath)
        XCTAssertEqual(try Data(contentsOf: firstPath), file.data)
    }

    func testUnsupportedAttachmentFailsBeforeTranscriptOrStatusChanges() async throws {
        let root = try root()
        let runtime = AttachmentSessionRuntime()
        let store = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, _ in runtime })
        defer { store.shutdown() }
        let id = SessionId()
        let initial = try await store.handle(.create(session: id, project: ProjectId(), provider: .claude))
        do {
            _ = try await store.handle(.send(session: id, text: "", model: nil, attachments: [
                .init(name: "unsupported.svg", mimeType: "image/svg+xml", data: Data("<svg/>".utf8))]))
            XCTFail("Unsupported images must be explicitly rejected")
        } catch {
            XCTAssertTrue((error as? ServiceError)?.message.contains("Unsupported image type") == true)
        }
        let unchanged = try await store.handle(.read(session: id))
        XCTAssertEqual(unchanged, initial)
        XCTAssertTrue(runtime.attachments.isEmpty)
    }
}
