import TabClient

extension SettingsModel {
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
}
