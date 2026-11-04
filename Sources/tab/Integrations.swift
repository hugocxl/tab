import Foundation
import TabClient
import TabCore

/// `tab integrations`: the skill and hooks of the coding agents on this computer.
enum Integrations {
    static func run(_ action: CLIIntegrations, json: Bool) async throws {
        switch action {
        case .context:
            let cli = Executable.currentURL()
            if let context = AgentIntegrations.context(environment: ProcessInfo.processInfo.environment, cli: cli) {
                Output.line(context)
            }
            return
        case .report(let provider, let state):
            return await AgentEventReport.send(provider: provider, state: state)
        case .status, .install, .remove:
            break
        }
        let integrations = try AgentIntegrations.current()
        let statuses: [AgentIntegrationStatus]
        switch action {
        case .install(let directories):
            statuses = try integrations.install(required: directories.isEmpty)
            for file in try AgentSkill.install(directories: directories) {
                Output.error("skill: \(file.path)")
            }
        case .remove: statuses = try integrations.remove()
        default: statuses = integrations.status()
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
        if !json, case .install = action, statuses.contains(where: { $0.agent == .codex && $0.hook == .installed }) {
            Output.error("Codex runs the new hook once you approve it with /hooks.")
        }
    }
}
