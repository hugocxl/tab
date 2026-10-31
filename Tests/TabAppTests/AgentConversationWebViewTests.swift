import AppKit
import TabCore
import TabProtocol
import WebKit
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationWebViewTests: XCTestCase {
    func testStartupKeepsNativePlaceholderHiddenUntilThemedConversationCommits() async throws {
        _ = NSApplication.shared
        let surface = AgentPaneView()
        defer { surface.disposeConversation() }
        XCTAssertTrue(surface.transcriptScroll.isHidden, "The old empty state must never be shown during renderer startup")
        XCTAssertTrue(surface.conversationWebView.isHidden)
        XCTAssertFalse(surface.conversationWebView.hasRendered)
        surface.theme = AppTheme(systemIsDark: true)
        surface.themeDidChange()
        surface.render(.init(session: SessionId(), project: ProjectId(), provider: .codex))
        XCTAssertTrue(surface.transcriptScroll.isHidden)
        let ready = await ModelFixtures.wait(15) { surface.usesWebConversation }
        XCTAssertTrue(ready)
        guard ready else { return }
        XCTAssertTrue(surface.conversationWebView.hasRendered)
        XCTAssertFalse(surface.conversationWebView.isHidden)
        XCTAssertTrue(surface.transcriptScroll.isHidden)
        let actual = try XCTUnwrap(surface.conversationWebView.webView.underPageBackgroundColor.usingColorSpace(.sRGB))
        let expected = try XCTUnwrap(surface.theme.card.usingColorSpace(.sRGB))
        for (component, target) in zip([actual.redComponent, actual.greenComponent, actual.blueComponent],
                                       [expected.redComponent, expected.greenComponent, expected.blueComponent]) {
            XCTAssertEqual(component, target, accuracy: 1.0 / 255, "WebKit may quantize its backing color to 8-bit channels")
        }
        let themed = try await surface.conversationWebView.evaluate("return !!window.TabConversation.snapshot?.palette && document.documentElement.classList.contains('dark')") as? Bool
        XCTAssertEqual(themed, true, "Reveal only after the snapshot and its palette are committed")
    }

    func testMissingInitialRenderAcknowledgementFailsWithinBoundedTime() async throws {
        let host = AgentConversationWebView(bundleRoot: nil, initialRenderTimeout: .milliseconds(30))
        defer { host.dispose() }
        var failure: String?
        host.onFailure = { failure = $0 }
        host.update(.init(session: SessionId(), project: ProjectId(), provider: .codex),
                    theme: AppTheme(systemIsDark: true), cwd: nil)
        let failed = await ModelFixtures.wait(2) { failure != nil }
        XCTAssertTrue(failed)
        XCTAssertFalse(host.hasRendered)
        XCTAssertFalse(host.isReady)
    }

    func testSnapshotPreservesOrderedProviderJSONAndMessageOwnedAttachments() throws {
        let descriptor = AgentChatAttachmentDescriptor(id: "image?1", name: "Image", mimeType: "image/png", byteCount: 10)
        let input = #"{"z":1,"a":null,"code":"window.alert('text only')"}"#
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex,
            status: .working, revision: 42, items: [
                .init(id: "user/1", kind: .user, text: "Question", attachments: [descriptor]),
                .init(id: "tool/1", kind: .tool, text: "Inspect", tool: .init(input: input, status: .running)),
            ])
        let payload = try AgentConversationWebView.payload(snapshot, theme: "dark", cwd: "/workspace", sequence: 2)
        XCTAssertEqual(payload["bridgeVersion"] as? Int, 1)
        XCTAssertEqual(payload["sessionId"] as? String, snapshot.session.description)
        XCTAssertEqual(payload["revision"] as? UInt64, 42)
        let items = try XCTUnwrap(payload["items"] as? [[String: Any]])
        XCTAssertEqual((items[1]["tool"] as? [String: Any])?["input"] as? String, input)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let attachments = try XCTUnwrap(messages[0]["attachments"] as? [[String: Any]])
        let url = try XCTUnwrap((attachments[0]["url"] as? String).flatMap(URL.init(string:)))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "item" }?.value, "user/1")
        XCTAssertEqual(query.first { $0.name == "attachment" }?.value, descriptor.id)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
    }

    func testBundledAssetsRejectParentTraversalAndSymlinkEscapes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<html></html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: "/etc")
        XCTAssertNotNil(AgentConversationWebView.bundledAssetURL(try XCTUnwrap(URL(string: "tab-conversation://bundle/index.html")), root: root))
        for value in ["tab-conversation://bundle/../passwd", "tab-conversation://bundle/%2e%2e/etc/passwd", "tab-conversation://bundle/outside/passwd", "file:///etc/passwd", "tab-conversation://attachment/index.html"] {
            XCTAssertNil(AgentConversationWebView.bundledAssetURL(try XCTUnwrap(URL(string: value)), root: root), value)
        }
    }

    func testRepeatedAttachmentIDsRemainMessageScopedForDisplayOpenAndDownload() async throws {
        let shared = AgentChatAttachmentDescriptor(id: "same-id", name: "image.png", mimeType: "image/png", byteCount: 1)
        let first = AgentChatItem(id: "first", kind: .user, text: "One", attachments: [shared])
        let second = AgentChatItem(id: "second", kind: .user, text: "Two", attachments: [shared])
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex, status: .idle, revision: 1, items: [first, second])
        let payload = try AgentConversationWebView.payload(snapshot, theme: "light", cwd: nil)
        let items = try XCTUnwrap(payload["items"] as? [[String: Any]])
        let nativeAttachments = try items.map { try XCTUnwrap($0["attachments"] as? [[String: Any]])[0] }
        XCTAssertEqual(nativeAttachments.compactMap { $0["id"] as? String }, ["same-id", "same-id"], "Raw provider IDs remain unchanged")
        let ids = try nativeAttachments.map { try XCTUnwrap($0["bridgeId"] as? String) }
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertEqual(ids, ["first", "second"].map { AgentConversationWebView.bridgeAttachmentID(item: $0, attachment: "same-id") })
        XCTAssertNil(AgentConversationWebView.ownedAttachment("same-id", snapshot: snapshot), "An ambiguous raw ID must not select an arbitrary owner")
        let surface = AgentPaneView()
        defer { surface.disposeConversation() }
        var opened: [(String, String, Bool)] = []
        surface.onOpenAttachment = { opened.append(($0, $1.id, $2)) }
        surface.render(snapshot)
        for (index, id) in ids.enumerated() {
            let result = try await surface.handleConversationAction("loadAttachment", ["attachmentId": id]) as? [String: Any]
            let url = try XCTUnwrap((result?["url"] as? String).flatMap(URL.init(string:)))
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(query.first { $0.name == "item" }?.value, index == 0 ? "first" : "second")
            XCTAssertEqual(query.first { $0.name == "attachment" }?.value, "same-id")
            _ = try await surface.handleConversationAction(index == 0 ? "openAttachment" : "downloadAttachment", ["attachment": ["id": id]])
        }
        XCTAssertEqual(opened.map(\.0), ["first", "second"])
        XCTAssertEqual(opened.map(\.1), ["same-id", "same-id"])
        XCTAssertEqual(opened.map(\.2), [false, true])
        var removed = snapshot
        removed.revision = 2; removed.items.removeFirst()
        surface.render(removed)
        do {
            _ = try await surface.handleConversationAction("loadAttachment", ["attachmentId": ids[0]])
            XCTFail("A scoped ID must stop resolving when its message is no longer retained")
        } catch {}
    }

    func testOnlyRendererEntryMayBecomeThePrivilegedMainDocument() throws {
        XCTAssertTrue(AgentConversationWebView.isRendererEntryURL(try XCTUnwrap(URL(string: "tab-conversation://bundle/index.html#answer"))))
        for value in ["tab-conversation://bundle/assets/uploaded.html", "tab-conversation://bundle/__asset/user-html", "tab-conversation://resource/opaque", "https://example.com/index.html"] {
            XCTAssertFalse(AgentConversationWebView.isRendererEntryURL(try XCTUnwrap(URL(string: value))))
        }
    }

    func testWorkspaceAssetURLsRefetchOwnedBytesAfterCacheEvictionAndResetOnNewSession() async throws {
        let host = AgentConversationWebView(bundleRoot: nil)
        defer { host.dispose() }
        let theme = AppTheme(systemIsDark: false)
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex, status: .idle, revision: 1, items: [])
        host.update(snapshot, theme: theme, cwd: "/workspace")
        var urls: [URL] = []
        var reloads = 0
        let count = 9 * 1024 * 1024
        for index in 0..<8 {
            let byte = UInt8(index)
            urls.append(try host.registerAsset(data: Data(repeating: byte, count: count), mimeType: "application/octet-stream") {
                reloads += 1
                return Data(repeating: byte, count: count)
            })
        }
        let first = try await host.registeredAssetData(urls[0])
        XCTAssertEqual(first.count, count)
        XCTAssertEqual(first.first, 0)
        XCTAssertEqual(reloads, 1, "An evicted URL must retain its project-owned loader instead of becoming a permanent 404")
        var scopeFailure: String?
        host.onFailure = { scopeFailure = $0 }
        snapshot.session = SessionId()
        host.update(snapshot, theme: theme, cwd: "/other-workspace")
        XCTAssertNotNil(scopeFailure, "A new session cannot inherit the previous host's native delegates")
        XCTAssertFalse(host.isReady)
        XCTAssertTrue(host.webView.isHidden)
        do {
            _ = try await host.registeredAssetData(urls[0])
            XCTFail("A previous conversation's opaque resource must lose its ownership on session change")
        } catch {}
    }

    func testApprovalActionsRetainExactPendingProviderIdentityAndRejectStaleRequests() async throws {
        let surface = AgentPaneView()
        defer { surface.disposeConversation() }
        let session = SessionId(), project = ProjectId()
        var decisions: [(String, Bool)] = []
        surface.onConversationApproval = { decisions.append(($0, $1)) }
        let items = [AgentChatItem(id: "approval:one", kind: .approval, text: "First", isComplete: false),
                     .init(id: "plain-two", kind: .approval, text: "Second", isComplete: false)]
        surface.render(.init(session: session, project: project, provider: .claude, status: .waiting, revision: 1, items: items))
        _ = try await surface.handleConversationAction("approve", ["requestId": "one", "allow": true])
        _ = try await surface.handleConversationAction("approve", ["requestId": "plain-two", "allow": false])
        XCTAssertEqual(decisions.map(\.0), ["approval:one", "plain-two"])
        XCTAssertEqual(decisions.map(\.1), [true, false])
        var resolved = items
        resolved[0].isComplete = true
        surface.render(.init(session: session, project: project, provider: .claude, status: .working, revision: 2, items: resolved))
        do {
            _ = try await surface.handleConversationAction("approve", ["requestId": "approval:one", "allow": true])
            XCTFail("A resolved approval must not be acknowledged or sent again")
        } catch {}
        XCTAssertEqual(decisions.count, 2)
        do {
            _ = try await surface.handleConversationAction("approve", ["requestId": "plain-two", "allow": true, "decision": "acceptForSession"])
            XCTFail("One-time native approval must not silently impersonate session-wide approval")
        } catch {}
        XCTAssertEqual(decisions.count, 2)
    }

    func testSlowActionCannotResolveAReusedRequestIDAfterActualPageReload() async throws {
        _ = NSApplication.shared
        let root = try XCTUnwrap(AgentConversationWebView.bundleRoot, "The shipped conversation renderer must be bundled")
        let host = AgentConversationWebView(bundleRoot: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var releaseOld: (() -> Void)?
        var readyCount = 0
        host.onReady = { readyCount += 1 }
        defer { releaseOld?(); host.dispose(); window.close() }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400); host.layoutSubtreeIfNeeded()
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex,
            status: .idle, revision: 1, items: [.init(id: "answer", kind: .assistant, text: "First")])
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false)
        host.update(snapshot, theme: theme, cwd: nil)
        for _ in 0..<1000 where !host.isReady || host.lastDeliveredRevision != 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(host.isReady)
        guard host.isReady else { return }
        host.onAction = { _, payload in
            if payload["label"] as? String == "old" {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    releaseOld = { continuation.resume() }
                }
                return "old"
            }
            return "new"
        }
        _ = try await host.evaluate("window.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'action',requestId:'1',action:{kind:'copy',label:'old'}})")
        for _ in 0..<500 where releaseOld == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(releaseOld)
        snapshot.revision = 2; snapshot.items[0].text = "Retained latest snapshot"
        host.update(snapshot, theme: theme, cwd: nil)
        let originalReadyCount = readyCount
        host.webView.reload()
        for _ in 0..<1000 {
            let current = try? await host.evaluate("return window.TabConversation?.snapshot?.revision ?? null")
            if readyCount > originalReadyCount, host.isReady, host.lastDeliveredRevision == 2, (current as? Int) == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(readyCount, originalReadyCount)
        XCTAssertEqual(host.lastDeliveredRevision, 2)
        _ = try await host.evaluate("window.__testReplies=[];window.TabConversation.resolve=(reply)=>window.__testReplies.push(reply);window.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'action',requestId:'1',action:{kind:'copy',label:'new'}})")
        releaseOld?(); releaseOld = nil
        var replies: [[String: Any]] = []
        for _ in 0..<500 {
            replies = (try await host.evaluate("return window.__testReplies")) as? [[String: Any]] ?? []
            if !replies.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?["result"] as? String, "new")
        XCTAssertEqual(replies.first?["requestId"] as? String, "1")
        let visible = try await host.evaluate("return document.body.innerText") as? String
        XCTAssertTrue(visible?.contains("Retained latest snapshot") == true)
        let beforeTimeout = Date()
        do {
            _ = try await host.evaluate("return new Promise(()=>{})", timeout: .milliseconds(50))
            XCTFail("A suspended WebKit Promise must have a bounded native continuation")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(beforeTimeout), 2)
        let pending = Task { try await host.evaluate("return new Promise(()=>{})") }
        await Task.yield()
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancellation must finish a pending evaluation") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
    }

    func testActualFullTimelineKeepsFoldGroupDisclosureAndScrollAcrossSnapshotUpdates() async throws {
        _ = NSApplication.shared
        let root = try XCTUnwrap(AgentConversationWebView.bundleRoot, "The shipped conversation renderer must be bundled")
        let host = AgentConversationWebView(bundleRoot: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { host.dispose(); window.close() }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 900); host.layoutSubtreeIfNeeded()
        let start = Date(timeIntervalSince1970: 1_793_448_000)
        var items = [AgentChatItem(id: "prompt", kind: .user, text: "Inspect the project", createdAt: start)]
        for index in 0..<40 {
            items.append(.init(id: "tool-\(index)", kind: .tool, text: "Command", tool: .init(category: .command,
                input: "echo item-\(index)", output: "Recorded output \(index)", status: .completed,
                startedAt: start.addingTimeInterval(1 + Double(index)), completedAt: start.addingTimeInterval(2 + Double(index)), exitCode: 0, presentation: .command)))
        }
        items.append(.init(id: "answer", kind: .assistant, text: "Final answer", createdAt: start.addingTimeInterval(65)))
        let turn = AgentChatTurn(userItemID: "prompt", startedAt: start, completedAt: start.addingTimeInterval(65), status: .idle, outcome: .completed)
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex, turns: [turn], status: .idle, revision: 1, items: items)
        var failure: String?
        host.onFailure = { failure = $0 }
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false)
        host.update(snapshot, theme: theme, cwd: "/workspace")
        for _ in 0..<1500 where !host.isReady && failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(failure); XCTAssertTrue(host.supportsFullTimeline)
        guard host.isReady else { return }
        var folded = false
        for _ in 0..<1000 {
            folded = (try await host.evaluate("const button=[...document.querySelectorAll('button')].find(button=>button.textContent.includes('Worked for'));if(button){button.click();return true;}return false")) as? Bool ?? false
            if folded { break }
            if failure != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(folded, failure ?? "The source turn fold must render")
        var opened = false
        for _ in 0..<1000 {
            opened = (try await host.evaluate("const button=[...document.querySelectorAll('button')].find(button=>button.textContent.includes('Ran 40 commands'));if(button){button.click();return true;}return false")) as? Bool ?? false
            if opened { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(opened)
        var geometry: [String: Any] = [:]
        for _ in 0..<1000 {
            geometry = (try await host.evaluate("const group=document.querySelector('[data-tool-group-scroll]');return group?{height:group.clientHeight,content:group.scrollHeight}:{}")) as? [String: Any] ?? [:]
            if (geometry["height"] as? Double ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertLessThanOrEqual(geometry["height"] as? Double ?? 0, 288)
        XCTAssertGreaterThan(geometry["content"] as? Double ?? 0, 800)
        _ = try await host.evaluate("const group=document.querySelector('[data-tool-group-scroll]');group.scrollTop=0;group.dispatchEvent(new Event('scroll'))")
        var clicked = false
        for _ in 0..<500 {
            clicked = (try await host.evaluate("const row=document.querySelector('[data-tool-group-scroll] [data-v2-item-type=\"command_execution\"][role=button]');if(row){window.__openedToolName=row.getAttribute('aria-label')??row.textContent;row.click();return true;}return false")) as? Bool ?? false
            if clicked { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let clickedName = try await host.evaluate("return window.__openedToolName ?? JSON.stringify([...document.querySelectorAll('[data-tool-group-scroll] [data-v2-item-type]')].map(row=>({type:row.getAttribute('data-v2-item-type'),role:row.getAttribute('role'),label:row.getAttribute('aria-label'),text:row.textContent})))") as? String ?? ""
        XCTAssertTrue(clicked, "Source virtualized child disclosures: " + clickedName)
        XCTAssertTrue(clickedName.contains("item-0"), "The actual source accessible label identifies the first command: " + clickedName)
        var expanded = false
        for _ in 0..<500 {
            expanded = (try await host.evaluate("return document.body.textContent.includes('Recorded output 0')")) as? Bool ?? false
            if expanded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let detailText = try await host.evaluate("return document.body.innerText") as? String ?? ""
        XCTAssertTrue(expanded, "Source body: " + String(detailText.suffix(3000)) + " diagnostics: " + host.renderDiagnostics.joined(separator: "; "))
        _ = try await host.evaluate("const group=document.querySelector('[data-tool-group-scroll]');group.scrollTop=120;group.dispatchEvent(new Event('scroll'))")
        // Scroll events may be delivered after a programmatic assignment. Wait for
        // the observable value without awaiting rAF, which pauses in occluded WK views.
        for _ in 0..<100 {
            let top = try await host.evaluate("return document.querySelector('[data-tool-group-scroll]')?.scrollTop") as? Double ?? -1
            if abs(top - 120) < 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        snapshot.revision = 2
        snapshot.items[snapshot.items.count - 1].text = "Final answer updated"
        host.update(snapshot, theme: theme, cwd: "/workspace")
        for _ in 0..<500 where host.lastDeliveredRevision != 2 { try await Task.sleep(for: .milliseconds(10)) }
        let retained = try await host.evaluate("const group=document.querySelector('[data-tool-group-scroll]');return {top:group?.scrollTop,open:!!group,fold:[...document.querySelectorAll('button')].some(button=>button.textContent.includes('Worked for')&&button.getAttribute('aria-expanded')==='true')}") as? [String: Any]
        XCTAssertEqual(retained?["open"] as? Bool, true)
        XCTAssertEqual(retained?["fold"] as? Bool, true)
        XCTAssertEqual(retained?["top"] as? Double ?? -1, 120, accuracy: 2)
        XCTAssertNil(failure)
    }

    func testActualOfflineConversationBundleRendersMathDiagramAndSyntaxInWKWebView() async throws {
        _ = NSApplication.shared
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["TAB_CONVERSATION_TEST_BUNDLE"]
            .map { URL(fileURLWithPath: $0) } ?? AgentConversationWebView.bundleRoot,
            "The shipped conversation renderer must be bundled")
        let host = AgentConversationWebView(bundleRoot: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { host.dispose(); window.close() }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        host.layoutSubtreeIfNeeded()
        var failure: String?
        host.onFailure = { failure = $0 }
        let source = """
        # Offline source renderer

        Inline math $x^2 + y^2 = z^2$.

        ```swift
        let value = "native bridge"
        ```

        ```mermaid
        graph TD
          A[Native] --> B[Conversation source]
        ```
        """
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude,
            status: .idle, revision: 1, items: [.init(id: "assistant", kind: .assistant, text: source)])
        host.update(snapshot, theme: AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false), cwd: nil)
        for _ in 0..<1500 where !host.isReady && failure == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(failure)
        XCTAssertTrue(host.isReady, "The actual bundled page must boot through its custom scheme")
        guard host.isReady else { return }
        for _ in 0..<500 where host.lastDeliveredRevision != 1 { try await Task.sleep(for: .milliseconds(10)) }
        // The renderer defaults math rendering off. Exercise the actual source setting,
        // rather than changing the port's default merely to satisfy the fixture.
        var fixturePayload = try AgentConversationWebView.payload(snapshot, theme: "light", cwd: nil)
        fixturePayload["settings"] = ["mathRenderingEnabled": true]
        _ = try await host.evaluate("window.TabConversation.update(snapshot)", arguments: ["snapshot": fixturePayload])
        var state: [String: Any] = [:]
        for _ in 0..<1500 {
            state = (try await host.evaluate("return {math:document.querySelectorAll('.katex').length,diagram:document.querySelectorAll('[data-markdown-mermaid] svg').length,syntax:document.querySelectorAll('.chat-markdown-shiki span[style]').length,fonts:document.fonts.status,text:document.body.innerText}", arguments: [:])) as? [String: Any] ?? [:]
            if (state["math"] as? Int ?? 0) > 0 && (state["diagram"] as? Int ?? 0) > 0 && (state["syntax"] as? Int ?? 0) > 0 && state["fonts"] as? String == "loaded" { break }
            if failure != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(failure)
        XCTAssertGreaterThan(state["math"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(state["diagram"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(state["syntax"] as? Int ?? 0, 0)
        XCTAssertEqual(state["fonts"] as? String, "loaded")
        XCTAssertTrue((state["text"] as? String)?.contains("Offline source renderer") == true)
        XCTAssertEqual(host.lastDeliveredRevision, 1)
        if let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let image = try await host.webView.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("conversation-wk-smoke.png"))
            }
        }
    }
    func testFullPaneModalOwnsHitTestingFocusAndNativeSendBoundary() async throws {
        _ = NSApplication.shared
        let session = SessionId(), project = ProjectId()
        var sends = 0
        var rejectSend = false
        var rejectRead = false
        let snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude,
            status: .idle, revision: 1, items: [.init(id: "answer", kind: .assistant, text: "Ready")])
        let pane = AgentPaneController(session: session, project: project, provider: .claude) { request in
            if case .send = request {
                sends += 1
                if rejectSend { throw ModelError("Fixture send rejected") }
            }
            if case .read = request, rejectRead { throw ModelError("Fixture offline") }
            return snapshot
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { pane.dispose(); window.close() }
        window.contentView = pane.view
        pane.view.frame = NSRect(x: 0, y: 0, width: 680, height: 700)
        pane.refresh()
        for _ in 0..<1000 where !pane.surface.usesWebConversation { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(pane.surface.usesWebConversation)
        guard pane.surface.usesWebConversation else { return }
        pane.view.layoutSubtreeIfNeeded()
        let host = pane.surface.conversationWebView
        guard host.supportsFullPaneComposition else {
            XCTAssertLessThan(host.frame.height, pane.view.bounds.height)
            throw XCTSkip("This renderer/runtime lacks the negotiated full-pane capability; body-only layout remains usable")
        }
        func bridge(_ script: String, operation: String) async throws {
            do { _ = try await host.evaluate(script) }
            catch { throw ModelError("\(operation): \(String(reflecting: type(of: error))) \(error)") }
        }
        XCTAssertEqual(host.frame, pane.view.bounds)
        try await bridge("window.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'ready',features:{fullTimeline:true,renderedHandshake:true,nativeViewport:false}})", operation: "negotiate legacy body viewport")
        for _ in 0..<200 where host.supportsNativeViewport { try await Task.sleep(for: .milliseconds(10)) }
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertLessThan(host.frame.height, pane.view.bounds.height, "An older renderer must stay above the composer even when WebKit itself is transparent")
        try await bridge("window.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'ready',features:{fullTimeline:true,renderedHandshake:true,nativeViewport:true}})", operation: "restore negotiated full-pane viewport")
        for _ in 0..<200 where !host.supportsNativeViewport { try await Task.sleep(for: .milliseconds(10)) }
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.frame, pane.view.bounds)
        let composer = pane.surface.composerScroll.convert(pane.surface.composerScroll.bounds, to: pane.view)
        let point = NSPoint(x: composer.midX, y: composer.midY)
        XCTAssertNil(host.hitTest(point), "Transparent composer footprint must route native editing to AppKit")
        _ = window.makeFirstResponder(pane.surface.composer)
        pane.surface.composer.string = "Do not send behind a modal"
        try await bridge("window.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'overlays',modal:true,rects:[{x:0,y:0,width:680,height:700}]})", operation: "open source modal")
        for _ in 0..<200 where !host.isModal { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(pane.surface.isConversationModal)
        XCTAssertNotNil(host.hitTest(point))
        XCTAssertFalse(pane.surface.composer.isEditable)
        XCTAssertFalse(pane.surface.send.isEnabled)
        pane.send()
        pane.focusContent()
        XCTAssertEqual(sends, 0, "Direct menu/keyboard sends must also be blocked by the source modal")
        XCTAssertFalse(window.firstResponder === pane.surface.composer)
        try await bridge("window.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'overlays',modal:false,rects:[]})", operation: "close source modal")
        for _ in 0..<200 where host.isModal { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(pane.surface.composer.isEditable)
        XCTAssertTrue(window.firstResponder === pane.surface.composer)
        XCTAssertNil(host.hitTest(point))
        rejectSend = true
        pane.send()
        for _ in 0..<200 where pane.errorMessage == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(sends, 1)
        XCTAssertTrue(pane.surface.feedback.stringValue.contains("Fixture send rejected"))
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(pane.surface.feedback.isHidden, "Failed sends without provider items remain visible below the source canvas")
        XCTAssertEqual(pane.surface.composer.string, "Do not send behind a modal")
        rejectRead = true
        pane.connectionChanged()
        XCTAssertEqual(host.connectionState, "cached")
        for _ in 0..<200 where pane.errorMessage?.contains("Fixture offline") != true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(pane.surface.feedback.stringValue.contains("Fixture offline"))
        XCTAssertTrue(pane.surface.usesWebConversation, "An offline transport does not discard the retained source transcript")

        let document = try XCTUnwrap(pane.surface.transcriptScroll.documentView as? AgentTranscriptDocument)
        let measurements = document.measurementCount
        let nativeEntries = document.entryCount
        var latest = snapshot
        latest.revision = 2
        latest.items += (0..<60).map { .init(id: "latest-\($0)", kind: .assistant, text: "Retained latest answer \($0)") }
        pane.surface.render(latest)
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(document.measurementCount, measurements, "Active source rendering must not lay out a hidden duplicate transcript")
        XCTAssertEqual(document.entryCount, nativeEntries)
        // This script intentionally resets the renderer. Do not register an
        // awaited evaluation that resetPage must immediately cancel.
        host.webView.callAsyncJavaScript("window.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'scroll',isAtBottom:false});window.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'anchor',messageId:'latest-30',offset:12});window.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'error',message:'Fixture renderer failure'})", arguments: [:], in: nil, in: .page) { _ in }
        for _ in 0..<200 where pane.surface.usesWebConversation { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(pane.surface.usesWebConversation)
        XCTAssertEqual(pane.surface.conversationRendererFailure, "Fixture renderer failure")
        XCTAssertEqual(document.entryCount, latest.items.count, "Fallback must materialize the latest retained snapshot")
        let restored = document.captureAnchor(at: pane.surface.transcriptScroll.contentView.bounds.minY)
        XCTAssertEqual(restored.rowID, "latest-30", "Fallback restores source row identity rather than copying incompatible renderer pixels")
        XCTAssertFalse(host.isReady)
        XCTAssertTrue(window.makeFirstResponder(pane.surface.composer))
        var staleAnchors = 0
        let forwardAnchor = host.onAnchor
        host.onAnchor = { anchor in staleAnchors += 1; forwardAnchor?(anchor) }
        // The failed page can still drain queued DOM observer messages. They
        // must not steal focus or alter native fallback reading/follow state.
        _ = try await host.evaluate("window.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'overlays',modal:true,rects:[{x:0,y:0,width:680,height:700}]});window.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'scroll',isAtBottom:true});window.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'anchor',messageId:'latest-50',offset:12})")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(host.isModal)
        XCTAssertFalse(host.isAtBottom)
        XCTAssertEqual(staleAnchors, 0)
        XCTAssertTrue(window.firstResponder === pane.surface.composer)
        latest.revision = 3
        latest.items.append(.init(id: "latest-60", kind: .assistant, text: "A later native fallback update"))
        pane.surface.render(latest)
        let stillReading = document.captureAnchor(at: pane.surface.transcriptScroll.contentView.bounds.minY)
        XCTAssertEqual(stillReading.rowID, "latest-30", "Old source scroll state must not pull fallback updates to the end")
    }

    func testActualWKFetchesOwnedAttachmentAndRangedWorkspaceURLs() async throws {
        _ = NSApplication.shared
        let host = AgentConversationWebView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { host.dispose(); window.close() }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 700); host.layoutSubtreeIfNeeded()
        let bytes = Data((0..<600_000).map { UInt8($0 % 251) })
        let attachment = AgentChatAttachmentDescriptor(id: "image", name: "payload.bin", mimeType: "application/octet-stream", byteCount: bytes.count)
        host.fetchAttachment = { item, descriptor in
            guard item == "owner", descriptor.id == "image" else { throw ModelError("Wrong attachment owner") }
            return bytes
        }
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex, status: .idle, revision: 1,
            items: [.init(id: "owner", kind: .user, text: "Owned attachment", attachments: [attachment])])
        host.update(snapshot, theme: AppTheme(systemIsDark: false), cwd: nil)
        for _ in 0..<1000 where !host.isReady { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(host.isReady)
        guard host.isReady else { return }
        var reads = 0
        let url = try host.registerRangedAsset(length: UInt64(bytes.count), mimeType: "application/octet-stream", revision: "fixture-v1", identity: "workspace.bin") { offset, count in
            reads += 1
            return bytes.subdata(in: Int(offset)..<Int(offset) + Int(count))
        }
        let duplicate = try host.registerRangedAsset(length: UInt64(bytes.count), mimeType: "application/octet-stream", revision: "fixture-v1", identity: "workspace.bin") { _, _ in XCTFail("Same identity+revision retains its original scoped reader"); return Data() }
        XCTAssertEqual(url, duplicate)
        for _ in 0..<100 {
            _ = try host.registerRangedAsset(length: UInt64(bytes.count), mimeType: "application/octet-stream", revision: "fixture-v1", identity: "workspace.bin") { _, _ in Data() }
        }
        XCTAssertEqual(host.retainedAssetDescriptorCount, 1, "Repeated source asset resolution must not retain new native readers")
        let attachmentURL = try XCTUnwrap(AgentConversationWebView.attachmentURL(item: "owner", attachment: "image"))
        let full = try await host.evaluate("const response=await fetch(url);const blob=await response.blob();const bytes=new Uint8Array(await blob.arrayBuffer());return {status:response.status,size:blob.size,first:bytes[0],last:bytes.at(-1)}", arguments: ["url": attachmentURL.absoluteString]) as? [String: Any]
        XCTAssertEqual(full?["size"] as? Int, bytes.count)
        XCTAssertEqual(full?["first"] as? Int, Int(bytes[0]))
        XCTAssertEqual(full?["last"] as? Int, Int(bytes.last!))
        let partial = try await host.evaluate("const response=await fetch(url,{headers:{Range:'bytes=260000-530000'}});const blob=await response.blob();const bytes=new Uint8Array(await blob.arrayBuffer());return {status:response.status,size:blob.size,range:response.headers.get('Content-Range'),first:bytes[0],last:bytes.at(-1)}", arguments: ["url": url.absoluteString]) as? [String: Any]
        XCTAssertEqual(partial?["status"] as? Int, 206)
        XCTAssertEqual(partial?["size"] as? Int, 270001)
        XCTAssertEqual(partial?["range"] as? String, "bytes 260000-530000/600000")
        XCTAssertEqual(partial?["first"] as? Int, Int(bytes[260000]))
        XCTAssertEqual(partial?["last"] as? Int, Int(bytes[530000]))
        XCTAssertEqual(reads, 2)
        var privilegedCalls = 0
        host.onAction = { _, _ in privilegedCalls += 1; return true }
        _ = try await host.evaluate("window.__rawScriptRan=false;window.addEventListener('message',event=>{if(event.data?.fixture==='raw-script-ran')window.__rawScriptRan=true;})")
        let hostile = Data("<html><script>parent.postMessage({fixture:'raw-script-ran'},'*');parent.__hostileExecuted=true;parent.webkit.messageHandlers.tabConversation.postMessage({bridgeVersion:1,type:'action',requestId:'hostile',action:{kind:'copy',text:'untrusted'}})</script></html>".utf8)
        let hostileURL = try host.registerAsset(data: hostile, mimeType: "text/html")
        XCTAssertFalse(AgentConversationWebView.isRendererEntryURL(hostileURL))
        let inertState = try await host.evaluate("return new Promise(resolve=>{const frame=document.createElement('iframe');frame.onload=()=>{let opaque=false;try{void frame.contentWindow.document}catch{opaque=true}resolve({loaded:true,opaque})};frame.src=url;document.body.append(frame);setTimeout(()=>resolve({timeout:true}),2000)})", arguments: ["url": hostileURL.absoluteString], timeout: .seconds(3)) as? [String: Any]
        XCTAssertEqual(inertState?["loaded"] as? Bool, true)
        XCTAssertEqual(inertState?["opaque"] as? Bool, true, "The owned document must actually load into the HTTP sandbox; cancelled navigation is not proof of inert HTML")
        try await Task.sleep(for: .milliseconds(100))
        let executed = try await host.evaluate("return window.__hostileExecuted === true") as? Bool
        XCTAssertFalse(executed ?? true, "Owned HTML bytes may be fetched but must remain inert when embedded")
        let rawScriptRan = try await host.evaluate("return window.__rawScriptRan === true") as? Bool
        XCTAssertEqual(rawScriptRan, false, "Opaque origin alone is insufficient: ordinary owned HTML must not execute even a postMessage marker")
        XCTAssertEqual(privilegedCalls, 0, "Untrusted asset subframes cannot invoke privileged main-frame actions")
    }

}
