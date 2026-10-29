import Foundation
import TabCore
import TabProtocol

/// Recognizes AI coding agents from a session's program and classifies what
/// they are doing from the screen, OSC title and OSC 9;4 progress, using the
/// JSON rule manifests in `Resources/Detection`. Rules are compiled once at
/// initialization; detection itself only matches.
public final class AgentDetector: AgentDetectorProtocol, @unchecked Sendable {
    /// Manifest file names (without `.json`) and the providers they describe.
    static let manifestFiles: [(AgentProvider, String)] = [
        (.claude, "claude"), (.codex, "codex"), (.openCode, "opencode"), (.cursor, "cursor"),
        (.copilot, "github-copilot"), (.droid, "droid"), (.pi, "pi"), (.grok, "grok"), (.kiro, "kiro"),
        (.xal, "xal"), (.antigravity, "antigravity"), (.ohMyPi, "omp"),
    ]

    private let rules: [AgentProvider: [DetectionRule]]

    /// Loads the bundled manifests. A manifest that fails to compile is
    /// logged and its provider falls back to idle.
    public convenience init() {
        var rules: [AgentProvider: [DetectionRule]] = [:]
        for (provider, file) in Self.manifestFiles {
            do {
                rules[provider] = try DetectionManifest.compile(try Self.bundledManifest(file))
            } catch {
                Log.server.error("\(provider.displayName, privacy: .public) detection: \(String(describing: error), privacy: .public)")
            }
        }
        self.init(rules: rules)
    }

    init(rules: [AgentProvider: [DetectionRule]]) {
        self.rules = rules
    }

    static func bundledManifest(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Detection") else {
            throw DetectionManifestError.invalid("missing manifest \(name).json")
        }
        return try Data(contentsOf: url)
    }

    public func detect(_ input: DetectionInput, previous: DetectionResult?) -> DetectionResult? {
        guard let provider = Self.identify(program: input.program) else { return nil }
        let text = DetectionText(screen: input.screen, title: input.title, progress: input.progress)
        guard let classification = classify(provider, text) else {
            let state = previous?.provider == provider ? previous?.state ?? .unknown : .unknown
            return DetectionResult(provider: provider, state: state, keepsPreviousState: true)
        }
        return DetectionResult(provider: provider, state: classification.state)
    }

    struct Classification: Equatable {
        var state: AgentState
        /// The rule saw an explicit idle prompt, so idle confirms sooner.
        var explicitIdle: Bool
    }

    /// The first matching rule by priority; `nil` when it asks to keep the
    /// previous state. Unrecognized screens of a known agent read as idle.
    func classify(_ provider: AgentProvider, _ input: DetectionText) -> Classification? {
        var regions: [String: RegionText] = [:]
        for rule in rules[provider] ?? [] {
            let text: RegionText
            if let cached = regions[rule.region] {
                text = cached
            } else {
                text = RegionText(DetectionRegion.text(input, spec: rule.region))
                regions[rule.region] = text
            }
            if rule.matcher.matches(text) {
                return rule.skipStateUpdate ? nil : Classification(state: rule.state, explicitIdle: rule.visibleIdle)
            }
        }
        return Classification(state: .idle, explicitIdle: false)
    }

    // MARK: - Providers

    /// The agent a foreground program is, from its name alone.
    public static func identify(program: String) -> AgentProvider? {
        identify(name: program, arguments: [])
    }

    /// The agent a foreground process is. Looks only at the executable and,
    /// for interpreters, the script position, never at prompt arguments.
    public static func identify(name: String, arguments: [String]) -> AgentProvider? {
        let name = basename(name)
        if let provider = alias(name) { return provider }
        let runtime = arguments.first.map(basename) ?? name
        if let provider = alias(runtime) { return provider }
        let interpreters: Set = ["node", "bun", "python", "python3", "bash", "sh", "zsh", "fish"]
        guard interpreters.contains(runtime) || runtime.hasPrefix("python3.") else { return nil }
        guard arguments.count > 1 else { return nil }
        let script = arguments[1]
        guard !script.hasPrefix("-") else { return nil }
        if let provider = alias(basename(script)) { return provider }
        let parts = script.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let pairs = zip(parts, parts.dropFirst()).map { [$0, $1] }
        if pairs.contains(["cursor-agent", "versions"]), basename(script) == "index.js" { return .cursor }
        for pair in pairs {
            switch (pair[0], pair[1]) {
            case ("@anthropic-ai", "claude-code"): return .claude
            case ("@openai", "codex"): return .codex
            case ("@github", "copilot"): return .copilot
            case ("@mariozechner", "pi-coding-agent"): return .pi
            default: continue
            }
        }
        return nil
    }

    private static func basename(_ value: String) -> String {
        value.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? value
    }

    private static func alias(_ value: String) -> AgentProvider? {
        var name = Substring(value)
        while name.hasSuffix(".js") { name = name.dropLast(3) }
        switch name {
        case "claude", "claude-code": return .claude
        case "codex": return .codex
        case "opencode", "opencode2": return .openCode
        case "cursor-agent", "cursor", "agent": return .cursor
        case "copilot", "github-copilot": return .copilot
        case "droid": return .droid
        case "pi": return .pi
        case "grok", "grok-build": return .grok
        case "kiro", "kiro-cli": return .kiro
        case "xal", "xal-dev": return .xal
        case "agy", "antigravity", "antigravity-cli": return .antigravity
        case "omp", "oh-my-pi": return .ohMyPi
        default: return nil
        }
    }
}

/// One session's agent state over time: idle after work is confirmed only
/// once it holds (300 ms for an explicit idle prompt, 700 ms otherwise), a
/// blank redraw never ends a working cycle, and a finished cycle is reported
/// once.
public struct AgentStateTracker: Sendable {
    public private(set) var provider: AgentProvider?
    public private(set) var state: AgentState = .unknown
    private var pending: ContinuousClock.Instant?
    private var lastInput: (screen: String, title: String, progress: String)?
    private var cycle = false

    public init() {}

    /// Classifies the session again. Returns whether a working cycle just
    /// completed.
    public mutating func update(detector: AgentDetector, provider: AgentProvider?, screen: String, title: String,
                                progress: String, now: ContinuousClock.Instant) -> Bool {
        if self.provider != provider { self = AgentStateTracker(provider: provider) }
        guard let provider else { return false }
        let unchanged = lastInput.map { $0.screen == screen && $0.title == title && $0.progress == progress } ?? false
        if unchanged, pending == nil { return false }
        let result = detector.classify(provider, DetectionText(screen: screen, title: title, progress: progress))
        lastInput = (screen, title, progress)
        guard let result else {
            pending = nil
            return false
        }
        let next = result.state
        if next == .idle, state == .working || state == .blocked {
            let hasSignal = !DetectionRegion.isBlank(screen) || !DetectionRegion.isBlank(title) || !progress.isEmpty
            // A cleared screen is never evidence that a working cycle finished.
            guard hasSignal else {
                pending = nil
                return false
            }
            let started = pending ?? now
            pending = started
            let confirmation: Duration = .milliseconds(result.explicitIdle ? 300 : 700)
            if now - started < confirmation { return false }
        }
        pending = nil
        let completed = cycle && next == .idle
        if next == .working { cycle = true }
        if next == .idle || next == .unknown { cycle = false }
        state = next
        return completed
    }

    private init(provider: AgentProvider?) {
        self.provider = provider
    }
}
