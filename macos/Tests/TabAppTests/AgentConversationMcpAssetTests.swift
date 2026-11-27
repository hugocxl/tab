import AppKit
import TabCore
import TabProtocol
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

    func testHTMLDocumentIsServedOnlyWhileItsToolCallIsRetained() async throws {
        let surface = AgentPaneView()
        let html = #"<!doctype html><html><body><script>document.body.textContent='Retained MCP'</script></body></html>"#
        let bytes = Data(html.utf8)
        var item = tool(output)
        item.attachments?[0].byteCount = bytes.count
        var fetched: [String] = []
        surface.fetchAttachment = { owner, descriptor in
            fetched.append(owner + "/" + descriptor.id)
            return bytes
        }
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex, status: .idle, revision: 1, items: [item])
        surface.render(snapshot)
        let document = try await surface.actions.htmlDocument(attachmentID: "html")
        XCTAssertEqual(document.data, bytes)
        XCTAssertFalse(document.match.publishedHTML)
        XCTAssertEqual(fetched, ["tool/html"])

        snapshot.revision = 2; snapshot.items.removeAll(); surface.render(snapshot)
        do {
            _ = try await surface.actions.htmlDocument(attachmentID: "html")
            XCTFail("A document must lose ownership when its tool leaves retained history")
        } catch {}

        var mismatched = item
        mismatched.attachments?[0].byteCount = bytes.count + 1
        snapshot.revision = 3; snapshot.items = [mismatched]; surface.render(snapshot)
        do {
            _ = try await surface.actions.htmlDocument(attachmentID: "html")
            XCTFail("Bytes that differ from the retained descriptor must be rejected")
        } catch {}

        let htmlOutput = #"{"htmlRender":{"attachmentId":"html","title":"Supplied published HTML","height":320}}"#
        var published = tool(htmlOutput, name: "html_render")
        published.attachments?[0].byteCount = bytes.count
        snapshot.revision = 4; snapshot.items = [published]; surface.render(snapshot)
        let rendered = try await surface.actions.htmlDocument(attachmentID: "html")
        XCTAssertEqual(rendered.data, bytes, "Published html_render bytes are served verbatim")
        XCTAssertTrue(rendered.match.publishedHTML)
    }

    func testDocumentReferenceUsesTheSameOwnershipChecksAsTheMatcher() {
        XCTAssertNotNil(AgentHtmlDocumentReference.find(in: tool(output)))
        XCTAssertNil(AgentHtmlDocumentReference.find(in: tool(output, name: "other.show")))
        XCTAssertNil(AgentHtmlDocumentReference.find(in: tool(output, htmlID: "missing")))
        XCTAssertNil(AgentHtmlDocumentReference.find(in: tool(String(repeating: " ", count: 16385) + output)))
    }

    func testHtmlRenderCandidateNeedsAnOwnedHTMLAttachment() {
        let render = #"{"htmlRender":{"attachmentId":"html"}}"#
        XCTAssertEqual(AgentConversationMcpAsset.htmlRenderCandidates(attachmentID: "html", items: [tool(render, name: "html_render")]).count, 1)
        XCTAssertTrue(AgentConversationMcpAsset.htmlRenderCandidates(attachmentID: "html", items: [tool(render, htmlID: "other")]).isEmpty)
        XCTAssertTrue(AgentConversationMcpAsset.htmlRenderCandidates(attachmentID: "other", items: [tool(render)]).isEmpty)
    }
}
