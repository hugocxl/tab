import Foundation
import TabProtocol
import XCTest

final class AgentModelCatalogTests: XCTestCase {
    func testCatalogMessagesRoundTrip() throws {
        let request = Message.request(RequestId(1), .agentModelCatalog(.init(project: ProjectId(), provider: .codex, forceRefresh: true)))
        let catalog = AgentModelCatalogReply(models: [.init(id: "future-model", title: "Future model",
            reasoningEfforts: [.max, .ultra, .init(rawValue: "future-effort")],
            defaultReasoningEffort: .ultra, resolvedModel: "future-model-v2", isDefault: true)], source: "live")
        let reply = Message.reply(RequestId(1), .agentModelCatalog(catalog))
        for message in [request, reply] {
            try message.validate()
            XCTAssertEqual(try WireJSON.decode(Message.self, from: WireJSON.encode(message)), message)
        }
    }

    func testBoundsAndControlCharactersRejectedEvenWithoutProvider() throws {
        for raw in ["", "bad\nvalue", "bad\0value", String(repeating: "x", count: 65)] {
            XCTAssertThrowsError(try AgentChatRequest.send(session: SessionId(), text: "Hi", model: nil,
                reasoningEffort: .init(rawValue: raw)).validate())
        }
        let valid = AgentModelDescriptor(id: "model", title: "Model", reasoningEfforts: [.high])
        XCTAssertThrowsError(try AgentModelCatalogReply(models: [valid, valid]).validate())
        XCTAssertThrowsError(try AgentModelCatalogReply(models: Array(repeating: valid, count: 257)).validate())
        var invalid = valid
        invalid.reasoningEfforts = [.init(rawValue: "bad\tvalue")]
        XCTAssertThrowsError(try AgentModelCatalogReply(models: [invalid]).validate())
    }

    func testOlderDescriptorWithoutOptionalMetadataDecodes() throws {
        let data = Data("""
        {"id":"model","title":"Model","reasoningEfforts":["future"]}
        """.utf8)
        let model = try WireJSON.decode(AgentModelDescriptor.self, from: data)
        XCTAssertFalse(model.isDefault)
        XCTAssertNil(model.resolvedModel)
        XCTAssertEqual(model.reasoningEfforts, [.init(rawValue: "future")])
    }

    func testLegacyRequestDefaultsToNonForcedRefresh() throws {
        let project = ProjectId()
        let data = try JSONSerialization.data(withJSONObject: ["project": project.description, "provider": "claude"])
        let request = try WireJSON.decode(AgentModelCatalogRequest.self, from: data)
        XCTAssertEqual(request.project, project)
        XCTAssertFalse(request.forceRefresh)
    }
}
