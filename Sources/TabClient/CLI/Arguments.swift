import Foundation
import TabProtocol

/// A usage mistake, reported as `tab: <message>`.
public struct CLIError: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

extension CLIError: LocalizedError {
    public var errorDescription: String? { message }
}

/// A parsed `tab` command line.
public struct CLIInvocation: Hashable, Sendable {
    /// The other computer whose server the command uses, from a leading `--host`.
    public var host: SSHTarget?
    public var command: CLICommand
}

public enum CLICommand: Hashable, Sendable {
    /// Usage text, which needs no server.
    case help(String)
    case version
    /// This build's version and protocol versions, as JSON.
    case buildInfo
    /// Opens a folder in the app.
    case open(String)
    /// A command for a server: this computer's, or the one `--host` names.
    case manage(ManageInvocation)
    /// Adds a pane or a tab in the app on this computer.
    case pane(CLIPane, json: Bool)
    case browser(BrowserInvocation)
    /// The skill and hooks of the coding agents on this computer.
    case integrations(CLIIntegrations, json: Bool)
    /// Joins stdin and stdout to the server, for clients on other computers.
    case stdio(BridgeStart)
    /// Answers an ssh prompt for the running app.
    case askpass(String)
}

/// A command for a server.
public struct ManageInvocation: Hashable, Sendable {
    public var json: Bool
    public var action: ManageAction
}

public enum ManageAction: Hashable, Sendable {
    case server(CLIServer)
    case project(CLIProject)
    case session(CLISession)
    case worktree(CLIWorktree)
    case mobile(CLIMobile)
    case settingsGet
    case settingsSet(key: String, value: String)
    case activityList
    case activityAck([UInt64])
    case git(project: String, action: String)
    case files(project: String, action: String)
    case exec(project: String, argv: [String], timeoutMs: UInt32)
    case device(CLIDevice)
    /// Exposes the server's `localhost:remote` on this computer until interrupted.
    case forward(remote: UInt16, local: UInt16?)
}

/// The server's simulators and emulators. A missing device means the only
/// running one.
public enum CLIDevice: Hashable, Sendable {
    case list
    case boot(device: String)
    case shutDown(device: String?)
    /// Saves a PNG to `output`, or writes it to stdout.
    case screenshot(device: String?, output: String?)
    /// A tap at a point of the screenshot, in its pixels.
    case tap(device: String?, x: Double, y: Double)
    case type(device: String?, text: String)
    case press(device: String?, button: DeviceButton)
    case open(device: String?, url: String)
}

public enum CLIServer: Hashable, Sendable {
    case start
    case status
    case stop(force: Bool)
}

public enum CLIProject: Hashable, Sendable {
    case list
    case new(directory: String, name: String?, create: Bool, reuse: Bool)
    case rename(project: String, name: String)
    case remove(project: String)
}

/// Terminals on the server. A missing session means the terminal this
/// command runs in; a missing project, its project, else Home.
public enum CLISession: Hashable, Sendable {
    /// `command` is typed into the new terminal, followed by Return.
    case new(project: String?, directory: String?, size: Size, command: String?)
    case list(project: String?, all: Bool)
    case send(session: String?, text: String)
    case press(session: String?, bytes: Data)
    case read(session: String?, lines: Int, saved: Bool)
    /// `before` 0 starts at the newest rows.
    case history(session: String?, before: UInt64, limit: UInt16, saved: Bool)
    case search(session: String?, query: String, before: UInt64, limit: UInt16, ignoreCase: Bool, saved: Bool)
    case wait(session: String?, until: CLIWaitUntil, timeoutMs: UInt32)
    /// Follows sessions starting and ending, agent states and notifications;
    /// `nil` follows every session.
    case events(session: String?)
    /// Ends the terminal, keeping its saved output.
    case stop(session: String?)
    /// Ends the terminal and deletes its saved output.
    case remove(session: String?)
}

public enum CLIWaitUntil: Hashable, Sendable {
    case text(String, ignoreCase: Bool)
    case exit
}

/// A new pane beside the caller's, or a new tab in Home.
public struct CLIPane: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        /// Shows `session`, or starts a terminal in `directory` and types `command`.
        case terminal(session: String?, directory: String?, command: String?)
        case agent(provider: AgentChatProvider)
        /// A copy of the conversation `agent`, or of the caller's.
        case fork(agent: String?)
        case browser(url: String?, profile: String?)
    }

    public var placement: AppPane.Placement
    /// `nil`: the caller's project, else Home. Tabs always go to Home.
    public var project: String?
    public var content: Content
}

public enum CLIWorktree: Hashable, Sendable {
    case list(project: String)
    /// `base == nil` checks out an existing branch.
    case new(project: String, name: String, branch: String, base: String?, directory: String?, hooks: Bool)
    case pullRequest(project: String, number: UInt64, name: String?, directory: String?, hooks: Bool)
    case register(project: String, directory: String)
    case remove(worktree: String, force: Bool, hooks: Bool)
}

public enum CLIMobile: Hashable, Sendable {
    case status
    case enable(port: UInt16?)
    case disable
    case pair(addresses: [String])
    case revoke(device: String)
}

public enum CLIIntegrations: Hashable, Sendable {
    case status
    /// Also writes the skill into each of `directories`.
    case install(directories: [String])
    case remove
    /// Prints what Tab tells an agent starting in one of its terminals.
    case context
    /// An agent's hook reports its state for the terminal it runs in.
    case report(provider: AgentProvider, state: AgentState?)
}

/// Reads `tab`'s arguments (without the program name).
public enum CLIParser {
    public static func parse(_ arguments: [String]) throws -> CLIInvocation {
        guard arguments.first == "--host" else {
            return CLIInvocation(host: nil, command: try command(arguments, remote: false))
        }
        guard arguments.count >= 2 else { throw CLIError("usage: tab --host DESTINATION COMMAND") }
        let rest = Array(arguments.dropFirst(2))
        if rest.first == "--host" { throw CLIError("--host given twice") }
        let host: SSHTarget
        do {
            host = try SSHTarget(destination: arguments[1])
        } catch {
            throw CLIError(String(describing: error))
        }
        return CLIInvocation(host: host, command: try command(rest, remote: true))
    }

    static func command(_ arguments: [String], remote: Bool) throws -> CLICommand {
        guard let first = arguments.first else {
            if remote { throw CLIError("usage: tab --host DESTINATION COMMAND") }
            return .help(CLIHelp.root)
        }
        if first == "--askpass", !remote { return .askpass(arguments.dropFirst().joined(separator: " ")) }
        if arguments.count == 1, !remote {
            switch first {
            case "--help", "-h": return .help(CLIHelp.root)
            case "--version", "-V": return .version
            case "--build-info": return .buildInfo
            default: break
            }
        }
        if first == "help", !remote { return .help(try CLIHelp.topic(Array(arguments.dropFirst()))) }
        guard let group = CLICommands.group(first) else {
            if arguments.count == 1, !remote, namesFolder(first) { return .open(first) }
            if remote, namesFolder(first) { throw CLIError("--host can't open a folder; leave it out") }
            throw CLIError("unknown command \(first); run tab --help")
        }
        let rest = Array(arguments.dropFirst())
        let beforeLiteral = rest.prefix { $0 != "--" }
        let (found, consumed) = group.command(for: rest)
        guard let spec = found else {
            let given = rest.prefix { !$0.hasPrefix("-") }.prefix(consumed + 1)
            if given.count <= consumed || beforeLiteral.contains("--help") || beforeLiteral.contains("-h") {
                return .help(CLIHelp.group(group))
            }
            throw CLIError("unknown command tab \(([group.name] + given).joined(separator: " ")); run tab \(group.name) --help")
        }
        if beforeLiteral.contains("--help") || beforeLiteral.contains("-h")
            || (rest.count == consumed && spec.words.lowerBound > 0) {
            return .help(CLIHelp.command(spec, in: group))
        }
        if remote, spec.place != .server { throw CLIError(spec.place.refusesHost(spec.name)) }
        return try spec.build(try CLIArguments(Array(rest.dropFirst(consumed)), spec: spec))
    }

    /// A word that isn't an option or a command name opens as a folder.
    static func namesFolder(_ word: String) -> Bool {
        !word.isEmpty && !word.hasPrefix("-") && CLICommands.group(word) == nil && word != "help"
    }
}

/// The words, options and flags given to one command. Words starting with a
/// dash are options; `--` ends them, so the words after it are taken as given.
struct CLIArguments {
    let spec: CLICommandSpec
    var words: [String] = []
    /// The words after `--`, for a command that keeps them apart.
    var literal: [String]?
    var values: [String: String] = [:]
    var lists: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ arguments: [String], spec: CLICommandSpec) throws {
        self.spec = spec
        var iterator = arguments.makeIterator()
        while let word = iterator.next() {
            if word == "--" {
                var after: [String] = []
                while let rest = iterator.next() { after.append(rest) }
                if spec.literal { literal = after } else { words += after }
                break
            }
            if spec.values.contains(word) || spec.lists.contains(word) {
                guard let value = iterator.next() else { throw CLIError("missing value for \(word)") }
                if spec.lists.contains(word) {
                    lists[word, default: []].append(value)
                } else if values.updateValue(value, forKey: word) != nil {
                    throw CLIError("\(word) given twice")
                }
            } else if spec.flags.contains(word) || (spec.json && word == "--json") {
                guard flags.insert(word).inserted else { throw CLIError("\(word) given twice") }
            } else if word.hasPrefix("-"), word.count > 1, Double(word) == nil {
                throw CLIError("unknown option \(word) for tab \(spec.name); put -- before words that start with a dash")
            } else {
                words.append(word)
            }
        }
        guard spec.words.contains(words.count) else { throw usage }
    }

    var usage: CLIError { CLIError("usage: " + spec.usage.map { "tab \(spec.name) \($0)" }.joined(separator: "\n   or: ")) }
    var json: Bool { flags.contains("--json") }

    func word(_ index: Int) -> String { words[index] }
    func optional(_ index: Int) -> String? { index < words.count ? words[index] : nil }
    func value(_ name: String) -> String? { values[name] }
    func list(_ name: String) -> [String] { lists[name] ?? [] }
    func flag(_ name: String) -> Bool { flags.contains(name) }

    /// The first word when the command was given one more than `rest`, as
    /// with an optional leading session.
    func leading(before rest: Int) -> String? {
        words.count > rest ? words[0] : nil
    }

    func trailing(_ index: Int, after rest: Int) -> String {
        words[words.count - rest + index]
    }

    func choice(_ index: Int, _ choices: [String]) throws -> String {
        guard choices.contains(words[index]) else { throw usage }
        return words[index]
    }

    func confirm() throws {
        guard flag("--yes") else { throw CLIError("tab \(spec.name) ends terminals or deletes data; pass --yes to confirm") }
    }

    func number<T: FixedWidthInteger>(_ name: String, default value: T, _ range: ClosedRange<T>) throws -> T {
        guard let text = values[name] else { return value }
        guard let number = T(text), range.contains(number) else {
            throw CLIError("\(name) must be a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return number
    }

    /// `--timeout SECONDS` in milliseconds; fractions are allowed.
    func timeout(default seconds: Double, maximum: Double) throws -> UInt32 {
        guard let text = values["--timeout"] else { return UInt32(seconds * 1000) }
        guard let value = Double(text), value.isFinite, value > 0, value <= maximum else {
            throw CLIError("--timeout must be a number of seconds, more than 0 and at most \(Int(maximum))")
        }
        return max(1, UInt32((value * 1000).rounded()))
    }

    /// The session given as the first word, checked to look like one.
    func session(before rest: Int) throws -> String? {
        guard let session = leading(before: rest) else { return nil }
        guard SessionSelector.isValid(session) else { throw CLIError(SessionSelector.invalid) }
        return session
    }
}

/// Session IDs on the command line: a whole UUID, a unique start of one, or a name.
public enum SessionSelector {
    static let invalid = "a session is an ID, a start of one with at least 4 characters, or a name such as wispy-cedar"

    public static func isValid(_ text: String) -> Bool {
        if UUID(uuidString: text) != nil || SessionName.isName(text) { return true }
        return text.count >= 4 && text.count < 36
            && text.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0) }
    }

    /// The one session whose ID is or starts with `text`, or whose name it is.
    public static func resolve(_ text: String, among sessions: [SessionId]) throws -> SessionId {
        if let id = SessionId(string: text) { return id }
        if SessionName.isName(text) {
            let named = Set(sessions.filter { SessionName.of($0) == text })
            guard let first = named.first else { throw CLIError("no session is named \(text)") }
            guard named.count == 1 else { throw CLIError("more than one session is named \(text); use its ID") }
            return first
        }
        let prefix = text.lowercased()
        let matches = Set(sessions.filter { $0.description.hasPrefix(prefix) })
        guard let first = matches.first else { throw CLIError("no session starts with \(text)") }
        guard matches.count == 1 else { throw CLIError("more than one session starts with \(text); use more characters") }
        return first
    }
}
