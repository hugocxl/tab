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

/// Why a provider can't start a conversation, as its last check found: its CLI is
/// missing, too old or signed out. The model menu shows it on the provider, and the
/// composer warns when it is the chosen one.
struct AgentProviderUnavailability: Equatable {
    /// A word or two beside the provider in the menu, such as "Signed out".
    var badge: String
    /// The short line atop the provider's models.
    var reason: String
    /// The whole explanation, such as "Codex: Unavailable. Run `codex login` in a terminal to sign in."
    var detail: String
    /// The command line that signs it in, when signing in is the fix.
    var signInCommand: String?

    /// Nil when the provider can run, or hasn't been checked.
    init?(_ provider: AgentProviderConfig, health: AgentProviderHealth?) {
        guard provider.enabled, let health, health.status == .error else { return nil }
        if !health.installed {
            (badge, reason) = ("Not installed", "\(provider.kind.name) wasn't found on this computer")
        } else if health.versionAdvisory?.status == .unsupported {
            badge = "Update needed"
            reason = health.versionAdvisory?.minimumVersion.map { "Needs \(provider.kind.name) \($0) or later" } ?? "This version is too old"
        } else if health.auth == .signedOut {
            (badge, reason) = ("Signed out", "Not signed in")
            signInCommand = health.signInCommand
        } else {
            (badge, reason) = ("Unavailable", "It can't run now")
        }
        let message = health.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        detail = "\(provider.title): Unavailable. " + (message.isEmpty ? "\(reason)." : message)
    }
}
