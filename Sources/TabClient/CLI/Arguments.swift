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
    case manage(ManageInvocation)
    case mobile(CLIMobile)
    case browser(BrowserInvocation)
    /// Installs the agent skill into agent folders and these folders.
    case installSkills([String])
    /// Joins stdin and stdout to the server, for clients on other computers.
    case stdio(BridgeStart)
    /// Answers an ssh prompt for the running app.
    case askpass(String)
}

public enum CLIMobile: Hashable, Sendable {
    case status
    case enable(port: UInt16?)
    case disable
    case pair(addresses: [String])
    case revoke(device: String)
}

/// A server management command: `server`, `project`, `session`, `worktree`,
/// `settings`, `activity`, `git`, `files` or `exec`.
public struct ManageInvocation: Hashable, Sendable {
    public var json: Bool
    public var action: ManageAction
}

public enum ManageAction: Hashable, Sendable {
    case server(CLIServer)
    case project(CLIProject)
    case session(CLISession)
    case worktree(CLIWorktree)
    case settingsGet
    case settingsSet(key: String, value: String)
    case activityList
    case activityAck([UInt64])
    case git(project: String, action: String)
    case files(project: String, action: String)
    case exec(project: String, argv: [String], timeoutMs: UInt32)
}

public enum CLIServer: Hashable, Sendable {
    case start
    case status
    case stop(force: Bool)
}

public enum CLIProject: Hashable, Sendable {
    case list
    case add(directory: String, name: String?, create: Bool, reuse: Bool)
    case rename(project: String, name: String)
    case delete(String)
}

/// Session commands. A missing session or project means the terminal this
/// command runs in.
public enum CLISession: Hashable, Sendable {
    case list(project: String?, all: Bool)
    /// `command` is typed into the new terminal, followed by Return.
    case create(project: String?, directory: String?, size: Size, command: String?)
    case end(String?)
    case discard(String?)
    case send(session: String?, text: String)
    case keys(session: String?, bytes: Data)
    case readScreen(session: String?, lines: Int, saved: Bool)
    /// `before` 0 starts at the newest rows.
    case history(session: String?, before: UInt64, limit: UInt16, saved: Bool)
    case search(session: String?, query: String, before: UInt64, limit: UInt16, ignoreCase: Bool, saved: Bool)
    case wait(session: String?, until: CLIWaitUntil, timeoutMs: UInt32)
}

public enum CLIWaitUntil: Hashable, Sendable {
    case text(String, ignoreCase: Bool)
    case exit
}

public enum CLIWorktree: Hashable, Sendable {
    case list(String)
    /// `base == nil` checks out an existing branch.
    case create(project: String, name: String, branch: String, base: String?, directory: String?, hooks: Bool)
    case checkoutPullRequest(project: String, number: UInt64, name: String?, directory: String?, hooks: Bool)
    case register(project: String, directory: String)
    case remove(worktree: String, force: Bool, hooks: Bool)
}

/// Reads `tab`'s arguments (without the program name).
public enum CLIParser {
    public static func parse(_ arguments: [String]) throws -> CLIInvocation {
        guard arguments.first == "--host" else {
            return CLIInvocation(host: nil, command: try command(arguments))
        }
        guard arguments.count >= 2 else { throw CLIError("usage: tab --host DESTINATION COMMAND") }
        let rest = Array(arguments.dropFirst(2))
        if rest.first == "--host" { throw CLIError("duplicate option --host") }
        let host: SSHTarget
        do {
            host = try SSHTarget(destination: arguments[1])
        } catch {
            throw CLIError(String(describing: error))
        }
        let command = try command(rest)
        switch command {
        case .help, .version, .buildInfo, .stdio, .open, .browser, .installSkills, .askpass:
            throw CLIError("--host can't be combined with \(rest.first ?? "no command")")
        case .manage, .mobile:
            return CLIInvocation(host: host, command: command)
        }
    }

    static func command(_ arguments: [String]) throws -> CLICommand {
        switch arguments.first {
        case nil: return .help(CLIHelp.root)
        case "--askpass": return .askpass(arguments.dropFirst().joined(separator: " "))
        default: break
        }
        if arguments.count == 1 {
            switch arguments[0] {
            case "--help", "-h": return .help(CLIHelp.root)
            case "--version", "-V": return .version
            case "--build-info": return .buildInfo
            default: break
            }
        }
        let group = arguments[0]
        let rest = Array(arguments.dropFirst())
        let wantsHelp = rest.last == "--help" || rest.last == "-h"
        switch group {
        case "help":
            guard let topic = rest.first else { return .help(CLIHelp.root) }
            guard rest.count == 1, let text = CLIHelp.topic(topic) else {
                throw CLIError("unknown command; run tab --help")
            }
            return .help(text)
        case "mobile":
            return wantsHelp ? .help(CLIHelp.mobile) : .mobile(try mobile(rest))
        case "stdio":
            if wantsHelp { return .help(CLIHelp.stdio) }
            switch rest {
            case []: return .stdio(.ifNeeded)
            case ["--no-start"]: return .stdio(.never)
            default: throw CLIError("usage: tab stdio [--no-start]")
            }
        case "install-skills":
            return wantsHelp ? .help(CLIHelp.installSkills) : .installSkills(try installSkills(rest))
        case "browser":
            return try BrowserParser.parse(rest)
        default:
            if arguments.count == 1, namesFolder(group) { return .open(group) }
            do {
                return .manage(try ManageParser.parse(arguments))
            } catch let help as HelpRequested {
                return .help(help.text)
            }
        }
    }

    /// A word that isn't an option or a command name opens as a folder.
    static func namesFolder(_ word: String) -> Bool {
        !word.isEmpty && !word.hasPrefix("-") && CLIHelp.topic(word) == nil && word != "help"
    }

    static func mobile(_ arguments: [String]) throws -> CLIMobile {
        if arguments.isEmpty { return .status }
        if arguments == ["enable"] { return .enable(port: nil) }
        if arguments.count == 3, arguments[0] == "enable", arguments[1] == "--port" {
            guard let port = UInt16(arguments[2]), port >= 1024 else {
                throw CLIError("port must be a number from 1024 to 65535")
            }
            return .enable(port: port)
        }
        if arguments == ["disable"] { return .disable }
        if arguments.count == 2, arguments[0] == "revoke", !arguments[1].isEmpty { return .revoke(device: arguments[1]) }
        guard arguments.first == "pair" else { throw CLIError("unknown mobile command; run tab mobile --help") }
        let options = Array(arguments.dropFirst())
        var addresses: [String] = []
        for index in stride(from: 0, to: options.count, by: 2) {
            guard options[index] == "--address", index + 1 < options.count else {
                throw CLIError("usage: tab mobile pair [--address HOST]...")
            }
            let address = options[index + 1]
            do {
                try Validation.pairingHosts([address])
            } catch {
                throw CLIError("--address \(address): use a DNS name or an IPv4 address, without a port")
            }
            addresses.append(address)
        }
        guard addresses.count <= Limits.maxPairingHosts else {
            throw CLIError("a pairing code holds at most \(Limits.maxPairingHosts) addresses")
        }
        return .pair(addresses: addresses)
    }

    static func installSkills(_ arguments: [String]) throws -> [String] {
        guard arguments.count.isMultiple(of: 2) else { throw CLIError("usage: tab install-skills [--dir DIR]...") }
        return try stride(from: 0, to: arguments.count, by: 2).map { index in
            guard arguments[index] == "--dir", !arguments[index + 1].isEmpty else {
                throw CLIError("usage: tab install-skills [--dir DIR]...")
            }
            return arguments[index + 1]
        }
    }
}

// MARK: - Management commands

enum ManageParser {
    static func parse(_ arguments: [String]) throws -> ManageInvocation {
        let group = arguments.first ?? ""
        guard let usage = CLIHelp.topic(group) else { throw CLIError("unknown command; run tab --help") }
        if (2 ... 3).contains(arguments.count), arguments.last == "--help" || arguments.last == "-h" {
            throw HelpRequested(text: usage)
        }
        let verb = arguments.count > 1 ? arguments[1] : ""
        let rest = Array(arguments.dropFirst(2))
        let (values, flags) = options(group, verb)
        let options = try Options(rest, values: values, flags: flags)
        let action: ManageAction
        switch group {
        case "server": action = .server(try server(verb, options))
        case "project": action = .project(try project(verb, options))
        case "session": action = .session(try session(verb, options))
        case "worktree": action = .worktree(try worktree(verb, options))
        case "settings":
            switch verb {
            case "get":
                try options.count(0)
                action = .settingsGet
            case "set":
                try options.count(2)
                action = .settingsSet(key: options.words[0], value: options.words[1])
            default: throw CLIError(usage)
            }
        case "activity":
            switch verb {
            case "list":
                try options.count(0)
                action = .activityList
            case "ack" where !options.words.isEmpty:
                action = .activityAck(try options.words.map { word in
                    guard let id = UInt64(word) else { throw CLIError("event IDs must be integers") }
                    return id
                })
            default: throw CLIError(usage)
            }
        case "git" where !verb.isEmpty && !verb.hasPrefix("-"), "files" where !verb.isEmpty && !verb.hasPrefix("-"):
            try options.count(1)
            action = group == "git" ? .git(project: verb, action: options.words[0])
                : .files(project: verb, action: options.words[0])
        case "exec" where !verb.isEmpty && !verb.hasPrefix("-") && !options.words.isEmpty:
            action = .exec(project: verb, argv: options.words,
                           timeoutMs: try options.number("--timeout-ms", default: 30000, 1 ... 300_000))
        default:
            throw CLIError(usage)
        }
        return ManageInvocation(json: options.flag("--json"), action: action)
    }

    /// Options that take a value, and flags, of `group verb`.
    static func options(_ group: String, _ verb: String) -> ([String], [String]) {
        switch (group, verb) {
        case ("project", "add"): (["--name"], ["--create", "--reuse"])
        case ("project", "delete"), ("session", "end"), ("session", "discard"): ([], ["--yes"])
        case ("worktree", "remove"): ([], ["--yes", "--force", "--hooks"])
        case ("server", "stop"): ([], ["--force"])
        case ("session", "list"): (["--project"], ["--all"])
        case ("session", "create"): (["--directory", "--cols", "--rows"], [])
        case ("session", "read-screen"): (["--lines"], ["--saved"])
        case ("session", "history"): (["--before", "--limit"], ["--saved"])
        case ("session", "search"): (["--before", "--limit"], ["--saved", "--ignore-case"])
        case ("session", "wait"): (["--text", "--timeout", "--timeout-ms"], ["--exit", "--ignore-case"])
        case ("worktree", "create"): (["--branch", "--base", "--directory"], ["--existing", "--hooks"])
        case ("worktree", "checkout-pr"): (["--name", "--directory"], ["--hooks"])
        case ("exec", _): (["--timeout-ms"], [])
        default: ([], [])
        }
    }

    static func server(_ verb: String, _ options: Options) throws -> CLIServer {
        try options.count(0)
        switch verb {
        case "start": return .start
        case "status": return .status
        case "stop": return .stop(force: options.flag("--force"))
        default: throw CLIError(CLIHelp.server)
        }
    }

    static func project(_ verb: String, _ options: Options) throws -> CLIProject {
        switch verb {
        case "list":
            try options.count(0)
            return .list
        case "add":
            try options.count(1)
            return .add(directory: options.words[0], name: options.values["--name"], create: options.flag("--create"),
                        reuse: options.flag("--reuse"))
        case "rename":
            try options.count(2)
            return .rename(project: options.words[0], name: options.words[1])
        case "delete":
            try options.count(1)
            try options.confirm()
            return .delete(options.words[0])
        default:
            throw CLIError(CLIHelp.project)
        }
    }

    static func session(_ verb: String, _ options: Options) throws -> CLISession {
        if verb == "list" {
            try options.count(0)
            return .list(project: options.values["--project"], all: options.flag("--all"))
        }
        if verb == "create" { return try createSession(options) }
        let arguments: Int
        switch verb {
        case "send", "send-keys", "search": arguments = 1
        case "end", "discard", "read-screen", "history", "wait": arguments = 0
        default: throw CLIError(CLIHelp.session)
        }
        // The session ID comes first and may be left out inside a Tab terminal.
        let given = options.words.count - arguments
        guard given == 0 || given == 1 else {
            throw CLIError("wrong number of arguments; run tab <command> --help")
        }
        let session = given == 1 ? options.words[0] : nil
        if let session, !SessionSelector.isValid(session) {
            throw CLIError("session ID must be a UUID or a start of one with at least 4 characters")
        }
        let argument = { options.words[given] }
        let saved = options.flag("--saved")
        switch verb {
        case "end":
            try options.confirm()
            return .end(session)
        case "discard":
            try options.confirm()
            return .discard(session)
        case "send":
            return .send(session: session, text: argument())
        case "send-keys":
            return .keys(session: session, bytes: try key(argument()))
        case "wait":
            return .wait(session: session, until: try until(options), timeoutMs: try waitTimeout(options))
        case "read-screen":
            return .readScreen(session: session, lines: try options.number("--lines", default: 50,
                                                                            1 ... Int(Limits.maxRows)),
                               saved: saved)
        case "history":
            return .history(session: session, before: try options.number("--before", default: 0, 0 ... UInt64.max),
                            limit: try options.number("--limit", default: 200, 1 ... 500), saved: saved)
        default:
            let query = argument()
            let limit: UInt16 = try options.number("--limit", default: 100, 1 ... 500)
            do {
                try Validation.search(query: query, maxResults: limit)
            } catch {
                throw CLIError("search query must contain 1 to \(Limits.maxSearchQuery) bytes")
            }
            return .search(session: session, query: query,
                           before: try options.number("--before", default: 0, 0 ... UInt64.max), limit: limit,
                           ignoreCase: options.flag("--ignore-case"), saved: saved)
        }
    }

    /// `session create [project] [options] [-- COMMAND...]`.
    static func createSession(_ options: Options) throws -> CLISession {
        let split = options.literal ?? options.words.count
        let project = options.words[..<split]
        guard project.count <= 1 else { throw CLIError(CLIHelp.session) }
        let command = options.words[split...].joined(separator: " ")
        if options.literal != nil, command.trimmingCharacters(in: .whitespaces).isEmpty {
            throw CLIError("missing command after --")
        }
        let size = Size(cols: try options.number("--cols", default: 80, 1 ... Limits.maxCols),
                        rows: try options.number("--rows", default: 24, 1 ... Limits.maxRows))
        return .create(project: project.first, directory: options.values["--directory"], size: size,
                       command: options.literal == nil ? nil : command)
    }

    /// `--timeout SECONDS` or `--timeout-ms N`, 30 seconds by default and at most an hour.
    static func waitTimeout(_ options: Options) throws -> UInt32 {
        let maximum: UInt32 = 3_600_000
        guard let seconds = options.values["--timeout"] else {
            return try options.number("--timeout-ms", default: 30000, 1 ... maximum)
        }
        guard options.values["--timeout-ms"] == nil else {
            throw CLIError("--timeout and --timeout-ms cannot be combined")
        }
        guard let value = Double(seconds), value.isFinite, value > 0, value * 1000 <= Double(maximum) else {
            throw CLIError("invalid value for --timeout; use seconds, at most 3600")
        }
        return max(1, UInt32((value * 1000).rounded()))
    }

    static func until(_ options: Options) throws -> CLIWaitUntil {
        switch (options.values["--text"], options.flag("--exit")) {
        case (let text?, false): return .text(text, ignoreCase: options.flag("--ignore-case"))
        case (nil, true) where !options.flag("--ignore-case"): return .exit
        default: throw CLIError("use either --text TEXT [--ignore-case] or --exit")
        }
    }

    static func worktree(_ verb: String, _ options: Options) throws -> CLIWorktree {
        switch verb {
        case "list":
            try options.count(1)
            return .list(options.words[0])
        case "register":
            try options.count(2)
            return .register(project: options.words[0], directory: options.words[1])
        case "create":
            try options.count(2)
            let name = options.words[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw CLIError("worktree name must not be empty") }
            if options.flag("--existing"), options.values["--base"] != nil {
                throw CLIError("--base and --existing cannot be combined")
            }
            return .create(project: options.words[0], name: name, branch: options.values["--branch"] ?? name,
                           base: options.flag("--existing") ? nil : options.values["--base"] ?? "HEAD",
                           directory: options.values["--directory"], hooks: options.flag("--hooks"))
        case "checkout-pr":
            try options.count(2)
            var number = Substring(options.words[1])
            while number.first == "#" { number = number.dropFirst() }
            guard let parsed = UInt64(number), parsed > 0 else {
                throw CLIError("pull request number must be a positive integer")
            }
            return .checkoutPullRequest(project: options.words[0], number: parsed, name: options.values["--name"],
                                        directory: options.values["--directory"], hooks: options.flag("--hooks"))
        case "remove":
            try options.count(1)
            try options.confirm()
            return .remove(worktree: options.words[0], force: options.flag("--force"), hooks: options.flag("--hooks"))
        default:
            throw CLIError(CLIHelp.worktree)
        }
    }

    static func key(_ key: String) throws -> Data {
        switch key.lowercased() {
        case "escape", "esc": Data([0x1B])
        case "enter", "return": Data([0x0D])
        case "tab": Data([0x09])
        case "ctrl+c", "ctrl-c": Data([0x03])
        case "ctrl+d", "ctrl-d": Data([0x04])
        case "ctrl+z", "ctrl-z": Data([0x1A])
        case "backspace": Data([0x7F])
        default: throw CLIError("unsupported key; use Escape, Enter, Tab, Ctrl+C, Ctrl+D, Ctrl+Z or Backspace")
        }
    }
}

/// `tab <group> --help` while parsing a management command.
struct HelpRequested: Error {
    let text: String
}

/// A command's words, options with values, and flags. `--` ends options;
/// any other word starting with a dash that isn't one of the command's
/// options is refused.
struct Options {
    var words: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []
    /// How many words came before `--`, if it was given.
    var literal: Int?

    init(_ arguments: [String], values known: [String], flags knownFlags: [String]) throws {
        var iterator = arguments.makeIterator()
        while let word = iterator.next() {
            if word == "--" {
                literal = words.count
                while let rest = iterator.next() { words.append(rest) }
                break
            }
            if known.contains(word) {
                guard let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                    throw CLIError("missing value for \(word)")
                }
                guard values.updateValue(value, forKey: word) == nil else { throw CLIError("duplicate option") }
            } else if knownFlags.contains(word) || word == "--json" {
                guard flags.insert(word).inserted else { throw CLIError("duplicate option") }
            } else if word.hasPrefix("-") {
                throw CLIError("unknown option \(word); use -- before literal arguments")
            } else {
                words.append(word)
            }
        }
    }

    func count(_ expected: Int) throws {
        guard words.count == expected else { throw CLIError("wrong number of arguments; run tab <command> --help") }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }

    func confirm() throws {
        guard flag("--yes") else { throw CLIError("this deletes data or ends terminals; pass --yes to confirm") }
    }

    func number<T: FixedWidthInteger>(_ name: String, default value: T, _ range: ClosedRange<T>) throws -> T {
        guard let text = values[name] else { return value }
        guard let number = T(text), range.contains(number) else { throw CLIError("invalid value for \(name)") }
        return number
    }
}

/// Session IDs on the command line: a whole UUID, or a unique start of one.
public enum SessionSelector {
    public static func isValid(_ text: String) -> Bool {
        if UUID(uuidString: text) != nil { return true }
        return text.count >= 4 && text.count < 36
            && text.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0) }
    }

    /// The one session whose ID is or starts with `text`.
    public static func resolve(_ text: String, among sessions: [SessionId]) throws -> SessionId {
        if let id = SessionId(string: text) { return id }
        let prefix = text.lowercased()
        let matches = Set(sessions.filter { $0.description.hasPrefix(prefix) })
        guard let first = matches.first else { throw CLIError("no session starts with \(text)") }
        guard matches.count == 1 else { throw CLIError("more than one session starts with \(text); use more characters") }
        return first
    }
}
