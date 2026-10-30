import TabProtocol

/// Picker presets from T3 Code's provider/model-manifest.json (2026-10-28).
/// Provider defaults and custom IDs also work with locally configured models.
struct AgentModelSelection: Equatable {
    var provider: AgentChatProvider
    var model: String?

    var title: String {
        guard let model else { return provider == .claude ? "Claude · Default" : "Codex · Default" }
        return Self.presets.first { $0.selection == self }?.title ?? model
    }

    static let presets: [(title: String, selection: AgentModelSelection)] = [
        ("Claude Opus 5.5", .init(provider: .claude, model: "claude-opus-5-5")),
        ("Claude Sonnet 5.5", .init(provider: .claude, model: "claude-sonnet-5-5")),
        ("Claude Haiku 5.5", .init(provider: .claude, model: "claude-haiku-5-5")),
        ("Claude Fable 5.1", .init(provider: .claude, model: "claude-fable-5-1")),
        ("GPT-6.1 Sol", .init(provider: .codex, model: "gpt-6.1-sol")),
        ("GPT-6 Astra", .init(provider: .codex, model: "gpt-6-astra")),
        ("GPT-6 Luna", .init(provider: .codex, model: "gpt-6-luna")),
    ]
}
