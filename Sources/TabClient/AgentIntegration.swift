import Darwin
import Foundation
import TabCore

/// A coding agent Tab can teach to use `tab`.
public enum CodingAgent: String, CaseIterable, Hashable, Codable, Sendable {
    case claude, codex, opencode, pi

    public var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .pi: "Pi"
        }
    }

    /// Whether the agent runs a command when a session starts and reads what
    /// it prints, so Tab can tell it which terminal it runs in.
    public var supportsSessionHook: Bool { self == .claude || self == .codex }
}

/// What Tab installed for one agent.
public struct AgentIntegrationStatus: Hashable, Codable, Sendable {
    public enum Part: String, Hashable, Codable, Sendable {
        case installed
        /// Installed by another build of Tab, or pointing at a `tab` that moved.
        case outdated
        case missing
        /// The agent has no such extension point.
        case unsupported
    }

    public var agent: CodingAgent
    /// The agent's configuration folder exists on this computer.
    public var found: Bool
    public var skill: Part
    public var hook: Part

    public init(agent: CodingAgent, found: Bool, skill: Part, hook: Part) {
        self.agent = agent
        self.found = found
        self.skill = skill
        self.hook = hook
    }

    /// Tab installed something for this agent.
    public var isIntegrated: Bool {
        (skill == .installed || skill == .outdated) || (hook == .installed || hook == .outdated)
    }
}

/// Installs the tab-cli skill into each coding agent found on this computer,
/// and a session-start hook into those that have one, so an agent running in
/// a Tab terminal learns that it does and how to drive Tab. Files are edited
/// in place: other skills, hooks and settings are kept, and a file that isn't
/// a JSON object is never overwritten.
public struct AgentIntegrations: Sendable {
    public var home: URL
    public var environment: [String: String]
    /// The `tab` the hooks run.
    public var cli: URL

    /// The command line hooks run, without arguments.
    public static let contextCommand = "agent-context"

    public init(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment, cli: URL) {
        self.home = home
        self.environment = environment
        self.cli = cli
    }

    /// The integrations of this user, with hooks running the `tab` beside the
    /// running program.
    public static func current() throws -> AgentIntegrations {
        let environment = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        guard let cli = Executable.sibling(Executable.cli) else { throw ExecutableError.notFound(Executable.cli) }
        return AgentIntegrations(home: home, environment: environment, cli: cli)
    }

    // MARK: Locations

    /// The agent's configuration folder, honoring the variable that moves it.
    public func root(_ agent: CodingAgent) -> URL {
        func override(_ name: String) -> URL? {
            guard let value = environment[name], value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        switch agent {
        case .claude:
            return override("CLAUDE_CONFIG_DIR") ?? home.appendingPathComponent(".claude", isDirectory: true)
        case .codex:
            return override("CODEX_HOME") ?? home.appendingPathComponent(".codex", isDirectory: true)
        case .opencode:
            let config = override("XDG_CONFIG_HOME") ?? home.appendingPathComponent(".config", isDirectory: true)
            return config.appendingPathComponent("opencode", isDirectory: true)
        case .pi:
            return override("PI_CODING_AGENT_DIR") ?? home.appendingPathComponent(".pi/agent", isDirectory: true)
        }
    }

    public func skillFile(_ agent: CodingAgent) -> URL {
        root(agent).appendingPathComponent("skills/\(AgentSkill.folderName)/SKILL.md")
    }

    /// The JSON file whose `hooks.SessionStart` runs the hook.
    public func hookFile(_ agent: CodingAgent) -> URL? {
        switch agent {
        case .claude: root(agent).appendingPathComponent("settings.json")
        case .codex: root(agent).appendingPathComponent("hooks.json")
        case .opencode, .pi: nil
        }
    }

    /// What the hook runs: this `tab`, quoted for a shell.
    public var hookCommand: String { Executable.commandLine([cli.path, Self.contextCommand]) }

    // MARK: Status

    public func status() -> [AgentIntegrationStatus] {
        CodingAgent.allCases.map(status)
    }

    public func status(_ agent: CodingAgent) -> AgentIntegrationStatus {
        let skill: AgentIntegrationStatus.Part
        switch try? String(contentsOf: skillFile(agent), encoding: .utf8) {
        case nil: skill = .missing
        case AgentSkill.text?: skill = .installed
        default: skill = .outdated
        }
        var hook = AgentIntegrationStatus.Part.unsupported
        if let file = hookFile(agent) {
            let commands = (try? HookDocument.read(file).tabCommands) ?? []
            if commands.isEmpty {
                hook = .missing
            } else {
                // Another Tab, such as a development build, may own the hook; it stays while its `tab` exists.
                hook = commands.contains { HookDocument.program($0).map(Executable.isExecutableFile) ?? false } ? .installed : .outdated
            }
        }
        return AgentIntegrationStatus(agent: agent, found: isDirectory(root(agent)), skill: skill, hook: hook)
    }

    /// Some agent has Tab's skill or hook.
    public static func isEnabled(_ statuses: [AgentIntegrationStatus]) -> Bool {
        statuses.contains { $0.found && $0.isIntegrated }
    }

    // MARK: Changing

    /// Installs the skill and hook into every agent found, replacing older
    /// copies. Fails when no agent is found.
    @discardableResult
    public func install() throws -> [AgentIntegrationStatus] {
        let found = CodingAgent.allCases.filter { isDirectory(root($0)) }
        guard !found.isEmpty else {
            throw CLIError("found no coding agent (Claude Code, Codex, OpenCode or Pi) on this computer")
        }
        for agent in found {
            try writeSkill(agent)
            if let file = hookFile(agent) { try HookDocument.update(file) { $0.setTabCommand(hookCommand) } }
        }
        return status()
    }

    /// Removes Tab's skill and hooks from every agent, keeping everything else.
    @discardableResult
    public func remove() throws -> [AgentIntegrationStatus] {
        for agent in CodingAgent.allCases {
            let skill = skillFile(agent)
            if FileManager.default.fileExists(atPath: skill.path) {
                try FileManager.default.removeItem(at: skill)
                rmdir(skill.deletingLastPathComponent().path) // only when nothing else is in it
            }
            if let file = hookFile(agent), FileManager.default.fileExists(atPath: file.path) {
                try HookDocument.update(file) { $0.setTabCommand(nil) }
            }
        }
        return status()
    }

    /// Brings what is installed up to date, such as the skill after an update
    /// or a hook whose `tab` is gone. Installs nothing new.
    public func refresh() throws {
        for agent in CodingAgent.allCases where isDirectory(root(agent)) {
            let current = status(agent)
            if current.skill == .outdated { try writeSkill(agent) }
            if current.hook == .outdated, let file = hookFile(agent) {
                try HookDocument.update(file) { $0.setTabCommand(hookCommand) }
            }
        }
    }

    private func writeSkill(_ agent: CodingAgent) throws {
        try AtomicFile.write(Data(AgentSkill.text.utf8), to: skillFile(agent), permissions: 0o644)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Context

    /// What the hook prints for an agent: nothing outside a Tab terminal.
    public static func context(environment: [String: String], cli: URL?) -> String? {
        guard let session = environment["TAB_SESSION_ID"], !session.isEmpty else { return nil }
        let command = cli.map { "`tab` (\($0.path))" } ?? "`tab`"
        return """
        You are running in a Tab terminal, session \(session). Tab keeps terminals running in a \
        background server, and \(command) drives them from a shell: start long-running work such as a \
        dev server or test watcher in its own terminal, wait for its output instead of polling, read \
        its screen, and manage projects and Git worktrees. Inside this terminal, session commands \
        default to it. Read the tab-cli skill, or run `tab --help`, before using it.
        """
    }
}

/// An agent's JSON file holding `hooks.SessionStart`, such as Claude Code's
/// `settings.json` or Codex's `hooks.json`.
struct HookDocument {
    private(set) var root: [String: Any]

    static let event = "SessionStart"

    /// The file's object; empty when missing. Anything else refuses, so a
    /// file Tab can't read is never replaced.
    static func read(_ url: URL) throws -> HookDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return HookDocument(root: [:])
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return HookDocument(root: [:]) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError("\(url.path) is not a JSON object; fix it before Tab changes it")
        }
        let document = HookDocument(root: root)
        guard document.groups != nil else {
            throw CLIError("\(url.path) has a \"hooks.\(event)\" that is not a list; fix it before Tab changes it")
        }
        return document
    }

    /// Reads `url`, changes it and writes it back when something changed,
    /// through a symbolic link to the file it points to.
    static func update(_ url: URL, _ change: (inout HookDocument) -> Void) throws {
        let target = url.resolvingSymlinksInPath()
        var document = try read(target)
        let before = document.root as NSDictionary
        change(&document)
        guard !before.isEqual(to: document.root) else { return }
        if document.root.isEmpty { return try FileManager.default.removeItem(at: target) }
        var data = try JSONSerialization.data(withJSONObject: document.root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)
            .map { mode_t($0.uint16Value) } ?? 0o644
        try AtomicFile.write(data, to: target, permissions: permissions)
    }

    /// The `SessionStart` matcher groups; `nil` when present but not a list.
    private var groups: [Any]? {
        guard let hooks = root["hooks"] else { return [] }
        guard let hooks = hooks as? [String: Any] else { return nil }
        guard let groups = hooks[Self.event] else { return [] }
        return groups as? [Any]
    }

    /// The commands of Tab's hooks, in file order.
    var tabCommands: [String] {
        (groups ?? []).flatMap(Self.handlers).compactMap(Self.command).filter(Self.isTab)
    }

    /// Replaces Tab's hooks with one running `command`, or removes them.
    mutating func setTabCommand(_ command: String?) {
        guard var groups else { return }
        groups = groups.compactMap { group in
            guard var object = group as? [String: Any], let handlers = object["hooks"] as? [Any] else { return group }
            let kept = handlers.filter { !Self.isTab(Self.command($0) ?? "") }
            guard kept.count != handlers.count else { return group }
            if kept.isEmpty { return nil }
            object["hooks"] = kept
            return object
        }
        if let command {
            groups.append(["hooks": [["type": "command", "command": command]]])
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        hooks[Self.event] = groups.isEmpty ? nil : groups
        root["hooks"] = hooks.isEmpty ? nil : hooks
    }

    private static func handlers(_ group: Any) -> [Any] {
        (group as? [String: Any])?["hooks"] as? [Any] ?? []
    }

    private static func command(_ handler: Any) -> String? {
        (handler as? [String: Any])?["command"] as? String
    }

    /// A hook Tab wrote: some `tab` running `agent-context`.
    static func isTab(_ command: String) -> Bool {
        program(command) != nil
    }

    /// The `tab` a hook Tab wrote runs; `nil` for other hooks.
    static func program(_ command: String) -> URL? {
        guard let arguments = try? Executable.commandArguments(command), arguments.count == 2,
              arguments[1] == AgentIntegrations.contextCommand,
              (arguments[0] as NSString).lastPathComponent == Executable.cli else { return nil }
        return URL(fileURLWithPath: arguments[0])
    }
}
