import AppKit
import TabClient
import TabCore
import TabProtocol

extension SettingsModel {
    /// Settings › Agents' section for migrating from another terminal.
    func buildTerminalMigration(_ b: SettingsPageBuilder) {
        b.row("terminal-migration", migrationButtons(b), stacked: true)
    }

    /// One line about what Tab installed for a provider.
    static func integrationSummary(_ status: AgentIntegrationStatus) -> String {
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
