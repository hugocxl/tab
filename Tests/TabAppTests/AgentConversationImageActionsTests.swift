import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationImageActionsTests: XCTestCase {
    func testActualWKOwnedImageFetchCopyAndSourceBlobSave() async throws {
        _ = NSApplication.shared
        let root = try XCTUnwrap(AgentConversationWebView.bundleRoot, "The shipped conversation renderer must be bundled")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = AgentConversationClipboardTransfer(pasteboard: board)
        let host = AgentConversationWebView(bundleRoot: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1_100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 1_100); host.layoutSubtreeIfNeeded()
        defer { clipboard.cancel(); host.dispose(); window.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tab-source-images-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var finished: [URL] = [], actionErrors: [String] = [], phases: [String] = []
        host.downloads.chooseDestination = { name in directory.appendingPathComponent(name) }
        host.downloads.onFinished = { finished.append($0) }
        host.downloads.onFailure = { actionErrors.append($0.localizedDescription) }
        host.onActionFailure = { actionErrors.append($0.localizedDescription) }
        host.onFailure = { actionErrors.append($0) }
        host.connectionState = "live"
        host.capabilities = ["nativeActions": true, "filesystem": true, "preview": true, "openAttachment": true, "downloadAttachment": true]
        host.fetchAttachment = { item, descriptor in XCTAssertEqual(item, "user"); XCTAssertEqual(descriptor.id, "image"); return png }
        let attachmentURL = try XCTUnwrap(AgentConversationWebView.attachmentURL(item: "user", attachment: "image"))
        let workspaceURL = try host.registerRangedAsset(length: UInt64(png.count), mimeType: "image/png", revision: "image", identity: "pixel.png", read: { offset, length in
            png.subdata(in: Int(offset)..<Int(offset) + Int(length))
        })
        host.onAction = { kind, payload in
            if kind == "copy" { if let phase = payload["phase"] as? String { phases.append(phase) }; return try clipboard.handle(payload) }
            if kind == "createAssetUrl" {
                let input = payload["input"] as? [String: Any] ?? payload
                let resource = input["resource"] as? [String: Any] ?? [:]
                let url = resource["_tag"] as? String == "attachment" ? attachmentURL : workspaceURL
                return ["relativeUrl": url.absoluteString, "expiresAt": Date().addingTimeInterval(600).timeIntervalSince1970 * 1000]
            }
            if kind == "filesystemMetadata" { return ["entries": [["kind": "file", "byteLength": png.count, "mimeType": "image/png"]]] }
            throw NSError(domain: "Unexpected image fixture action: " + kind, code: 1)
        }
        let project = ProjectId(), session = SessionId()
        host.update(.init(session: session, project: project, provider: .codex, status: .idle, revision: 1,
                          items: [.init(id: "user", kind: .user, text: "See attached", attachments: [.init(id: "image", name: "attached.png", mimeType: "image/png", byteCount: png.count)]),
                                  .init(id: "answer", kind: .assistant, text: "![Workspace image](/workspace/pixel.png)", isComplete: true)]),
                    theme: AppTheme(systemIsDark: false), cwd: "/workspace")
        guard await wait(host, "return !!document.querySelector('img[alt=\"attached.png\"]') && !!document.querySelector('img[alt=\"Workspace image\"]')") else { return }
        for (name, url) in [("attached.png", attachmentURL), ("Workspace image", workspaceURL)] {
            let fetched = try await host.evaluate("const response=await fetch(url);const blob=await response.blob();return {status:response.status,size:blob.size,mime:blob.type};", arguments: ["url": url.absoluteString]) as? [String: Any]
            XCTAssertEqual(fetched?["status"] as? Int, 200)
            XCTAssertEqual(fetched?["size"] as? Int, png.count)
            XCTAssertEqual(fetched?["mime"] as? String, "image/png")
            _ = try await host.evaluate("Array.from(document.images).find(image=>image.alt===name).click();return true", arguments: ["name": name])
            guard await wait(host, "return !!document.querySelector('[role=dialog] img')") else { return }
            for label in ["Copy image", "Save image"] {
                _ = try await host.evaluate("document.querySelector('[role=dialog] img').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,clientX:100,clientY:100}));return true")
                guard await wait(host, "return Array.from(document.querySelectorAll('[role=menuitem]')).some(item=>item.textContent.trim()===label && !item.disabled)", arguments: ["label": label]) else { return }
                let count = finished.count
                // The source deliberately gates pointer clicks behind its opening RAF.
                // Its supported Enter path is independent of that frame, including in an occluded WK fixture.
                _ = try await host.evaluate("""
                const item=Array.from(document.querySelectorAll('[role=menuitem]')).find(item=>item.textContent.trim()===label);
                if(!item||item.disabled)throw new Error('The actual source action is unavailable: '+label);
                item.focus({preventScroll:true});
                item.dispatchEvent(new KeyboardEvent('keydown',{bubbles:true,key:'Enter'}));return true;
                """, arguments: ["label": label])
                let deadline = Date().addingTimeInterval(8)
                if label == "Copy image" {
                    while board.data(forType: .png) != png, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
                    XCTAssertEqual(board.data(forType: .png), png, "\(name); phases=\(phases); errors=\(actionErrors)")
                    board.clearContents()
                } else {
                    while finished.count == count, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
                    guard let saved = finished.dropFirst(count).first else { XCTFail("Actual source Save image did not reach WKDownload: \(actionErrors)"); return }
                    XCTAssertEqual(try Data(contentsOf: saved), png)
                }
            }
            _ = try await host.evaluate("document.querySelector('[aria-label=\"Close image preview\"]').click();return true")
            guard await wait(host, "return !document.querySelector('[aria-label=\"Close image preview\"]') && !document.querySelector('[data-slot=dialog-popup] img')") else { return }
        }
        XCTAssertEqual(phases.filter { $0 == "commit" }.count, 2)
        XCTAssertTrue(actionErrors.isEmpty, actionErrors.joined(separator: "\n"))
        XCTAssertTrue(host.renderDiagnostics.isEmpty, host.renderDiagnostics.joined(separator: "\n"))
    }

    private func wait(_ host: AgentConversationWebView, _ script: String, arguments: [String: Any] = [:]) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let value = try? await host.evaluate(script, arguments: arguments), value as? Bool == true { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let text = try? await host.evaluate("return document.body.innerText")
        XCTFail("Actual image source fixture timed out: \(script); body=\(String(describing: text)); diagnostics=\(host.renderDiagnostics)")
        return false
    }
}
