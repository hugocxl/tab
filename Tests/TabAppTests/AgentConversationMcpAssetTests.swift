import AppKit
import TabCore
import TabProtocol
import WebKit
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationMcpAssetTests: XCTestCase {
    private func tool(_ output: String, name: String = "weather.show", htmlID: String = "html") -> AgentChatItem {
        var activity = AgentToolActivity(name: name, output: output, status: .completed, presentation: .dynamicTool)
        activity.outputIsJSON = true
        return .init(id: "tool", kind: .tool, text: "weather.show", tool: activity,
            attachments: [.init(id: htmlID, name: "app.html", mimeType: "text/html", byteCount: 20)])
    }
    private let output = #"{"tabMcpApp":{"attachmentId":"html","server":"weather","tool":"show","resourceUri":"ui://weather/show","csp":{"connectDomains":["https://example.com"]}}}"#

    func testOnlyMatchingRetainedToolHTMLCanRequestSourceDocumentPreparation() throws {
        let item = tool(output)
        let legacy = output.replacingOccurrences(of: "tabMcpApp", with: "t3McpApp")
        XCTAssertNotNil(AgentConversationMcpAsset.match(attachmentID: "html", items: [tool(legacy)]),
                        "Previously retained provider documents must remain readable")
        let match = try XCTUnwrap(AgentConversationMcpAsset.match(attachmentID: "html", items: [item]))
        XCTAssertEqual(match.ownership.itemID, "tool")
        XCTAssertTrue(match.ownership.isRetained(in: ["tool": item]))
        var changed = item
        changed.tool?.output = output + " "
        XCTAssertFalse(match.ownership.isRetained(in: ["tool": changed]))
        XCTAssertNil(AgentConversationMcpAsset.match(attachmentID: "html", items: [tool(output, name: "other.show")]))
        XCTAssertNil(AgentConversationMcpAsset.match(attachmentID: "html", items: [tool(output, htmlID: "missing")]))
        var ordinary = item; ordinary.kind = .user
        XCTAssertNil(AgentConversationMcpAsset.match(attachmentID: "html", items: [ordinary]))
        ordinary = item; ordinary.attachments?[0].mimeType = "image/png"
        XCTAssertNil(AgentConversationMcpAsset.match(attachmentID: "html", items: [ordinary]))
        let wrapped = "{\"content\":[{\"type\":\"text\",\"text\":" + String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.fragmentsAllowed]), as: UTF8.self) + "}]}"
        XCTAssertNotNil(AgentConversationMcpAsset.match(attachmentID: "html", items: [tool(wrapped)]))
        XCTAssertNil(AgentConversationMcpAsset.match(attachmentID: "html", items: [tool(String(repeating: " ", count: 16385) + output)]))
    }

    func testActualWKPreparedOwnedDocumentExecutesOnlyInAnOpaqueFrame() async throws {
        _ = NSApplication.shared
        let surface = AgentPaneView()
        let host = surface.conversationWebView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { surface.disposeConversation(); window.close() }
        window.contentView = surface
        surface.frame = NSRect(x: 0, y: 0, width: 680, height: 700); surface.layoutSubtreeIfNeeded()
        let html = #"<!doctype html><html><body><script>document.body.textContent='Executable retained MCP';let blocked=false;try{parent.__mcpEscaped=true}catch{blocked=true};parent.postMessage({fixture:'mcp-executed',blocked},'*');</script></body></html>"#
        let bytes = Data(html.utf8)
        var item = tool(output)
        item.attachments?[0].byteCount = bytes.count
        surface.fetchAttachment = { owner, descriptor in
            guard owner == "tool", descriptor.id == "html" else { throw ModelError("Wrong resource owner") }
            return bytes
        }
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex, status: .idle, revision: 1, items: [item])
        surface.render(snapshot)
        for _ in 0..<1000 where !host.isReady { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(host.isReady)
        guard host.isReady else { return }
        let resource: [String: Any] = ["_tag": "attachment", "attachmentId": "html", "renderIntent": "mcp-app", "mimeType": "text/html", "disposition": "inline"]
        let result = try await surface.handleConversationAction("createAssetUrl", ["input": ["resource": resource]]) as? [String: Any]
        let url = try XCTUnwrap((result?["relativeUrl"] as? String).flatMap(URL.init(string:)))
        XCTAssertFalse(AgentConversationWebView.isRendererEntryURL(url))
        let prepared = try await host.registeredAssetData(url)
        let text = String(decoding: prepared, as: UTF8.self)
        XCTAssertTrue(text.contains("default-src 'none'"))
        XCTAssertTrue(text.contains("connect-src https://example.com"))
        let executionScript = "return await new Promise(resolve=>{const frame=document.createElement('iframe');frame.sandbox='allow-scripts allow-forms';const listener=event=>{if(event.source===frame.contentWindow&&event.data?.fixture==='mcp-executed'){window.removeEventListener('message',listener);resolve({origin:event.origin,blocked:event.data.blocked,escaped:window.__mcpEscaped===true});}};window.addEventListener('message',listener);frame.src=url;document.body.append(frame);setTimeout(()=>resolve({timeout:true}),3000);})"
        let state = try await host.evaluate(executionScript, arguments: ["url": url.absoluteString], timeout: .seconds(5)) as? [String: Any]
        XCTAssertEqual(state?["origin"] as? String, "null", "Prepared MCP execution: \(String(describing: state))")
        XCTAssertEqual(state?["blocked"] as? Bool, true)
        XCTAssertEqual(state?["escaped"] as? Bool, false)
        snapshot.revision = 2; snapshot.items.removeAll(); surface.render(snapshot)
        do { _ = try await host.registeredAssetData(url); XCTFail("Prepared documents must lose ownership when their tool leaves retained history") } catch {}
        do { _ = try await surface.handleConversationAction("createAssetUrl", ["input": ["resource": resource]]); XCTFail("A caller renderIntent cannot create an app without owned bytes") } catch {}
        let htmlOutput = #"{"htmlRender":{"attachmentId":"html","title":"Supplied published HTML","height":320}}"#
        var published = tool(htmlOutput, name: "html_render")
        published.attachments?[0].byteCount = bytes.count
        snapshot.revision = 3; snapshot.items = [published]; surface.render(snapshot)
        let htmlResource: [String: Any] = ["_tag": "attachment", "attachmentId": "html", "mimeType": "text/html", "disposition": "inline"]
        let htmlResult = try await surface.handleConversationAction("createAssetUrl", ["input": ["resource": htmlResource]]) as? [String: Any]
        let publishedURL = try XCTUnwrap((htmlResult?["relativeUrl"] as? String).flatMap(URL.init(string:)))
        let publishedBytes = try await host.registeredAssetData(publishedURL)
        XCTAssertEqual(publishedBytes, bytes, "Already published html_render bytes must not receive a second bootstrap")
        let htmlState = try await host.evaluate(executionScript, arguments: ["url": publishedURL.absoluteString], timeout: .seconds(5)) as? [String: Any]
        XCTAssertEqual(htmlState?["origin"] as? String, "null", "Published HTML execution: \(String(describing: htmlState))")
        XCTAssertEqual(htmlState?["blocked"] as? Bool, true)
    }
}
