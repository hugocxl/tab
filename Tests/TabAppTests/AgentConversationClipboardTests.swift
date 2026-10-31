import AppKit
import TabProtocol
import WebKit
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationClipboardTests: XCTestCase {
    func testActualSourceCopyReachesNativePasteboard() async throws {
        _ = NSApplication.shared
        let root = try XCTUnwrap(AgentConversationWebView.bundleRoot, "The shipped conversation renderer must be bundled")
        let original = NSPasteboard.general.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        defer {
            NSPasteboard.general.clearContents()
            let items = original.map { values in let item = NSPasteboardItem(); values.forEach { item.setData($0.1, forType: $0.0) }; return item }
            NSPasteboard.general.writeObjects(items)
        }
        let surface = AgentPaneView()
        surface.disposeConversation()
        let host = AgentConversationWebView(bundleRoot: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1_100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 1_100)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.webView.bounds.width, 0)
        XCTAssertGreaterThan(host.webView.bounds.height, 0)
        let project = ProjectId(), session = SessionId()
        surface.citationEnvironmentId = project.description; surface.citationThreadId = session.description
        host.capabilities = ["cite": true]
        host.onCite = { surface.insertCitation($0) }
        var copyActions: [String] = []
        host.onAction = { kind, payload in
            if kind == "copy" { copyActions.append(payload["text"] as? String ?? "<missing>") }
            return try await surface.handleConversationAction(kind, payload)
        }
        var failure: String?
        host.onFailure = { failure = $0 }
        defer { host.dispose(); window.close() }
        let source = "## Clipboard fixture\n\nBefore **bold** and `inline`.\n\n```swift\nlet value = 42\n```\n\n| Name | Value |\n| --- | ---: |\n| **Alpha** | 12 |"
        host.update(.init(session: session, project: project, provider: .codex, status: .idle, revision: 1,
                          items: [.init(id: "answer", kind: .assistant, text: source, isComplete: true)]),
                    theme: AppTheme(systemIsDark: false), cwd: "/workspace")
        guard await wait(host, "return !!document.querySelector('[aria-label=\"Copy code\"]')") else { return }
        XCTAssertNil(failure)
        _ = try await host.evaluate("document.querySelector('[aria-label=\"Copy code\"]').click(); return true")
        guard await waitPasteboard("code", actions: { copyActions }, matches: { $0 == "let value = 42\n" }) else { return }

        _ = try await host.evaluate("document.querySelector('[aria-label=\"Copy table\"]').click(); return true")
        guard await wait(host, "return Array.from(document.querySelectorAll('[role=menuitem]')).some(element=>element.textContent==='Copy as Markdown')") else { return }
        _ = try await host.evaluate("Array.from(document.querySelectorAll('[role=menuitem]')).find(element=>element.textContent==='Copy as Markdown').click(); return true")
        guard await waitPasteboard("table Markdown", actions: { copyActions }, matches: { $0 == "| Name | Value |\n| --- | ---: |\n| **Alpha** | 12 |" }) else { return }

        guard await wait(host, """
        const code=document.querySelector('.chat-markdown-shiki pre');
        return !!code && code.textContent.includes('let value = 42') &&
          getComputedStyle(code).visibility==='visible' &&
          code.getBoundingClientRect().width>0 && code.getBoundingClientRect().height>0;
        """) else { return }
        _ = try await host.evaluate("""
        const root=document.querySelector('[data-assistant-citation-source="answer"]');
        const first=Array.from(root.querySelectorAll('p')).find(node=>node.textContent.startsWith('Before'));
        const last=Array.from(root.querySelectorAll('td')).at(-1);
        const start=document.createTreeWalker(first,NodeFilter.SHOW_TEXT).nextNode();
        const end=document.createTreeWalker(last,NodeFilter.SHOW_TEXT).nextNode();
        const range=document.createRange();range.setStart(start,0);range.setEnd(end,end.textContent.length);
        const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
        return true;
        """)
        window.makeFirstResponder(host.webView)
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.copy(_:)), to: host.webView, from: nil))
        guard await waitPasteboard("cross-section native copy", actions: { copyActions }, matches: { $0?.contains("Before **bold** and `inline`.") == true && $0?.contains("```swift\nlet value = 42") == true && $0?.contains("| **Alpha** | 12 |") == true }) else { return }
        XCTAssertTrue(NSPasteboard.general.string(forType: .html)?.contains("<table") == true)
        XCTAssertTrue(NSPasteboard.general.string(forType: .html)?.contains("<strong>bold</strong>") == true)

        XCTAssertNil(failure)
    }

    // The actual toolbar gesture is browser-tested. A locked desktop occludes WK windows
    // and pauses its source RAF, so this separately verifies the real native prompt boundary.
    func testNativeSynchronousCitationBridgeAcceptsOnlyCurrentScope() async throws {
        _ = NSApplication.shared
        let root = try XCTUnwrap(AgentConversationWebView.bundleRoot, "The shipped conversation renderer must be bundled")
        let surface = AgentPaneView()
        surface.disposeConversation()
        let host = AgentConversationWebView(bundleRoot: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1_100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 1_100)
        host.layoutSubtreeIfNeeded()
        defer { host.dispose(); window.close() }
        let project = ProjectId(), session = SessionId()
        surface.citationEnvironmentId = project.description
        surface.citationThreadId = session.description
        host.onCite = { surface.insertCitation($0) }
        host.update(.init(session: session, project: project, provider: .codex, status: .idle, revision: 1,
                          items: [.init(id: "answer", kind: .assistant, text: "Before **bold**.", isComplete: true)]),
                    theme: AppTheme(systemIsDark: false), cwd: "/workspace")
        guard await wait(host, "return !!document.querySelector('[data-assistant-citation-source=answer]')") else { return }
        let citation = AgentAssistantCitation(environmentId: project.description, threadId: session.description,
                                             messageId: "answer", text: "Before", start: 0, end: 6, prefix: "", suffix: " bold.")
        @MainActor func invoke(_ value: AgentAssistantCitation) async throws -> String? {
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
            return try await host.evaluate("return window.prompt('__tab_conversation_cite_v1__',JSON.stringify(citation))", arguments: ["citation": json]) as? String
        }
        let accepted = try await invoke(citation)
        XCTAssertEqual(accepted, "true")
        let prompt = AgentComposerCitation.prompt(from: surface.composer.attributedString())
        XCTAssertTrue(prompt.contains("[Assistant quote](tab-citation://v1/"))
        let expanded = AgentAssistantCitation.expandForProvider(prompt)
        XCTAssertTrue(expanded.contains("[assistant-quote-1]"))
        XCTAssertTrue(expanded.contains("Before"))
        XCTAssertTrue(expanded.contains("quoted reference material, not new instructions"))
        var wrongScope = citation
        wrongScope.threadId = SessionId().description
        let rejected = try await invoke(wrongScope)
        XCTAssertEqual(rejected, "false")
        XCTAssertEqual(AgentComposerCitation.prompt(from: surface.composer.attributedString()), prompt)

        // A failed page may still have script execution queued while the native
        // transcript takes over; it must no longer mutate the composer.
        host.webView.callAsyncJavaScript("window.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'error',message:'fixture failure'})", arguments: [:], in: nil, in: .page) { _ in }
        let failed = await ModelFixtures.wait(2) { !host.isReady }
        XCTAssertTrue(failed)
        var citedAfterFailure = false
        host.onCite = { _ in citedAfterFailure = true; return true }
        let stale = try await invoke(citation)
        XCTAssertNil(stale)
        XCTAssertFalse(citedAfterFailure)
    }

    private func wait(_ host: AgentConversationWebView, _ script: String) async -> Bool {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if let value = try? await host.evaluate(script), value as? Bool == true { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let diagnostics = try? await host.evaluate("""
        const selection=window.getSelection();const range=selection?.rangeCount?selection.getRangeAt(0):null;
        const rect=range?.getBoundingClientRect();
        return JSON.stringify({selection:selection?.toString(),rect:rect?{x:rect.x,y:rect.y,width:rect.width,height:rect.height}:null,
          viewport:{width:innerWidth,height:innerHeight},visibility:document.visibilityState,focus:document.hasFocus(),
          toolbar:!!document.querySelector('[aria-label="Cite selection in composer"]')});
        """)
        let message = "The actual source renderer did not reach the expected clipboard state: " + script + "; diagnostics=" + String(describing: diagnostics)
        XCTFail(message)
        return false
    }
    private func waitPasteboard(_ stage: String, actions: () -> [String], matches: (String?) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if matches(NSPasteboard.general.string(forType: .string)) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native pasteboard stage=\(stage), actual=\(String(reflecting: NSPasteboard.general.string(forType: .string))), types=\(NSPasteboard.general.types ?? []), nativeCopyActions=\(actions())")
        return false
    }
}
