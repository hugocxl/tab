import TabProtocol

/// A provider-owned model ID. Friendly labels and capabilities come from its catalog.
struct AgentModelSelection: Equatable {
    var provider: AgentChatProvider
    var model: String?

    var title: String {
        guard let model else { return provider.name }
        return model
    }
}
