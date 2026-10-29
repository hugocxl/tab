import Foundation
import TabCore

/// A program that answers ssh's prompts, such as the running app answering
/// with a password typed this session. ssh runs it with the prompt as its
/// only argument and reads the answer from its output.
public struct Askpass: Hashable, Sendable {
    public var program: String
    /// More environment for the program, such as which answer to give.
    public var environment: [String: String]

    public init(program: String, environment: [String: String] = [:]) {
        self.program = program
        self.environment = environment
    }
}

/// A program that connects ssh to the other computer, such as through a
/// proxy. ssh runs it with the host and port after `arguments`.
public struct ProxyCommand: Hashable, Sendable {
    public var program: String
    public var arguments: [String]
    /// More environment for the program, such as which proxy to use.
    public var environment: [String: String]

    public init(program: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.program = program
        self.arguments = arguments
        self.environment = environment
    }

    /// ssh expands `%` tokens, then runs the line with the user's shell.
    var option: String {
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: #"'\''"#).replacingOccurrences(of: "%", with: "%%") + "'"
        }
        return "ProxyCommand=" + ([program] + arguments).map(quote).joined(separator: " ") + " %h %p"
    }
}

/// Whether connecting may start a server that isn't running there.
public enum BridgeStart: Hashable, Sendable {
    /// Start the server if it isn't running, like most commands.
    case ifNeeded
    /// Only use a running server, like `tab server status`.
    case never
}

/// Another computer reached with ssh: an `ssh_config` alias, `host`,
/// `user@host` or `ssh://user@host:port`, with an optional user, port and
/// identity file; or a custom command prefix that the remote command is
/// appended to as one argument, such as `vm ssh devbox --`.
public struct SSHTarget: Hashable, Sendable, CustomStringConvertible {
    /// The computer as the user named it.
    public private(set) var destination: String
    public var user: String?
    public var port: UInt16?
    /// Logs in with this private key file only.
    public var identity: String?
    /// Lets ssh ask once for a password or a key's passphrase. Without it ssh
    /// never prompts (`BatchMode=yes`).
    public var askpass: Askpass?
    public var proxy: ProxyCommand?
    /// Lets the askpass program see a new host's key prompt.
    public var hostKeyPrompt = false
    /// Runs this instead of ssh; it must accept ssh's arguments.
    public var program: String?
    private var customArguments: [String]?

    /// Refuses destinations ssh could read as an option or that would split
    /// into several arguments.
    public init(destination: String, user: String? = nil, port: UInt16? = nil, identity: String? = nil) throws {
        guard !destination.isEmpty else { throw SSHTargetError.invalid("SSH destination must not be empty") }
        guard !destination.hasPrefix("-") else { throw SSHTargetError.invalid("SSH destination must not start with -") }
        guard !destination.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control })
        else { throw SSHTargetError.invalid("SSH destination must not contain spaces or control characters") }
        if let user {
            guard !user.isEmpty, !user.hasPrefix("-"), !user.contains(where: { $0.isWhitespace || $0 == "@" })
            else { throw SSHTargetError.invalid("SSH user must be one word") }
        }
        self.destination = destination
        self.user = user
        self.port = port
        self.identity = identity
    }

    /// A command prefix, split like a shell would split it (quotes and
    /// backslashes, no expansions), that reaches the other computer.
    public static func customCommand(_ source: String) throws -> SSHTarget {
        let words: [String]
        do {
            words = try Executable.commandArguments(source)
        } catch let error as ExecutableError {
            throw SSHTargetError.invalid(error.description)
        }
        var target = try SSHTarget(destination: "custom")
        target.destination = source.trimmingCharacters(in: .whitespacesAndNewlines)
        target.program = words[0]
        target.customArguments = Array(words.dropFirst())
        return target
    }

    public var isCustomCommand: Bool { customArguments != nil }

    /// The computer as the user named it, for messages.
    public var description: String { destination }

    /// The program that runs: the target's own, else `TAB_SSH`, else `ssh`.
    public func executable(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let program { return program }
        if let ssh = environment["TAB_SSH"], !ssh.isEmpty { return ssh }
        return "ssh"
    }

    /// The arguments that run `remote` there. Prompts reach only an askpass
    /// program, since nobody may be there to answer them.
    public func arguments(remote: String, proxy: ProxyCommand? = nil) -> [String] {
        if let customArguments { return customArguments + [remote] }
        var arguments = ["-T"]
        let prompts = askpass == nil ? ["BatchMode=yes"] : ["BatchMode=no", "NumberOfPasswordPrompts=1"]
        for option in prompts + Self.options {
            arguments += ["-o", option]
        }
        if hostKeyPrompt {
            for option in ["StrictHostKeyChecking=ask", "FingerprintHash=sha256", "ControlPath=none"] {
                arguments += ["-o", option]
            }
        }
        if let proxy {
            arguments += ["-o", "ControlPath=none", "-o", proxy.option]
        }
        if let port { arguments += ["-p", String(port)] }
        if let user { arguments += ["-l", user] }
        if let identity { arguments += ["-i", identity, "-o", "IdentitiesOnly=yes"] }
        return arguments + ["--", destination, remote]
    }

    /// The environment ssh needs on top of this process's. Custom commands
    /// manage their own settings and authentication, so they get none.
    /// `SSH_ASKPASS_REQUIRE=force` makes ssh use the askpass program even
    /// without a display.
    public func environment(proxy: ProxyCommand? = nil) -> [String: String] {
        guard !isCustomCommand else { return [:] }
        var environment = proxy?.environment ?? [:]
        if let askpass {
            environment["SSH_ASKPASS"] = askpass.program
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment.merge(askpass.environment) { $1 }
        }
        return environment
    }

    /// A process that runs `remote` there through the same ssh and login as
    /// the bridge, such as an installer. A proxy is used only when ssh's
    /// config has no route of its own.
    public func process(remote: String) throws -> Process {
        let proxy = self.proxy.flatMap { proxy in (try? hasOwnRoute()) == true ? nil : proxy }
        let process = Process()
        process.executableURL = try Self.resolve(executable())
        process.arguments = arguments(remote: remote, proxy: proxy)
        process.environment = ProcessInfo.processInfo.environment.merging(environment(proxy: proxy)) { $1 }
        return process
    }

    /// A program path, or a name found on `PATH`.
    static func resolve(_ program: String,
                        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin") throws -> URL {
        if program.contains("/") {
            let url = URL(fileURLWithPath: program)
            guard Executable.isExecutableFile(url) else { throw SSHTargetError.missingProgram(program) }
            return url
        }
        for folder in path.split(separator: ":") where !folder.isEmpty {
            let url = URL(fileURLWithPath: String(folder)).appendingPathComponent(program)
            if Executable.isExecutableFile(url) { return url }
        }
        throw SSHTargetError.missingProgram(program)
    }

    // MARK: ssh -G

    /// The login ssh prompts for, `user@host`, as its config resolves this
    /// destination. A password prompt naming another login, such as a jump
    /// host's, isn't for this destination.
    public func login() throws -> String {
        guard let login = Self.login(fromConfig: try config()) else {
            throw SSHTargetError.invalid("no SSH user or host for \(destination)")
        }
        return login
    }

    /// Whether ssh's config reaches this destination its own way, with
    /// `ProxyJump` or `ProxyCommand`.
    public func hasOwnRoute() throws -> Bool {
        Self.route(fromConfig: try config())
    }

    /// The identity file ssh's config names for this destination, if it exists.
    public func defaultIdentity() throws -> String? {
        Self.identity(fromConfig: try config(), home: NSHomeDirectory())
    }

    /// `ssh -G`, which reads the config and contacts nothing.
    private func config() throws -> String {
        guard !isCustomCommand else {
            throw SSHTargetError.unsupported("Custom commands manage their own SSH settings and authentication")
        }
        let process = Process()
        process.executableURL = try Self.resolve(executable())
        var arguments = ["-G"]
        if let port { arguments += ["-p", String(port)] }
        if let user { arguments += ["-l", user] }
        process.arguments = arguments + ["--", destination]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SSHTargetError.invalid("could not read the SSH settings for \(destination)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func route(fromConfig config: String) -> Bool {
        config.split(separator: "\n").contains { line in
            guard let space = line.firstIndex(of: " ") else { return false }
            let key = line[..<space]
            let value = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            return (key == "proxyjump" || key == "proxycommand") && value != "none"
        }
    }

    /// `user@host` from `ssh -G` output; ssh names a host key alias in its
    /// prompts instead of the host name when there is one.
    static func login(fromConfig config: String) -> String? {
        func value(_ key: String) -> String? {
            for line in config.split(separator: "\n") {
                guard let space = line.firstIndex(of: " "), line[..<space] == key else { continue }
                return line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        guard let user = value("user"), let host = value("hostkeyalias") ?? value("hostname") else { return nil }
        return "\(user)@\(host)"
    }

    static func identity(fromConfig config: String, home: String) -> String? {
        for line in config.split(separator: "\n") where line.hasPrefix("identityfile ") {
            let value = line.dropFirst("identityfile ".count).trimmingCharacters(in: .whitespaces)
            let path: String
            if value.hasPrefix("~/") {
                path = (home as NSString).appendingPathComponent(String(value.dropFirst(2)))
            } else if value.hasPrefix("%d/") {
                path = (home as NSString).appendingPathComponent(String(value.dropFirst(3)))
            } else if value.contains("%") || value.hasPrefix("~") || value == "none" {
                continue
            } else {
                path = value
            }
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue {
                return path
            }
        }
        return nil
    }

    /// Keepalives end a dead connection instead of hanging. A shared master
    /// would keep running with our pipes, and the user's remote command and
    /// forwards belong to interactive sessions, not to the bridge.
    static let options = [
        "ConnectTimeout=10",
        "ServerAliveInterval=15",
        "ServerAliveCountMax=3",
        "ControlMaster=no",
        "RemoteCommand=none",
        "ClearAllForwardings=yes",
    ]
}

public enum SSHTargetError: Error, Hashable, Sendable, CustomStringConvertible {
    case invalid(String)
    case unsupported(String)
    /// The ssh program, or a custom command's, isn't there.
    case missingProgram(String)

    public var description: String {
        switch self {
        case .invalid(let message), .unsupported(let message): message
        case .missingProgram(let program): "\(program) was not found"
        }
    }
}

extension SSHTargetError: LocalizedError {
    public var errorDescription: String? { description }
}

// MARK: - The bridge

/// The bridge to a server on another computer: `tab stdio` runs there,
/// joined to that computer's server, and its stdin and stdout carry the
/// protocol unchanged, so version negotiation stays end to end. It writes a
/// ready line first, so the client can skip what the remote shell prints.
public enum Bridge {
    /// Starts the ready line; the bridge version and a newline follow.
    static let ready = Array("TAB-STDIO/".utf8)
    static let version = Array("1".utf8)
    /// The most a remote shell may print before the ready line.
    static let maxNoise = 64 * 1024
    static let maxVersion = 16
    static let maxDetail = 300
    /// What `tab stdio --no-start` reports when no server runs.
    static let notRunning = "the server isn't running"
    static let notFound = ["tab: not found", "tab: command not found", "command not found: tab"]
    /// ssh's own words when the network or the host's sshd fails it.
    static let unreachable = [
        "Could not resolve hostname", "connect to host", "Connection closed by", "Connection reset by",
        "Connection timed out", "kex_exchange_identification", "No route to host", "Network is unreachable",
    ]

    /// The line `tab stdio` writes before relaying.
    public static var readyLine: Data { Data(ready + version + [0x0A]) }

    /// The command a remote login shell runs to start the bridge. It runs
    /// under `sh` whatever the login shell is, and also looks where the
    /// installer and the app put `tab`.
    public static func command(_ start: BridgeStart) -> String {
        let path = #"export PATH="$PATH:$HOME/.local/bin:/Applications/Tab.app/Contents/MacOS""#
        switch start {
        case .ifNeeded: return "sh -lc '\(path); exec tab stdio'"
        case .never: return "sh -lc '\(path); exec tab stdio --no-start'"
        }
    }

    /// How a bridge's transport ended, to explain a connection that failed
    /// before the bridge was ready.
    public struct Exit: Hashable, Sendable {
        /// Such as 255 from ssh itself or 127 from a shell that can't find `tab`.
        public var status: Int32?
        /// The end of the transport's error output.
        public var stderr: String

        public init(status: Int32?, stderr: String) {
            self.status = status
            self.stderr = stderr
        }
    }

    enum NotReady: Equatable {
        /// The stream ended first, after the shell printed this.
        case ended([UInt8])
        /// The shell printed more than `maxNoise` bytes first.
        case noisy([UInt8])
        /// A bridge answered with a version this build can't speak.
        case version([UInt8])
    }

    /// Finds the ready line in what the transport prints first.
    struct ReadyLine {
        private(set) var seen: [UInt8] = []
        private var start: Int?
        private var searched = 0

        /// Adds bytes; returns the bytes after the ready line once complete,
        /// or why it can't come.
        mutating func push(_ bytes: some Collection<UInt8>) -> Result<[UInt8], NotReadyError>? {
            seen.append(contentsOf: bytes)
            guard let start = start ?? find() else {
                return seen.count >= maxNoise + ready.count ? .failure(NotReadyError(.noisy(seen))) : nil
            }
            if start > maxNoise { return .failure(NotReadyError(.noisy(Array(seen[..<start])))) }
            let lineStart = start + ready.count
            let line = seen[lineStart...]
            if let end = line.firstIndex(of: 0x0A) {
                let found = Array(seen[lineStart ..< end])
                if found == version { return .success(Array(seen[(end + 1)...])) }
                return .failure(NotReadyError(.version(found)))
            }
            if line.count > maxVersion { return .failure(NotReadyError(.version(Array(line.prefix(maxVersion))))) }
            return nil
        }

        private mutating func find() -> Int? {
            if seen.count >= ready.count, searched <= seen.count - ready.count {
                for index in searched ... (seen.count - ready.count) where seen[index ..< index + ready.count].elementsEqual(ready) {
                    start = index
                    break
                }
            }
            searched = max(0, seen.count - (ready.count - 1))
            return start
        }

        var ended: NotReady { .ended(seen) }
    }

    struct NotReadyError: Error, Equatable {
        let reason: NotReady
        init(_ reason: NotReady) { self.reason = reason }
    }

    /// Explains a transport that ended before the bridge was ready, from its
    /// exit status, its error output and what it printed.
    static func explain(_ exit: Exit, printed: [UInt8]) -> (RemoteReason, String) {
        let stderr = exit.stderr
        func said(_ texts: [String]) -> Bool { texts.contains { stderr.contains($0) } }
        let last = lastLine(Array(stderr.utf8))
        let ssh = exit.status == 255 || exit.status == nil
        let reason: RemoteReason
        if ssh && said(["REMOTE HOST IDENTIFICATION HAS CHANGED"]) {
            reason = .hostKeyChanged
        } else if ssh && said(["Host key verification failed", "host key is known for"]) {
            reason = .hostKeyUnknown
        } else if ssh && said(["Permission denied (", "Too many authentication failures"]) {
            reason = .authenticationFailed
        } else if exit.status == 127 || said(notFound) {
            reason = .notInstalled
        } else if said(["tab: unknown command"]) {
            reason = .incompatible
        } else if said([notRunning]) {
            reason = .notRunning
        } else if !last.isEmpty && (exit.status == 255 || (ssh && said(unreachable))) {
            reason = .unreachable
        } else if !last.isEmpty && exit.status != 0 {
            reason = .bridgeFailed
        } else if !String(decoding: printed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reason = .unexpectedOutput
        } else {
            reason = .bridgeFailed
        }
        let detail: String
        switch reason {
        case .incompatible:
            detail = "it predates remote connections"
        case .unexpectedOutput:
            detail = lastLine(printed)
        case .bridgeFailed where last.isEmpty:
            detail = exit.status.map { "the connection closed before Tab started (exit status \($0))" }
                ?? "the connection closed before Tab started"
        case .bridgeFailed:
            detail = last.hasPrefix("tab: ") ? String(last.dropFirst(5)) : last
        default:
            detail = last
        }
        return (reason, detail)
    }

    /// The last line with text, cleaned up for a one-line message.
    static func lastLine(_ bytes: [UInt8]) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        return String(line.unicodeScalars.filter { $0.properties.generalCategory != .control }.prefix(maxDetail)
            .map(Character.init))
    }
}
