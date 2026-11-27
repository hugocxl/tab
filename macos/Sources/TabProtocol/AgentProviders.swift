import Foundation

/// One coding agent a server can run in agent panes: a CLI such as Claude Code,
/// Codex or Gemini CLI with its own executable, home folder, arguments, environment
/// and model preferences. Each kind but a custom ACP agent has a built-in provider
/// whose `id` is the kind's name; more can be added, such as a second Claude signed
/// in to another account through its own config folder.
public struct AgentProviderConfig: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var kind: AgentChatProvider
    /// Shown instead of the kind's name.
    public var name: String?
    /// A disabled provider offers no models and starts no new conversations.
    public var enabled: Bool
    /// The CLI to run: a name looked up on `PATH`, or a path. Empty runs the kind's own command.
    public var executable: String?
    /// The kind's `homeVariable`, such as `CLAUDE_CONFIG_DIR` or `CODEX_HOME`: where the
    /// CLI keeps its sign-in, settings and conversations. Empty uses the CLI's own default.
    public var home: String?
    /// Codex only: a folder of this account's own that keeps its sign-in apart while
    /// sharing everything else, such as conversations and skills, with `home`. Empty
    /// runs Codex in `home` itself.
    public var shadowHome: String?
    /// A `#RRGGBB` color marking the provider in the model menu, such as one per account.
    public var accentColor: String?
    /// Added after Tab's own arguments when the CLI starts. A custom ACP agent's are all
    /// it starts with, such as `--acp`.
    public var arguments: [String]
    /// Variables set for the CLI, such as API keys and base URLs, in order.
    public var environment: [AgentProviderVariable]
    /// Claude only: the context size, in tokens, at which it compacts the conversation.
    public var autoCompactTokens: Int?
    public var models: AgentProviderModels

    public static let autoCompactRange = 100_000 ... 1_000_000

    public init(id: String, kind: AgentChatProvider, name: String? = nil, enabled: Bool = true,
                executable: String? = nil, home: String? = nil, shadowHome: String? = nil, accentColor: String? = nil,
                arguments: [String] = [], environment: [AgentProviderVariable] = [], autoCompactTokens: Int? = nil,
                models: AgentProviderModels = AgentProviderModels()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.enabled = enabled
        self.executable = executable
        self.home = home
        self.shadowHome = shadowHome
        self.accentColor = accentColor
        self.arguments = arguments
        self.environment = environment
        self.autoCompactTokens = autoCompactTokens
        self.models = models
    }

    /// The built-in provider of `kind`, with nothing changed.
    public static func builtIn(_ kind: AgentChatProvider) -> AgentProviderConfig {
        AgentProviderConfig(id: kind.rawValue, kind: kind, enabled: kind.spec.enabledByDefault)
    }

    public var isBuiltIn: Bool { kind.hasBuiltIn && id == kind.rawValue }

    /// A built-in provider as older builds added it by themselves: nothing set but whether it is on.
    var isUnchangedBuiltIn: Bool {
        var unchanged = AgentProviderConfig.builtIn(kind)
        unchanged.enabled = enabled
        return isBuiltIn && self == unchanged
    }

    /// The name the app shows: the chosen one, else the kind's.
    public var title: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? kind.name : trimmed
    }

    /// The command run when none is set; empty for a custom ACP agent, which needs one.
    public var defaultExecutable: String { kind.spec.executable ?? "" }

    /// The variable `home` sets, when the kind has one.
    public var homeVariable: String? { kind.spec.homeVariable }

    /// Whether the kind can keep an account's sign-in in a shadow home.
    public var supportsShadowHome: Bool { kind == .codex }

    /// The API key it signs in with: the first of its kind's key variables that has a value.
    public var apiKey: String? {
        environment.first { kind.spec.apiKeyVariables.contains($0.name) && !$0.value.isEmpty }?.value
    }

    /// The folder its CLI keeps its sign-in in, written from `~`: a Codex account folder, else
    /// its config folder, else its kind's default. Nil when the kind keeps one sign-in per
    /// Mac, such as Antigravity CLI in the keychain.
    public var signInFolder: String? {
        guard homeVariable != nil else { return nil }
        func folder(_ path: String?) -> String? {
            var path = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty else { return nil }
            let home = NSHomeDirectory()
            if path == home || path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
            return path
        }
        return (supportsShadowHome ? folder(shadowHome) : nil) ?? folder(home) ?? folder(kind.spec.defaultHome)
    }

    /// Whether it and `other` would run signed in to the same account: the same API key, or
    /// without one the same sign-in folder. Custom ACP agents are told apart by their commands.
    public func sharesSignIn(with other: AgentProviderConfig) -> Bool {
        guard kind == other.kind, kind != .acp else { return false }
        if apiKey != nil || other.apiKey != nil { return apiKey == other.apiKey }
        return signInFolder == other.signInFolder
    }

    /// Marker colors the app offers for `accentColor`.
    public static let accentColors = ["#F2701B", "#E5484D", "#D6409F", "#8E4BF2", "#1F6FEB", "#1E9AA0", "#2FA84A", "#F29D1B"]

    /// `accentColor` as red, green and blue from 0 to 255, when it is a valid `#RRGGBB`.
    public var accentComponents: (red: Int, green: Int, blue: Int)? {
        guard let hex = accentColor, Self.isAccentColor(hex), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    public static func isAccentColor(_ text: String) -> Bool {
        text.count == 7 && text.first == "#" && text.dropFirst().allSatisfy(\.isHexDigit)
    }

    /// Whether `id` can name a provider: 1 to 64 letters, digits, `-` and `_`.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, enabled, executable, home, shadowHome, accentColor, arguments, environment, autoCompactTokens, models
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(AgentChatProvider.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        executable = try c.decodeIfPresent(String.self, forKey: .executable)
        home = try c.decodeIfPresent(String.self, forKey: .home)
        shadowHome = try c.decodeIfPresent(String.self, forKey: .shadowHome)
        accentColor = try c.decodeIfPresent(String.self, forKey: .accentColor)
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
    public static let maxProviders = 128
    public static let defaultHealthCheckInterval = 300

    /// Configured providers, in the order the app lists them.
    public var providers: [AgentProviderConfig]
    /// Seconds between background checks of each provider's version and sign-in; 0 checks only on request.
    public var healthCheckInterval: Int

    public init(providers: [AgentProviderConfig] = [], healthCheckInterval: Int = defaultHealthCheckInterval) {
        self.providers = providers
        self.healthCheckInterval = healthCheckInterval
        normalize()
    }

    /// 2 since providers are only ever added by the user. Older builds wrote none and
    /// filled the list with every built-in kind.
    static let revision = 2

    private enum CodingKeys: String, CodingKey { case providers, healthCheckInterval, revision }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = (try? c.decodeIfPresent(LossyProviders.self, forKey: .providers))?.providers ?? []
        healthCheckInterval = try c.decodeIfPresent(Int.self, forKey: .healthCheckInterval) ?? Self.defaultHealthCheckInterval
        normalize()
        if (try? c.decodeIfPresent(Int.self, forKey: .revision)) == nil { dropSeededProviders() }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(providers, forKey: .providers)
        try c.encode(healthCheckInterval, forKey: .healthCheckInterval)
        try c.encode(Self.revision, forKey: .revision)
    }

    /// Drops repeated IDs.
    private mutating func normalize() {
        var seen = Set<String>()
        providers = providers.filter { seen.insert($0.id).inserted }
    }

    /// Older builds, and older apps saving to this server, list every built-in kind whether
    /// the user added it or not. Such a list keeps only the providers the user changed.
    private mutating func dropSeededProviders() {
        let ids = Set(providers.map(\.id))
        guard AgentChatProvider.builtIn.allSatisfy({ ids.contains($0.rawValue) }) else { return }
        providers.removeAll(where: \.isUnchangedBuiltIn)
    }

    public func provider(_ id: String?) -> AgentProviderConfig? {
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }

    /// The provider a conversation runs: `id`'s, or the first configured provider of `kind`,
    /// falling back to a default configuration for legacy conversations.
    public func provider(_ id: String?, kind: AgentChatProvider) -> AgentProviderConfig {
        if let found = provider(id), found.kind == kind { return found }
        if id == nil, let first = providers.first(where: { $0.kind == kind }) { return first }
        return provider(kind.rawValue) ?? .builtIn(kind)
    }

    /// A new provider's ID, unused by any other.
    public func newID(_ kind: AgentChatProvider) -> String {
        var number = 2
        while provider("\(kind.rawValue)-\(number)") != nil { number += 1 }
        return "\(kind.rawValue)-\(number)"
    }

    /// A new provider's ID from its label, such as `claude-work` for “Work” or “Claude Work”,
    /// unused by any other; `newID` when the label has no letters or digits.
    public func newID(_ kind: AgentChatProvider, label: String) -> String {
        func tokens(_ text: String) -> [String] {
            text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
        }
        var words = tokens(label)
        let nameWords = tokens(kind.name)
        let idWords = tokens(kind.rawValue)
        if !nameWords.isEmpty, words.starts(with: nameWords) {
            words.removeFirst(nameWords.count)
        } else if !idWords.isEmpty, words.starts(with: idWords) {
            words.removeFirst(idWords.count)
        }
        guard !words.isEmpty else {
            return provider(kind.rawValue) == nil ? kind.rawValue : newID(kind)
        }
        let base = String((kind.rawValue + "-" + words.joined(separator: "-")).prefix(60))
        guard provider(base) != nil else { return base }
        var number = 2
        while provider("\(base)-\(number)") != nil { number += 1 }
        return "\(base)-\(number)"
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

/// Whether a provider can run conversations, as its last check found.
public enum AgentProviderStatus: String, Codable, Sendable, CaseIterable {
    /// Installed, signed in or signed in as far as Tab can tell, and new enough.
    case ready
    /// It runs, but something needs attention: an update, an unknown sign-in, a version Tab hasn't tested.
    case warning
    /// It can't run: missing, signed out, or older than Tab supports.
    case error
    /// Turned off in Settings › Agents.
    case disabled

    public init(from decoder: Decoder) throws {
        self = AgentProviderStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .warning
    }
}

/// How a provider's installed CLI compares with its latest release and the oldest Tab supports.
public struct AgentProviderVersionAdvisory: Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The latest release couldn't be looked up.
        case unknown
        case current
        /// A newer release is out.
        case behindLatest
        /// Older than `minimumVersion`; conversations may fail until it is updated.
        case unsupported

        public init(from decoder: Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var status: Status
    public var latestVersion: String?
    /// The oldest version Tab's integration works with.
    public var minimumVersion: String?
    /// How the CLI was installed, such as "Homebrew" or "npm".
    public var installedBy: String?
    /// The command that updates the CLI the way it was installed.
    public var updateCommand: String?
    /// Whether the server can run `updateCommand` itself.
    public var canUpdate: Bool
    /// When the latest release was looked up.
    public var checkedAt: Date?

    public init(status: Status, latestVersion: String? = nil, minimumVersion: String? = nil, installedBy: String? = nil,
                updateCommand: String? = nil, canUpdate: Bool = false, checkedAt: Date? = nil) {
        self.status = status
        self.latestVersion = latestVersion
        self.minimumVersion = minimumVersion
        self.installedBy = installedBy
        self.updateCommand = updateCommand
        self.canUpdate = canUpdate
        self.checkedAt = checkedAt
    }

    private enum CodingKeys: String, CodingKey {
        case status, latestVersion, minimumVersion, installedBy, updateCommand, canUpdate, checkedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .unknown
        latestVersion = try c.decodeIfPresent(String.self, forKey: .latestVersion)
        minimumVersion = try c.decodeIfPresent(String.self, forKey: .minimumVersion)
        installedBy = try c.decodeIfPresent(String.self, forKey: .installedBy)
        updateCommand = try c.decodeIfPresent(String.self, forKey: .updateCommand)
        canUpdate = try c.decodeIfPresent(Bool.self, forKey: .canUpdate) ?? false
        checkedAt = try c.decodeIfPresent(Date.self, forKey: .checkedAt)
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
    /// The overall state, from what the check found. Servers that predate it send none,
    /// and it is worked out from the other fields.
    public var status: AgentProviderStatus
    /// The CLI the check ran.
    public var executablePath: String?
    public var versionAdvisory: AgentProviderVersionAdvisory?
    /// The command that installs the CLI, when it wasn't found.
    public var installCommand: String?
    /// Whether the server can run `installCommand` itself.
    public var canInstall: Bool
    /// The command that signs in, when it is signed out.
    public var signInCommand: String?

    public init(provider: String, installed: Bool, version: String? = nil, auth: Auth = .unknown,
                account: String? = nil, email: String? = nil, message: String? = nil, checkedAt: Date,
                status: AgentProviderStatus? = nil, executablePath: String? = nil,
                versionAdvisory: AgentProviderVersionAdvisory? = nil, installCommand: String? = nil,
                canInstall: Bool = false, signInCommand: String? = nil) {
        self.provider = provider
        self.installed = installed
        self.version = version
        self.auth = auth
        self.account = account
        self.email = email
        self.message = message
        self.checkedAt = checkedAt
        self.executablePath = executablePath
        self.versionAdvisory = versionAdvisory
        self.installCommand = installCommand
        self.canInstall = canInstall
        self.signInCommand = signInCommand
        self.status = .ready
        self.status = status ?? derivedStatus
    }

    /// The status the other fields imply.
    public var derivedStatus: AgentProviderStatus {
        guard installed else { return .error }
        if auth == .signedOut || versionAdvisory?.status == .unsupported { return .error }
        if auth == .unknown || versionAdvisory?.status == .behindLatest { return .warning }
        return .ready
    }

    private enum CodingKeys: String, CodingKey {
        case provider, installed, version, auth, account, email, message, checkedAt
        case status, executablePath, versionAdvisory, installCommand, canInstall, signInCommand
    }

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
        executablePath = try c.decodeIfPresent(String.self, forKey: .executablePath)
        versionAdvisory = try c.decodeIfPresent(AgentProviderVersionAdvisory.self, forKey: .versionAdvisory)
        installCommand = try c.decodeIfPresent(String.self, forKey: .installCommand)
        canInstall = try c.decodeIfPresent(Bool.self, forKey: .canInstall) ?? false
        signInCommand = try c.decodeIfPresent(String.self, forKey: .signInCommand)
        status = .ready
        status = try c.decodeIfPresent(AgentProviderStatus.self, forKey: .status) ?? derivedStatus
    }
}

/// Installing or updating a provider's CLI, run by its server.
public struct AgentProviderMaintenance: Hashable, Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case install, update
    }

    public enum Status: String, Codable, Sendable {
        case running
        case succeeded
        case failed
        /// It finished, but the CLI reports the same version as before.
        case unchanged

        public init(from decoder: Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
        }
    }

    public static let maxOutputBytes = 10_000

    public var provider: String
    public var action: Action
    public var command: String
    public var status: Status
    public var startedAt: Date
    public var finishedAt: Date?
    /// What happened, in a sentence.
    public var message: String?
    /// The end of what the command printed.
    public var output: String?

    public init(provider: String, action: Action, command: String, status: Status, startedAt: Date,
                finishedAt: Date? = nil, message: String? = nil, output: String? = nil) {
        self.provider = provider
        self.action = action
        self.command = command
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.message = message
        self.output = output
    }

    public var isRunning: Bool { status == .running }
}

/// A server's providers with what their last checks found.
public struct AgentProvidersState: Hashable, Codable, Sendable {
    public var settings: AgentProviderSettings
    /// The latest check of each provider that has had one.
    public var health: [AgentProviderHealth]
    /// The latest install or update of each provider that has had one since the server started.
    public var maintenance: [AgentProviderMaintenance]
    /// The kinds of provider the server can run. Servers that predate it run only the
    /// original two, and the providers of other kinds this build adds are left out.
    public var kinds: [AgentChatProvider]

    public init(settings: AgentProviderSettings, health: [AgentProviderHealth] = [],
                maintenance: [AgentProviderMaintenance] = [], kinds: [AgentChatProvider] = AgentChatProvider.allCases) {
        self.kinds = kinds
        self.settings = settings
        self.health = health
        self.maintenance = maintenance
        self.settings.providers.removeAll { !kinds.contains($0.kind) }
    }

    private enum CodingKeys: String, CodingKey { case settings, health, maintenance, kinds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decode(AgentProviderSettings.self, forKey: .settings)
        health = try c.decodeIfPresent([AgentProviderHealth].self, forKey: .health) ?? []
        maintenance = try c.decodeIfPresent([AgentProviderMaintenance].self, forKey: .maintenance) ?? []
        // A kind a newer server names but this build doesn't know is left out.
        let names = try c.decodeIfPresent([String].self, forKey: .kinds)
        kinds = names.map { $0.compactMap(AgentChatProvider.init(rawValue:)) } ?? AgentChatProvider.original
        settings.providers.removeAll { !kinds.contains($0.kind) }
    }

    public func health(_ provider: String) -> AgentProviderHealth? { health.first { $0.provider == provider } }

    public func maintenance(_ provider: String) -> AgentProviderMaintenance? { maintenance.first { $0.provider == provider } }

    /// The status a provider shows: off, else what its last check found; nil before any check.
    public func status(_ provider: AgentProviderConfig) -> AgentProviderStatus? {
        guard provider.enabled else { return .disabled }
        return health(provider.id)?.status
    }
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
              text(name, max: 128), text(executable), text(home), text(shadowHome),
              accentColor.map(Self.isAccentColor) ?? true,
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
