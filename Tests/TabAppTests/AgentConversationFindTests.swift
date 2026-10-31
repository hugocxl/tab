import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationFindTests: XCTestCase {
    func testNativeFindShortcutOpensAndClosesTheActualSourceBar() async throws {
        _ = NSApplication.shared
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex,
            status: .idle, revision: 1, items: [.init(id: "answer", kind: .assistant, text: "A retained answer")])
        let pane = AgentPaneController(session: snapshot.session, project: snapshot.project, provider: .codex) { _ in snapshot }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 700),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { pane.dispose(); window.close() }
        XCTAssertFalse(pane.performConversationShortcut(.find), "A loading/fallback renderer must not consume Find")
        window.contentView = pane.surface
        pane.surface.frame = NSRect(x: 0, y: 0, width: 680, height: 700)
        pane.surface.layoutSubtreeIfNeeded()
        pane.surface.render(snapshot)
        let host = pane.surface.conversationWebView
        for _ in 0..<1000 where !pane.surface.usesWebConversation { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(pane.surface.usesWebConversation)
        guard pane.surface.usesWebConversation else { return }
        XCTAssertFalse(pane.performConversationShortcut(.newTab))
        XCTAssertTrue(pane.performConversationShortcut(.find))
        var opened = false
        for _ in 0..<200 {
            opened = try await host.evaluate("return document.querySelector('[data-thread-find-bar] input[aria-label=\"Find in thread\"]') !== null") as? Bool == true
            if opened { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(opened, "The native action must open the conversation’s actual find bar")
        let closed = try await host.evaluate("return window.TabConversation.find('close')") as? Bool
        XCTAssertEqual(closed, true)
        var visible = true
        for _ in 0..<200 {
            visible = try await host.evaluate("return document.querySelector('[data-thread-find-bar]') !== null") as? Bool == true
            if !visible { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(visible)
    }
}
