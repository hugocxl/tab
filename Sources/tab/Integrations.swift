import Foundation
import TabClient
import TabCore

/// `tab integrations`: the skill and hooks of the coding agents on this computer.
enum Integrations {
    static func run(_ action: CLIIntegrations, json: Bool) throws {
        let integrations = try AgentIntegrations.current()
        let statuses: [AgentIntegrationStatus]
        switch action {
        case .status: statuses = integrations.status()
        case .install: statuses = try integrations.install()
        case .remove: statuses = try integrations.remove()
        }
        let values = statuses.map { status -> JSONValue in
            .object([
                "agent": .string(status.agent.rawValue),
                "found": .bool(status.found),
                "skill": .string(status.skill.rawValue),
                "hook": .string(status.hook.rawValue),
            ])
        }
        Output.list(values, columns: ["agent", "found", "skill", "hook"], json: json)
        if !json, action == .install, statuses.contains(where: { $0.agent == .codex && $0.hook == .installed }) {
            Output.error("Codex runs the new hook once you approve it with /hooks.")
        }
    }
}
