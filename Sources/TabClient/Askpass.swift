import Darwin
import Foundation
import TabCore
import TabProtocol

/// ssh asks the running program for a remote server's password: the
/// program's own executable is ssh's `SSH_ASKPASS`, and in askpass mode it
/// fetches the answer from the running program through a private socket.
/// Passwords stay in that program's memory; nothing is written to disk.
public final class AskpassServer: @unchecked Sendable {
    /// Where the running program answers; the executable runs as askpass when set.
    public static let socketVariable = "TAB_ASKPASS_SOCKET"
    /// Which answer ssh asks for. It is only in the environment of this
    /// program's ssh runs.
    public static let tokenVariable = "TAB_ASKPASS_TOKEN"

    private struct Answer {
        var password: String?
        /// The destination's `user@host`; a password prompt naming any other
        /// login, such as a jump host's, gets nothing.
        var login: String?
        /// A new host's key prompt the user approved, answered `yes` once.
        var approvedHostKey: String?
        /// The latest host key prompt ssh asked about, for the user to approve.
        var offeredHostKey: String?
        var asksHostKeys = false
    }

    public let socket: URL
    /// The program ssh runs; the running executable by default.
    public let program: String
    private let lock = NSLock()
    private var answers: [String: Answer] = [:]
    private var tokens: [String: String] = [:]
    private var listener: UnixSocketListener?

    /// - Parameter socket: a short path only this user can reach, such as in
    ///   the profile folder.
    public init(socket: URL, program: String? = nil) {
        self.socket = socket
        self.program = program ?? Executable.currentPathForAskpass()
    }

    deinit {
        listener?.close()
    }

    /// How ssh asks for `server`'s password, answering only prompts that
    /// name `login`. Nothing listens until a password is set.
    public func askpass(for server: String, login: String) -> Askpass {
        let token = lock.withLock { () -> String in
            let token = token(for: server)
            answers[token, default: Answer()].login = login
            return token
        }
        return askpass(token: token)
    }

    /// Like `askpass(for:login:)`, also offering a new host's key prompt to
    /// `offeredHostKey(for:)` and answering `yes` to one the user approved.
    public func askpassWithHostKey(for server: String, login: String?, approved: String?) throws -> Askpass {
        try listen()
        let token = lock.withLock { () -> String in
            let token = token(for: server)
            var answer = answers[token, default: Answer()]
            answer.login = login ?? answer.login
            answer.asksHostKeys = true
            answer.approvedHostKey = approved
            answer.offeredHostKey = nil
            answers[token] = answer
            return token
        }
        return askpass(token: token)
    }

    /// The host key prompt ssh asked about last for `server`, if any.
    public func offeredHostKey(for server: String) -> String? {
        lock.withLock { tokens[server].flatMap { answers[$0]?.offeredHostKey } }
    }

    public func setPassword(_ password: String, for server: String) throws {
        try listen()
        lock.withLock { answers[token(for: server), default: Answer()].password = password }
    }

    public func hasPassword(for server: String) -> Bool {
        lock.withLock { tokens[server].flatMap { answers[$0]?.password } != nil }
    }

    public func forgetPassword(for server: String) {
        lock.withLock {
            guard let token = tokens[server] else { return }
            answers[token]?.password = nil
        }
    }

    private func askpass(token: String) -> Askpass {
        Askpass(program: program, environment: [Self.socketVariable: socket.path, Self.tokenVariable: token])
    }

    /// Call with the lock held.
    private func token(for server: String) -> String {
        if let token = tokens[server] { return token }
        let token = UUID().uuidString.lowercased()
        tokens[server] = token
        return token
    }

    /// Answers on the socket from now on; only this user can open it.
    private func listen() throws {
        try lock.withLock {
            guard listener == nil else { return }
            let listener = try UnixSocketListener(path: socket.path)
            chmod(socket.path, 0o600)
            self.listener = listener
            let thread = Thread { [weak self] in
                while let client = try? listener.accept() {
                    self?.respond(client)
                }
            }
            thread.name = "TabClient.askpass"
            thread.start()
        }
    }

    /// Reads a token, a newline and ssh's prompt to the end, then writes the
    /// answer, or nothing to refuse.
    private func respond(_ client: FileDescriptorStream) {
        defer { client.close() }
        var request = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while request.count <= 16 * 1024 {
            let count = (try? chunk.withUnsafeMutableBytes { try client.read(into: $0) }) ?? 0
            guard count > 0 else { break }
            request.append(contentsOf: chunk[0 ..< count])
        }
        let text = String(decoding: request, as: UTF8.self)
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let token = String(parts.first ?? "")
        let prompt = parts.count > 1 ? String(parts[1]) : ""
        let reply = lock.withLock { () -> String? in
            guard var answer = answers[token] else { return nil }
            let reply = Self.answer(&answer, prompt: prompt)
            answers[token] = answer
            return reply
        }
        try? client.write(Data((reply ?? "").utf8))
    }

    /// A key's passphrase never leaves this computer, so ssh's passphrase
    /// prompt gets the password. A password goes to a host, so only a prompt
    /// for exactly the destination's login gets it. Anything else, such as a
    /// jump host's prompt or trusting an unknown host, is refused.
    private static func answer(_ answer: inout Answer, prompt: String) -> String? {
        if answer.asksHostKeys, isHostKeyPrompt(prompt) {
            if answer.approvedHostKey == prompt {
                answer.approvedHostKey = nil
                return "yes"
            }
            answer.offeredHostKey = prompt
            return nil
        }
        let wanted = prompt.hasPrefix("Enter passphrase for key '")
            || answer.login.map { asksPassword(of: $0, prompt: prompt) } == true
        return wanted ? answer.password : nil
    }

    static func isHostKeyPrompt(_ prompt: String) -> Bool {
        guard prompt.hasPrefix("The authenticity of host '") else { return false }
        let fingerprint = prompt.split(separator: "\n").contains { line in
            guard let range = line.range(of: " key fingerprint is") else { return false }
            var rest = line[range.upperBound...]
            while rest.first == ":" { rest = rest.dropFirst() }
            return rest.trimmingCharacters(in: .whitespaces).hasPrefix("SHA256:")
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return fingerprint && trimmed.hasSuffix("Are you sure you want to continue connecting (yes/no/[fingerprint])?")
    }

    /// ssh starts a password prompt with the login it is for: `user@host's
    /// password: `, or `(user@host) ` before the server's own words.
    static func asksPassword(of login: String, prompt: String) -> Bool {
        if prompt.hasPrefix(login),
           prompt.dropFirst(login.count).trimmingCharacters(in: .whitespaces) == "'s password:" {
            return true
        }
        let prefix = "(\(login)) "
        guard prompt.hasPrefix(prefix) else { return false }
        return prompt.dropFirst(prefix.count).lowercased().contains("password")
    }

    // MARK: Askpass mode

    /// Answers one ssh prompt by asking the running program, when this
    /// process was started as askpass: with `TAB_ASKPASS_SOCKET` set, or as
    /// `tab --askpass <prompt>`. Returns the exit status, or `nil` when this
    /// isn't an askpass run. Call it first thing in `main`.
    public static func runIfRequested(arguments: [String] = CommandLine.arguments,
                                      environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32? {
        guard let socket = environment[socketVariable], !socket.isEmpty else { return nil }
        var prompt = arguments.dropFirst()
        if prompt.first == "--askpass" { prompt = prompt.dropFirst() }
        let token = environment[tokenVariable] ?? ""
        guard let answer = try? ask(socket: socket, token: token, prompt: prompt.joined(separator: " ")),
              !answer.isEmpty else { return 1 }
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        return 0
    }

    static func ask(socket: String, token: String, prompt: String) throws -> String {
        let stream = try FileDescriptorStream.connect(unixSocket: socket)
        defer { stream.close() }
        try stream.write(Data("\(token)\n\(prompt)".utf8))
        shutdown(stream.writeDescriptor, SHUT_WR)
        var answer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = try chunk.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count > 0 else { break }
            answer.append(contentsOf: chunk[0 ..< count])
        }
        return String(decoding: answer, as: UTF8.self)
    }
}

extension Executable {
    /// The running executable's path, which ssh runs as askpass.
    static func currentPathForAskpass() -> String {
        currentURL()?.path ?? CommandLine.arguments[0]
    }
}
