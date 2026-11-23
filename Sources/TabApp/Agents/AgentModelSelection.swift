import TabProtocol

/// A provider-owned model ID. Friendly labels and capabilities come from its catalog.
struct AgentModelSelection: Equatable {
    var provider: AgentChatProvider
    /// The server's provider of `provider`'s kind; nil is the kind's built-in one.
    var providerID: String?
    var model: String?

    init(provider: AgentChatProvider, providerID: String? = nil, model: String?) {
        self.provider = provider
        self.providerID = providerID == provider.rawValue ? nil : providerID
        self.model = model
    }

    /// The provider's ID, a built-in one's being its kind's name.
    var providerKey: String { providerID ?? provider.rawValue }

    var title: String {
        guard let model else { return provider.name }
        return model
    }
}
