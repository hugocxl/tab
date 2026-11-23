import Foundation

/// How Tab talks to a provider's CLI.
public enum AgentProviderWire: Sendable {
    /// Claude Code's `--print` stream-json with control requests.
    case claudeStream
    /// `codex app-server` JSON-RPC.
    case codexAppServer
    /// The Agent Client Protocol: JSON-RPC 2.0 over stdio, `initialize`, `session/new`,
    /// `session/prompt` and `session/update`.
    case acp
}

/// What Tab knows about a kind of provider: how to start it, where it keeps its
/// sign-in, how it is installed and updated, and the oldest version Tab works with.
public struct AgentProviderSpec: Sendable {
    public var name: String
    /// Who makes it, such as "Google".
    public var vendor: String?
    public var wire: AgentProviderWire
    /// The command run when the provider sets none; nil when it must be set.
    public var executable: String?
    /// Arguments that start a conversation, before the provider's own.
    public var sessionArguments: [String]
    /// The variable a provider's config folder sets, such as `CLAUDE_CONFIG_DIR`.
    public var homeVariable: String?
    /// The folder the CLI uses when `homeVariable` isn't set.
    public var defaultHome: String?
    /// An example for the launch arguments field.
    public var argumentsExample: String?
    /// The npm package the CLI ships as.
    public var npmPackage: String?
    /// The Homebrew formula or cask the CLI ships as.
    public var homebrew: String?
    public var homebrewIsCask: Bool
    /// Arguments that make the CLI update itself, such as `["update"]`.
    public var selfUpdateArguments: [String]?
    /// The command shown to install it when it isn't found.
    public var installCommand: String?
    /// The command shown to sign in when it is signed out.
    public var signInCommand: String?
    /// The oldest version Tab's integration works with.
    public var minimumVersion: String?
    /// Variables that sign it in with an API key instead of an account.
    public var apiKeyVariables: [String]
    public var documentationURL: String?
    /// A JSON manifest of the latest release, `{version, url, sha512}`, with `{target}` standing
    /// for the platform, such as `darwin_arm64`. Tab can install and verify such a release itself.
    public var releaseManifest: String?
    /// Whether a new server turns its built-in provider on.
    public var enabledByDefault: Bool

    public init(name: String, vendor: String? = nil, wire: AgentProviderWire, executable: String?,
                sessionArguments: [String] = [], homeVariable: String? = nil, defaultHome: String? = nil,
                argumentsExample: String? = nil, npmPackage: String? = nil, homebrew: String? = nil,
                homebrewIsCask: Bool = false, selfUpdateArguments: [String]? = nil, installCommand: String? = nil,
                signInCommand: String? = nil, minimumVersion: String? = nil, apiKeyVariables: [String] = [],
                documentationURL: String? = nil, releaseManifest: String? = nil, enabledByDefault: Bool = true) {
        self.name = name
        self.vendor = vendor
        self.wire = wire
        self.executable = executable
        self.sessionArguments = sessionArguments
        self.homeVariable = homeVariable
        self.defaultHome = defaultHome
        self.argumentsExample = argumentsExample
        self.npmPackage = npmPackage
        self.homebrew = homebrew
        self.homebrewIsCask = homebrewIsCask
        self.selfUpdateArguments = selfUpdateArguments
        self.installCommand = installCommand
        self.signInCommand = signInCommand
        self.minimumVersion = minimumVersion
        self.apiKeyVariables = apiKeyVariables
        self.documentationURL = documentationURL
        self.releaseManifest = releaseManifest
        self.enabledByDefault = enabledByDefault
    }
}

extension AgentChatProvider {
    public var spec: AgentProviderSpec {
        switch self {
        case .claude:
            AgentProviderSpec(name: "Claude Code", vendor: "Anthropic", wire: .claudeStream, executable: "claude",
                              homeVariable: "CLAUDE_CONFIG_DIR", defaultHome: "~/.claude", argumentsExample: "e.g. --chrome",
                              npmPackage: "@anthropic-ai/claude-code", homebrew: "claude-code", homebrewIsCask: true,
                              selfUpdateArguments: ["update"],
                              installCommand: "curl -fsSL https://claude.ai/install.sh | bash",
                              signInCommand: "claude auth login", minimumVersion: "2.1.111",
                              apiKeyVariables: ["ANTHROPIC_API_KEY"],
                              documentationURL: "https://docs.anthropic.com/en/docs/claude-code")
        case .codex:
            AgentProviderSpec(name: "Codex", vendor: "OpenAI", wire: .codexAppServer, executable: "codex",
                              sessionArguments: ["app-server"], homeVariable: "CODEX_HOME", defaultHome: "~/.codex",
                              argumentsExample: "e.g. -c model_verbosity=low", npmPackage: "@openai/codex",
                              homebrew: "codex", homebrewIsCask: true, installCommand: "npm install -g @openai/codex",
                              signInCommand: "codex login", minimumVersion: "0.149.0",
                              documentationURL: "https://github.com/openai/codex")
        case .antigravity:
            // `agy acp` 1.5.1 lets clients other than Zed use every model. Google sign-ins live in
            // the system keychain, so another config folder wouldn't be another account.
            AgentProviderSpec(name: "Antigravity CLI", vendor: "Google", wire: .acp, executable: "agy",
                              sessionArguments: ["acp"], argumentsExample: "e.g. --sandbox", selfUpdateArguments: ["update"],
                              installCommand: "Download it from https://antigravity.google/download",
                              signInCommand: "agy", minimumVersion: "1.5.1", apiKeyVariables: ["GEMINI_API_KEY"],
                              documentationURL: "https://antigravity.google/product/antigravity-cli",
                              releaseManifest: "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/{target}.json")
        case .gemini:
            // `--acp` replaced `--experimental-acp` in 0.36.0. GEMINI_CLI_HOME stands in for
            // the home folder, so the CLI keeps its sign-in in `$GEMINI_CLI_HOME/.gemini`.
            // Off by default: personal Google accounts moved to Antigravity CLI.
            AgentProviderSpec(name: "Gemini CLI", vendor: "Google Code Assist", wire: .acp, executable: "gemini",
                              sessionArguments: ["--acp"], homeVariable: "GEMINI_CLI_HOME", defaultHome: "~",
                              argumentsExample: "e.g. --sandbox", npmPackage: "@google/gemini-cli", homebrew: "gemini-cli",
                              installCommand: "npm install -g @google/gemini-cli",
                              signInCommand: "gemini", minimumVersion: "0.36.0",
                              apiKeyVariables: ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
                              documentationURL: "https://geminicli.com/docs/", enabledByDefault: false)
        case .openCode:
            AgentProviderSpec(name: "OpenCode", vendor: "Anomaly", wire: .acp, executable: "opencode",
                              sessionArguments: ["acp"], homeVariable: "OPENCODE_CONFIG_DIR", defaultHome: "~/.config/opencode",
                              argumentsExample: "e.g. --log-level warn", npmPackage: "@opencode/cli", homebrew: "opencode",
                              selfUpdateArguments: ["upgrade"], installCommand: "brew install opencode",
                              signInCommand: "opencode auth login", minimumVersion: "1.0.0",
                              documentationURL: "https://opencode.ai/docs")
        case .grok:
            AgentProviderSpec(name: "Grok", vendor: "xAI", wire: .acp, executable: "grok",
                              sessionArguments: ["agent", "stdio"], homeVariable: "GROK_HOME", defaultHome: "~/.grok",
                              npmPackage: "@xai-official/grok", selfUpdateArguments: ["update"],
                              installCommand: "npm install -g @xai-official/grok", signInCommand: "grok login",
                              minimumVersion: "1.0.13", apiKeyVariables: ["XAI_API_KEY"],
                              documentationURL: "https://docs.x.ai")
        case .kiro:
            AgentProviderSpec(name: "Kiro", vendor: "Amazon", wire: .acp, executable: "kiro-cli",
                              sessionArguments: ["acp"], installCommand: "curl -fsSL https://cli.kiro.dev/install | bash",
                              signInCommand: "kiro-cli login", minimumVersion: "2.27.0", apiKeyVariables: ["KIRO_API_KEY"],
                              documentationURL: "https://kiro.dev/docs/cli")
        case .acp:
            AgentProviderSpec(name: "ACP Agent", wire: .acp, executable: nil,
                              argumentsExample: "e.g. --acp", documentationURL: "https://agentclientprotocol.com")
        }
    }

    /// Whether every server has a provider of this kind without adding one. A custom ACP
    /// agent needs its command first, so it is only ever added.
    public var hasBuiltIn: Bool { self != .acp }

    /// The kinds that come with a built-in provider.
    public static var builtIn: [AgentChatProvider] { allCases.filter(\.hasBuiltIn) }

    /// The mark the app shows for conversations of this kind.
    public var activityProvider: AgentProvider {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .antigravity: .antigravity
        case .gemini: .gemini
        case .openCode: .openCode
        case .grok: .grok
        case .kiro: .kiro
        case .acp: .unknown("acp")
        }
    }
}

/// Dotted version numbers compared part by part, numbers as numbers.
public enum AgentProviderVersion {
    /// The first version number in `text`, such as `2.1.311` in "2.1.311 (Claude Code)".
    public static func find(in text: String) -> String? {
        guard let range = text.range(of: #"\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.]+)?"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// Whether `a` is older than `b`. A prerelease is older than its release.
    public static func isOlder(_ a: String, than b: String) -> Bool {
        compare(a, b) == .orderedAscending
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (aCore, aPre) = split(a), (bCore, bPre) = split(b)
        for index in 0 ..< max(aCore.count, bCore.count) {
            let x = index < aCore.count ? aCore[index] : 0
            let y = index < bCore.count ? bCore[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (aPre, bPre) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (x?, y?): return x == y ? .orderedSame : x.compare(y, options: .numeric)
        }
    }

    private static func split(_ version: String) -> ([Int], String?) {
        let trimmed = version.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
        let parts = trimmed.split(separator: "-", maxSplits: 1)
        let core = (parts.first ?? "").split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        return (core, parts.count > 1 ? String(parts[1]) : nil)
    }
}
