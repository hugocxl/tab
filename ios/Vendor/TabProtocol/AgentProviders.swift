import Foundation

/// One coding agent a server can run in agent panes: a Claude Code or Codex
/// CLI with its own executable, home folder, arguments, environment and model
/// preferences. Each kind has a built-in provider whose `id` is the kind's
/// name; more can be added, such as a second Claude signed in to another
/// account through its own config folder.
public struct AgentProviderConfig: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var kind: AgentChatProvider
    /// Shown instead of the kind's name.
    public var name: String?
    /// A disabled provider offers no models and starts no new conversations.
    public var enabled: Bool
    /// The CLI to run: a name looked up on `PATH`, or a path. Empty runs `claude` or `codex`.
    public var executable: String?
    /// `CLAUDE_CONFIG_DIR` or `CODEX_HOME`: where the CLI keeps its sign-in,
    /// settings and conversations. Empty uses the CLI's own default.
    public var home: String?
    /// Added after Tab's own arguments when the CLI starts.
    public var arguments: [String]
    /// Variables set for the CLI, such as API keys and base URLs, in order.
    public var environment: [AgentProviderVariable]
    /// Claude only: the context size, in tokens, at which it compacts the conversation.
    public var autoCompactTokens: Int?
    public var models: AgentProviderModels

    public static let autoCompactRange = 100_000 ... 1_000_000

    public init(id: String, kind: AgentChatProvider, name: String? = nil, enabled: Bool = true,
                executable: String? = nil, home: String? = nil, arguments: [String] = [],
                environment: [AgentProviderVariable] = [], autoCompactTokens: Int? = nil,
                models: AgentProviderModels = AgentProviderModels()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.enabled = enabled
        self.executable = executable
        self.home = home
        self.arguments = arguments
        self.environment = environment
        self.autoCompactTokens = autoCompactTokens
        self.models = models
    }

    /// The built-in provider of `kind`, with nothing changed.
    public static func builtIn(_ kind: AgentChatProvider) -> AgentProviderConfig {
        AgentProviderConfig(id: kind.rawValue, kind: kind)
    }

    public var isBuiltIn: Bool { id == kind.rawValue }

    /// The name the app shows: the chosen one, else the kind's.
    public var title: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? kind.name : trimmed
    }

    /// The command run when none is set.
    public var defaultExecutable: String { kind == .claude ? "claude" : "codex" }

    /// The variable `home` sets.
    public var homeVariable: String { kind == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME" }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, enabled, executable, home, arguments, environment, autoCompactTokens, models
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(AgentChatProvider.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        executable = try c.decodeIfPresent(String.self, forKey: .executable)
        home = try c.decodeIfPresent(String.self, forKey: .home)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try c.decodeIfPresent([AgentProviderVariable].self, forKey: .environment) ?? []
        autoCompactTokens = try c.decodeIfPresent(Int.self, forKey: .autoCompactTokens)
        models = try c.decodeIfPresent(AgentProviderModels.self, forKey: .models) ?? AgentProviderModels()
    }
}

/// One environment variable of a provider.
public struct AgentProviderVariable: Hashable, Codable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// How a provider's models show in the composer's model menu.
public struct AgentProviderModels: Hashable, Codable, Sendable {
    /// Model IDs listed first, marked as favorites.
    public var favorites: [String]
    /// Model IDs left out of the menu.
    public var hidden: [String]
    /// Model IDs in the order the user arranged; others follow in the provider's order.
    public var order: [String]
    /// Models the provider doesn't report, such as a newly released one.
    public var custom: [AgentCustomModel]

    public init(favorites: [String] = [], hidden: [String] = [], order: [String] = [], custom: [AgentCustomModel] = []) {
        self.favorites = favorites
        self.hidden = hidden
        self.order = order
        self.custom = custom
    }

    private enum CodingKeys: String, CodingKey { case favorites, hidden, order, custom }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favorites = try c.decodeIfPresent([String].self, forKey: .favorites) ?? []
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        custom = try c.decodeIfPresent([AgentCustomModel].self, forKey: .custom) ?? []
    }

    public var isEmpty: Bool { favorites.isEmpty && hidden.isEmpty && order.isEmpty && custom.isEmpty }

    /// `reported` plus the custom models, favorites first, then in the user's
    /// order, then the provider's.
    public func arrange(_ reported: [AgentModelDescriptor]) -> [AgentModelDescriptor] {
        var all = reported
        for model in custom where !all.contains(where: { $0.id == model.id }) {
            all.append(AgentModelDescriptor(id: model.id, title: model.title ?? model.id, reasoningEfforts: []))
        }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let favorite = Set(favorites)
        return all.enumerated().sorted { a, b in
            let aFavorite = favorite.contains(a.element.id), bFavorite = favorite.contains(b.element.id)
            if aFavorite != bFavorite { return aFavorite }
            let aRank = rank[a.element.id] ?? Int.max, bRank = rank[b.element.id] ?? Int.max
            return aRank == bRank ? a.offset < b.offset : aRank < bRank
        }.map(\.element)
    }

    /// The arranged models the menu offers.
    public func visible(_ reported: [AgentModelDescriptor]) -> [AgentModelDescriptor] {
        let hidden = Set(hidden)
        return arrange(reported).filter { !hidden.contains($0.id) }
    }
}

/// A model added by hand.
public struct AgentCustomModel: Hashable, Codable, Sendable {
    public var id: String
    public var title: String?

    public init(id: String, title: String? = nil) {
        self.id = id
        self.title = title
    }
}

/// A server's coding agents, kept in its `agent-providers.json`.
public struct AgentProviderSettings: Hashable, Codable, Sendable {
    public static let maxProviders = 32
    public static let defaultHealthCheckInterval = 300

    /// Every provider, built-in ones included, in the order the app lists them.
    public var providers: [AgentProviderConfig]
    /// Seconds between background checks of each provider's version and sign-in; 0 checks only on request.
    public var healthCheckInterval: Int

    public init(providers: [AgentProviderConfig] = [], healthCheckInterval: Int = defaultHealthCheckInterval) {
        self.providers = providers
        self.healthCheckInterval = healthCheckInterval
        normalize()
    }

    private enum CodingKeys: String, CodingKey { case providers, healthCheckInterval }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = (try? c.decodeIfPresent(LossyProviders.self, forKey: .providers))?.providers ?? []
        healthCheckInterval = try c.decodeIfPresent(Int.self, forKey: .healthCheckInterval) ?? Self.defaultHealthCheckInterval
        normalize()
    }

    /// Adds a missing built-in provider and drops repeated IDs.
    private mutating func normalize() {
        var seen = Set<String>()
        providers = providers.filter { seen.insert($0.id).inserted }
        for kind in AgentChatProvider.allCases where !seen.contains(kind.rawValue) {
            providers.append(.builtIn(kind))
        }
    }

    public func provider(_ id: String?) -> AgentProviderConfig? {
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }

    /// The provider a conversation runs: `id`'s, or else its kind's built-in one.
    public func provider(_ id: String?, kind: AgentChatProvider) -> AgentProviderConfig {
        if let found = provider(id), found.kind == kind { return found }
        return provider(kind.rawValue) ?? .builtIn(kind)
    }

    /// A new provider's ID, unused by any other.
    public func newID(_ kind: AgentChatProvider) -> String {
        var number = 2
        while provider("\(kind.rawValue)-\(number)") != nil { number += 1 }
        return "\(kind.rawValue)-\(number)"
    }

    /// Decodes each provider alone, so one a newer build wrote with a kind
    /// this build doesn't know is skipped rather than failing the file.
    private struct LossyProviders: Decodable {
        var providers: [AgentProviderConfig] = []
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            while !c.isAtEnd {
                if let provider = try? c.decode(AgentProviderConfig.self) {
                    providers.append(provider)
                } else {
                    _ = try? c.decode(Skipped.self)
                }
            }
        }
        private struct Skipped: Decodable {}
    }
}

/// What a check found about a provider's CLI.
public struct AgentProviderHealth: Hashable, Codable, Sendable {
    public enum Auth: String, Codable, Sendable {
        case signedIn, signedOut, unknown

        public init(from decoder: Decoder) throws {
            self = Auth(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var provider: String
    /// Whether the CLI was found and ran.
    public var installed: Bool
    /// Such as `2.1.311`.
    public var version: String?
    public var auth: Auth
    /// How it is signed in, such as "Claude Team subscription" or "ChatGPT".
    public var account: String?
    /// The signed-in account's email address, when the CLI reports one.
    public var email: String?
    /// Why it can't run, or what to fix, such as a missing CLI.
    public var message: String?
    public var checkedAt: Date

    public init(provider: String, installed: Bool, version: String? = nil, auth: Auth = .unknown,
                account: String? = nil, email: String? = nil, message: String? = nil, checkedAt: Date) {
        self.provider = provider
        self.installed = installed
        self.version = version
        self.auth = auth
        self.account = account
        self.email = email
        self.message = message
        self.checkedAt = checkedAt
    }

    private enum CodingKeys: String, CodingKey { case provider, installed, version, auth, account, email, message, checkedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        version = try c.decodeIfPresent(String.self, forKey: .version)
        auth = try c.decodeIfPresent(Auth.self, forKey: .auth) ?? .unknown
        account = try c.decodeIfPresent(String.self, forKey: .account)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        checkedAt = try c.decode(Date.self, forKey: .checkedAt)
    }
}

/// A server's providers with what their last checks found.
public struct AgentProvidersState: Hashable, Codable, Sendable {
    public var settings: AgentProviderSettings
    /// The latest check of each provider that has had one.
    public var health: [AgentProviderHealth]

    public init(settings: AgentProviderSettings, health: [AgentProviderHealth] = []) {
        self.settings = settings
        self.health = health
    }

    private enum CodingKeys: String, CodingKey { case settings, health }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decode(AgentProviderSettings.self, forKey: .settings)
        health = try c.decodeIfPresent([AgentProviderHealth].self, forKey: .health) ?? []
    }

    public func health(_ provider: String) -> AgentProviderHealth? { health.first { $0.provider == provider } }
}

extension AgentProviderSettings {
    public func validate() throws(ErrorCode) {
        guard providers.count <= Self.maxProviders, (0 ... 86_400).contains(healthCheckInterval) else { throw .badRequest }
        var ids = Set<String>()
        for provider in providers {
            guard ids.insert(provider.id).inserted else { throw .badRequest }
            try provider.validate()
        }
    }
}

extension AgentProviderConfig {
    public func validate() throws(ErrorCode) {
        func text(_ value: String?, max: Int = Limits.maxPathBytes) -> Bool {
            guard let value else { return true }
            return value.utf8.count <= max && !value.utf8.contains(0)
        }
        guard !id.isEmpty, id.utf8.count <= 64,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }),
              text(name, max: 128), text(executable), text(home),
              arguments.count <= 64, arguments.allSatisfy({ text($0) }),
              autoCompactTokens.map(Self.autoCompactRange.contains) ?? true else { throw .badRequest }
        try Validation.environment(Dictionary(environment.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last }))
        try models.validate()
    }
}

extension AgentProviderModels {
    public func validate() throws(ErrorCode) {
        let ids = favorites + hidden + order + custom.map(\.id)
        guard ids.count <= 4 * AgentModelCatalogReply.maxModels, custom.count <= 64,
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }),
              custom.allSatisfy({ ($0.title?.utf8.count ?? 0) <= 256 }) else { throw .badRequest }
    }
}
