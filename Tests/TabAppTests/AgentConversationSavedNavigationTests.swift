import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationSavedNavigationTests: XCTestCase {
    func testSavedLinkReadsExactlyTheRequestedSessionAndRetainsItsProvider() async throws {
        let session = SessionId(), project = ProjectId()
        let source = AgentChatSnapshot(session: session, project: project, provider: .codex, status: .closed,
                                       items: [.init(id: "answer", kind: .assistant, text: "Saved result", isComplete: true)])
        var requests: [AgentChatRequest] = []
        let result = try await AgentConversationSavedNavigation.read(session: session, project: project, request: { request in requests.append(request); return source })
        XCTAssertEqual(requests, [.read(session: session)])
        XCTAssertEqual(result, source)
    }

    func testMismatchedSessionOrProjectCannotBecomeANavigationTarget() async throws {
        let session = SessionId(), project = ProjectId()
        for result in [AgentChatSnapshot(session: SessionId(), project: project, provider: .claude),
                       AgentChatSnapshot(session: session, project: ProjectId(), provider: .claude)] {
            do {
                _ = try await AgentConversationSavedNavigation.read(session: session, project: project, request: { _ in result })
                XCTFail("An unrelated server reply cannot authorize opening a cited pane")
            } catch {}
        }
    }
    func testExistingTargetBecomesReadyBeforeActualSourceCitationNavigation() async throws {
        _ = NSApplication.shared
        guard AgentConversationWebView.isAvailable else { throw XCTSkip("Build the bundled source conversation") }
        let session = SessionId(), project = ProjectId()
        let snapshot = AgentChatSnapshot(session: session, project: project, provider: .codex, status: .idle, revision: 2,
                                         items: [.init(id: "saved-answer", kind: .assistant, text: "Saved quote with more context.", isComplete: true)])
        var requests: [AgentChatRequest] = []
        let controller = AgentPaneController(session: session, project: project, provider: .codex) { request in requests.append(request); return snapshot }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = controller.surface
        controller.surface.frame = NSRect(x: 0, y: 0, width: 900, height: 1100); controller.surface.layoutSubtreeIfNeeded()
        defer { controller.dispose(); window.close() }
        do { try await AgentConversationSavedNavigation.awaitRenderer(controller, snapshot: snapshot) }
        catch { XCTFail("The existing target renderer did not become authoritative/ready: \(error)"); return }
        let citation = AgentAssistantCitation(environmentId: project.description, threadId: session.description, messageId: "saved-answer",
                                             text: "Saved quote", start: 0, end: 11, prefix: "", suffix: " with more context.")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(citation))
        let accepted = try await controller.surface.conversationWebView.evaluate("return window.TabConversation.navigateCitation(citation)", arguments: ["citation": json]) as? Bool
        XCTAssertEqual(accepted, true)
        XCTAssertEqual(controller.snapshot?.session, session)
        XCTAssertEqual(controller.snapshot?.project, project)
        XCTAssertTrue(requests.allSatisfy { request in
            switch request { case .create(let found, let owner, _): return found == session && owner == project
            case .read(let found): return found == session
            default: return false }
        }, "Navigation must not send a prompt or allocate another session")
    }

}
