import AppKit
import TabClient
import TabCore
import TabProtocol

extension SettingsModel {
    func buildIntegrations(_ b: SettingsPageBuilder) {
        let statuses = store.agentIntegrations
        let enabled = statuses.map(AgentIntegrations.isEnabled) ?? false
        b.row("agent-integration", b.toggle("agent-integration", enabled, enabled: statuses != nil && !store.agentIntegrationBusy) { [store] in
            store.setAgentIntegration($0)
        })
        b.note("agent-integration", "Teach Claude Code, Codex, OpenCode and Pi how to use Tab.")
        b.row("agent-integration-agents", statuses.map(agentList) ?? .label("Looking for agents…", .note), stacked: true)
        if statuses?.contains(where: { $0.agent == .codex && $0.hook == .installed }) ?? false {
            b.note("agent-integration-agents", "Codex runs a new or changed hook only after you approve it: type /hooks in Codex.")
        }
        b.row("terminal-migration", migrationButtons(b), stacked: true)
    }

    private func agentList(_ statuses: [AgentIntegrationStatus]) -> SettingControl {
        .column(statuses.map { status in
            var controls: [SettingControl] = []
            if let logo = AgentLogo.image(for: Self.provider(status.agent), lightBackground: AppTheme.shared.palette.isLight) {
                controls.append(.image(logo, side: 20))
            }
            controls.append(.column([.label(status.agent.name), .label(Self.summary(status), .secondary)]))
            return .row(controls)
        })
    }

    static func provider(_ agent: CodingAgent) -> AgentProvider {
        switch agent {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .openCode
        case .pi: .pi
        }
    }

    /// One line about what Tab installed for an agent.
    static func summary(_ status: AgentIntegrationStatus) -> String {
        guard status.found else { return "Not found on this Mac" }
        guard status.isIntegrated else { return "Not set up" }
        if status.skill == .outdated || status.hook == .outdated { return "Updates when Tab next opens" }
        switch (status.skill, status.hook) {
        case (.installed, .installed): return "Skill and hooks installed"
        case (.installed, .unsupported): return "Skill installed"
        case (.installed, .missing): return "Skill installed; turn integration off and on to add the hooks"
        default: return "Hooks installed; turn integration off and on to add the skill"
        }
    }

    private func migrationButtons(_ b: SettingsPageBuilder) -> SettingControl {
        let sources = store.host?.migrationSources() ?? []
        guard !sources.isEmpty else { return .label("No other terminal's settings were found on this Mac.", .note) }
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
        let buttons = sources.map { source in
            b.button(source.name, help: "Open an agent tab with a prompt to migrate \(source.name)") { [weak self] in
                guard let self else { return }
                do {
                    try store.host?.openAgent(prompt: TerminalMigration.prompt(for: source, home: home, dirs: store.dirs))
                    window?.close()
                } catch {
                    store.setError("terminal-migration", SettingsStore.message(error))
                }
            }
        }
        return .column([
            .row(buttons),
            .label("Opens an agent tab with the prompt ready to review and send.", .note),
        ])
    }
}
