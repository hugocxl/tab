import Foundation
import XCTest
@testable import TabProtocol

final class AgentProviderSettingsTests: XCTestCase {
    func testFilesFromOtherBuildsLoadWithBothBuiltInProviders() throws {
        let json = """
        {"providers": [
            {"id": "claude-2", "kind": "claude", "name": "Work", "futureKey": 1},
            {"id": "gemini", "kind": "gemini", "enabled": true},
            {"id": "claude-2", "kind": "claude", "name": "Duplicate"},
            {"id": "codex", "kind": "codex", "enabled": false}
        ], "futureSetting": true}
        """
        let settings = try JSONDecoder().decode(AgentProviderSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.providers.map(\.id), ["claude-2", "codex", "claude"])
        XCTAssertEqual(settings.provider("claude-2")?.name, "Work")
        XCTAssertEqual(settings.provider("codex")?.enabled, false)
        XCTAssertEqual(settings.healthCheckInterval, AgentProviderSettings.defaultHealthCheckInterval)
        try settings.validate()
        XCTAssertEqual(try JSONDecoder().decode(AgentProviderSettings.self, from: Data("{}".utf8)).providers.map(\.id),
                       ["claude", "codex"])
    }

    func testAConversationFallsBackToItsKindsBuiltInProvider() {
        let settings = AgentProviderSettings(providers: [AgentProviderConfig(id: "work", kind: .codex)])
        XCTAssertEqual(settings.provider("work", kind: .codex).id, "work")
        XCTAssertEqual(settings.provider("work", kind: .claude).id, "claude", "a provider of another kind never runs it")
        XCTAssertEqual(settings.provider("removed", kind: .codex).id, "codex")
        XCTAssertEqual(settings.provider(nil, kind: .codex).id, "codex")
        XCTAssertEqual(settings.newID(.codex), "codex-2")
    }

    func testModelsArrangeFavoritesThenTheUsersOrderAndHideOnlyFromTheMenu() {
        let reported = ["a", "b", "c", "d"].map { AgentModelDescriptor(id: $0, title: $0.uppercased(), reasoningEfforts: []) }
        let models = AgentProviderModels(favorites: ["c"], hidden: ["b", "custom"], order: ["d", "b"],
                                         custom: [AgentCustomModel(id: "custom"), AgentCustomModel(id: "a")])
        XCTAssertEqual(models.arrange(reported).map(\.id), ["c", "d", "b", "a", "custom"])
        XCTAssertEqual(models.visible(reported).map(\.id), ["c", "d", "a"])
        XCTAssertEqual(models.arrange(reported).first { $0.id == "a" }?.title, "A", "a custom ID the CLI reports keeps its details")
    }

    func testValidationRefusesWhatACLICantTake() {
        func refuses(_ change: (inout AgentProviderConfig) -> Void) {
            var provider = AgentProviderConfig.builtIn(.claude)
            change(&provider)
            XCTAssertThrowsError(try AgentProviderSettings(providers: [provider]).validate())
        }
        refuses { $0.id = "has space" }
        refuses { $0.environment = [AgentProviderVariable(name: "A=B", value: "x")] }
        refuses { $0.home = "bad\0path" }
        refuses { $0.autoCompactTokens = 50_000 }
        var duplicate = AgentProviderSettings()
        duplicate.providers.append(.builtIn(.claude))
        XCTAssertThrowsError(try duplicate.validate())
    }

    func testPromptsAndSnapshotsFromOlderBuildsKeepTheirProvider() throws {
        let prompt = try JSONDecoder().decode(AgentPrompt.self, from: Data("""
            {"id": "\(UUID().uuidString)", "text": "hi", "provider": "codex", "planMode": false, "attachments": []}
            """.utf8))
        XCTAssertNil(prompt.providerID)
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: WireJSON.encode(snapshot)) as? [String: Any])
        object["providerID"] = nil
        let decoded = try WireJSON.decode(AgentChatSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.providerID)
    }
}
