import Darwin
import Foundation
import TabCore
import TabProtocol

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

    /// The `tab` arguments of the hook that runs when an agent's session starts.
    static let contextArguments = ["integrations", "context"]

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

    /// The JSON file whose `hooks` run Tab's hooks.
    public func hookFile(_ agent: CodingAgent) -> URL? {
        switch agent {
        case .claude: root(agent).appendingPathComponent("settings.json")
        case .codex: root(agent).appendingPathComponent("hooks.json")
        case .opencode, .pi: nil
        }
    }

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
            let found = (try? HookDocument.read(file).tabHooks) ?? []
            if found.isEmpty {
                hook = .missing
            } else if Set(found.map(\.hook)) != Set(TabHook.all(for: agent)) {
                hook = .outdated
            } else {
                // Another Tab, such as a development build, may own the hooks; they stay while its `tab` exists.
                hook = found.allSatisfy { Executable.isExecutableFile($0.program) } ? .installed : .outdated
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
    /// copies. Fails when no agent is found, unless `required` is false.
    @discardableResult
    public func install(required: Bool = true) throws -> [AgentIntegrationStatus] {
        let found = CodingAgent.allCases.filter { isDirectory(root($0)) }
        guard !found.isEmpty || !required else {
            throw CLIError("found no coding agent (Claude Code, Codex, OpenCode or Pi) on this computer")
        }
        for agent in found {
            try writeSkill(agent)
            if let file = hookFile(agent) { try HookDocument.update(file) { $0.setTabHooks(TabHook.all(for: agent), cli: cli) } }
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
                try HookDocument.update(file) { $0.setTabHooks([], cli: cli) }
            }
        }
        return status()
    }

    /// Brings what is installed up to date, such as the skill after an update
    /// or hooks from an older Tab or whose `tab` is gone. Installs nothing new.
    public func refresh() throws {
        for agent in CodingAgent.allCases where isDirectory(root(agent)) {
            let current = status(agent)
            if current.skill == .outdated { try writeSkill(agent) }
            if current.hook == .outdated, let file = hookFile(agent) {
                try HookDocument.update(file) { $0.setTabHooks(TabHook.all(for: agent), cli: cli) }
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

    /// What the hook prints for an agent: nothing outside a Tab terminal or agent pane.
    public static func context(environment: [String: String], cli: URL?) -> String? {
        let command = cli.map { "`tab` (\($0.path))" } ?? "`tab`"
        if let agent = environment["TAB_AGENT_ID"], !agent.isEmpty {
            return """
            You are running in a Tab agent pane, agent \(agent): the Tab app shows this conversation, and \
            \(command) drives the app from a shell. When the user asks for panes, tabs or a split, or to \
            branch or fork this conversation, they mean Tab's panes, not your own subagents, which Tab \
            doesn't show. Open a terminal, agent, browser, simulator, editor or diff pane beside this one with \
            `tab pane new`. To branch, run `tab pane new agent --fork -- "<what this branch does>"` once per \
            branch: each pane continues this conversation and starts on its message, and the user talks to \
            it there. Branches that change files need a worktree each (`tab worktree new`, then `--fork \
            --project <worktree>`). `tab agent wait` and `tab agent read` give a branch's latest reply. Read \
            the tab-cli skill, or run `tab --help`, before using it.
            """
        }
        guard let session = environment["TAB_SESSION_ID"], !session.isEmpty else { return nil }
        let name = SessionId(string: session).map { " (\(SessionName.of($0)))" } ?? ""
        return """
        You are running in a Tab terminal, session \(session)\(name). Tab keeps terminals running in a \
        background server, and \(command) drives them from a shell: start long-running work such as a \
        dev server or test watcher in its own terminal, wait for its output instead of polling, read \
        its screen, open terminal, agent, browser, simulator, editor and diff panes beside this one, and \
        manage projects and Git worktrees. Inside this terminal, session commands default to it. Read \
        the tab-cli skill, or run `tab --help`, before using it.
        """
    }
}

/// A hook Tab installs: when it runs, which of the event's sources it
/// matches, and the `tab` arguments it runs.
struct TabHook: Hashable {
    var event: String
    var matcher: String?
    var arguments: [String]

    /// What Tab installs into `agent`: context when a session starts, and the
    /// agent's state as it changes.
    static func all(for agent: CodingAgent) -> [TabHook] {
        let name = agent.rawValue
        let state = { (event: String, matcher: String?, state: String) in
            TabHook(event: event, matcher: matcher, arguments: ["integrations", "report", name, state])
        }
        let context = TabHook(event: "SessionStart", matcher: nil, arguments: AgentIntegrations.contextArguments)
        switch agent {
        case .claude:
            return [context, state("UserPromptSubmit", nil, "working"), state("PreToolUse", nil, "working"),
                    state("Notification", "permission_prompt|elicitation_dialog", "blocked"),
                    state("Stop", nil, "idle"), state("SessionEnd", nil, "ended")]
        case .codex:
            return [context, state("UserPromptSubmit", nil, "working"), state("PreToolUse", nil, "working"),
                    state("PermissionRequest", nil, "blocked"), state("Stop", nil, "idle"),
                    state("SessionEnd", nil, "ended")]
        case .opencode, .pi:
            return []
        }
    }

    /// The hook as an agent's JSON lists it, running `cli`.
    func group(cli: URL) -> [String: Any] {
        var group: [String: Any] = ["hooks": [[
            "type": "command",
            "command": Executable.commandLine([cli.path] + arguments),
            "timeout": 3,
        ]]]
        if let matcher { group["matcher"] = matcher }
        return group
    }
}

/// An agent's JSON file holding `hooks`, such as Claude Code's
/// `settings.json` or Codex's `hooks.json`: an object of event names, each a
/// list of matcher groups whose `hooks` list commands.
struct HookDocument {
    private(set) var root: [String: Any]

    /// A hook Tab wrote, as found in the file.
    struct Found: Hashable {
        var hook: TabHook
        var program: URL
    }

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
        if let hooks = root["hooks"], !(hooks is [String: Any]) {
            throw CLIError("\(url.path) has a \"hooks\" that is not an object; fix it before Tab changes it")
        }
        return HookDocument(root: root)
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

    private var hooks: [String: Any] { root["hooks"] as? [String: Any] ?? [:] }

    /// Tab's hooks in the file.
    var tabHooks: [Found] {
        hooks.flatMap { event, groups -> [Found] in
            ((groups as? [Any]) ?? []).flatMap { group -> [Found] in
                let matcher = (group as? [String: Any])?["matcher"] as? String
                return Self.handlers(group).compactMap(Self.command).compactMap { command in
                    Self.parse(command).map { Found(hook: TabHook(event: event, matcher: matcher, arguments: $0.arguments),
                                                    program: $0.program) }
                }
            }
        }
    }

    /// Replaces Tab's hooks, in every event, with `hooks` running `cli`.
    mutating func setTabHooks(_ wanted: [TabHook], cli: URL) {
        var hooks = self.hooks
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let kept = groups.compactMap { group -> Any? in
                guard var object = group as? [String: Any], let handlers = object["hooks"] as? [Any] else { return group }
                let others = handlers.filter { Self.parse(Self.command($0) ?? "") == nil }
                guard others.count != handlers.count else { return group }
                if others.isEmpty { return nil }
                object["hooks"] = others
                return object
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        for hook in wanted {
            hooks[hook.event] = ((hooks[hook.event] as? [Any]) ?? []) + [hook.group(cli: cli)]
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
    }

    private static func handlers(_ group: Any) -> [Any] {
        (group as? [String: Any])?["hooks"] as? [Any] ?? []
    }

    private static func command(_ handler: Any) -> String? {
        (handler as? [String: Any])?["command"] as? String
    }

    /// The `tab` and its arguments, for a command Tab wrote; `nil` for others.
    /// Commands of older builds count too, so installing replaces them.
    static func parse(_ command: String) -> (program: URL, arguments: [String])? {
        guard let words = try? Executable.commandArguments(command), words.count >= 2,
              (words[0] as NSString).lastPathComponent == Executable.cli else { return nil }
        let arguments = Array(words.dropFirst())
        let current = arguments.count >= 2 && arguments[0] == "integrations" && ["context", "report"].contains(arguments[1])
        let older = ["agent-context", "agent-event"].contains(arguments[0])
        guard current || older else { return nil }
        return (URL(fileURLWithPath: words[0]), arguments)
    }
}
