import Foundation
import TabClient
import TabCore

/// What the Add Server and Edit Server dialog holds, before it is saved.
public struct ServerForm: Equatable, Sendable {
    public var name = ""
    /// A host or `~/.ssh/config` alias, or a whole destination such as
    /// `user@host` or `ssh://user@host:port` when user and port are empty.
    public var host = ""
    public var user = ""
    public var port = ""
    public var identityFile = ""
    public var passwordLogin = false
    /// Kept in memory until Tab quits; empty asks when connecting.
    public var password = ""
    /// Runs this command prefix instead of ssh, when set.
    public var customCommand: String?
    /// Empty leaves it ungrouped.
    public var group = ""

    public init() {}

    /// The form for an existing entry.
    public init(_ entry: ServerEntry) {
        name = entry.name
        group = entry.group ?? ""
        if let command = entry.sshCommand {
            customCommand = command
            return
        }
        (host, user) = Self.splitLogin(entry.ssh)
        port = entry.port.map(String.init) ?? ""
        identityFile = entry.identityFile ?? ""
        passwordLogin = entry.passwordLogin
    }

    /// The SSH destination, or the custom command: what a Test Connection
    /// tried, so a result is shown only for the same form.
    public var probeKey: String {
        if let customCommand { return customCommand.trimmingCharacters(in: .whitespaces) }
        let login = (try? destination()) ?? host.trimmingCharacters(in: .whitespaces)
        let port = port.trimmingCharacters(in: .whitespaces)
        return port.isEmpty ? login : "\(login) -p \(port)"
    }

    /// The settings entry: `id`'s, or a new one. Throws a message to show.
    public func entry(id: ServerId? = nil) throws -> ServerEntry {
        var entry = ServerEntry(id: id ?? ServerId(), name: "", ssh: "")
        if let customCommand {
            let command = customCommand.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { throw ServerFormError("Enter the command that reaches the server") }
            entry.sshCommand = command
        } else {
            entry.ssh = try destination()
            entry.port = try parsedPort()
            let identity = identityFile.trimmingCharacters(in: .whitespaces)
            entry.identityFile = identity.isEmpty ? nil : identity
            entry.passwordLogin = passwordLogin
        }
        let typedName = name.trimmingCharacters(in: .whitespaces)
        entry.name = typedName.isEmpty ? (entry.sshCommand ?? entry.ssh) : typedName
        entry.group = Self.groupName(group)
        do {
            try entry.validate()
        } catch let error as SettingsError {
            throw ServerFormError(error.message.prefix(1).uppercased() + error.message.dropFirst())
        }
        return entry
    }

    /// How the app reaches the entry, before a password or proxy is added.
    public static func target(for entry: ServerEntry, proxy: ProxyCommand? = nil) throws -> SSHTarget {
        if let command = entry.sshCommand { return try SSHTarget.customCommand(command) }
        var target = try SSHTarget(destination: entry.ssh, port: entry.port.map { UInt16($0) }, identity: entry.identityFile)
        target.proxy = proxy
        return target
    }

    /// The SSH destination from host and user. With no user and no port, the
    /// host may itself be `user@host` or `ssh://user@host:port`.
    public func destination() throws -> String {
        let host = host.trimmingCharacters(in: .whitespaces)
        let user = user.trimmingCharacters(in: .whitespaces)
        let port = port.trimmingCharacters(in: .whitespaces)
        let invalid = ServerFormError("Enter an SSH host: a ~/.ssh/config alias, a host name, or an address")
        guard !host.isEmpty else { throw invalid }
        var destination = host
        if !user.isEmpty || !port.isEmpty {
            if host.contains("@") || host.hasPrefix("ssh://") {
                throw ServerFormError("Put the user and port either in the host or in their own fields")
            }
        }
        if !user.isEmpty {
            if user.contains("@") || user.contains(":") { throw ServerFormError("Enter a user name without @ or :") }
            destination = "\(user)@\(host)"
        }
        guard (try? SSHTarget(destination: destination)) != nil else { throw invalid }
        return destination
    }

    private func parsedPort() throws -> Int? {
        let port = port.trimmingCharacters(in: .whitespaces)
        guard !port.isEmpty else { return nil }
        guard let number = Int(port), (1...65535).contains(number) else {
            throw ServerFormError("Use a port from 1 to 65535")
        }
        return number
    }

    /// A typed group name, or none when it is blank.
    public static func groupName(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The host and user fields for a destination. `ssh://` destinations
    /// stay whole in the host field, where they keep their port.
    static func splitLogin(_ destination: String) -> (host: String, user: String) {
        guard !destination.hasPrefix("ssh://"), let at = destination.lastIndex(of: "@") else {
            return (destination, "")
        }
        return (String(destination[destination.index(after: at)...]), String(destination[..<at]))
    }
}

public struct ServerFormError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// A Test Connection from the server dialog.
public enum ConnectionTest: Equatable, Sendable {
    case testing
    /// ssh asked to trust a new host key; this is its prompt.
    case untrustedHost(String)
    case installing
    case notInstalled(String)
    case installFailed(String)
    /// It connected; this is the version of Tab there.
    case succeeded(String)
    case failed(String)

    /// What the dialog says, and whether it is an error, a warning or good news.
    public enum Tone: Sendable { case muted, good, warning, error }

    public var message: (text: String, tone: Tone) {
        switch self {
        case .testing: return ("Testing connection…", .muted)
        case .untrustedHost(let prompt):
            let details = prompt.components(separatedBy: "\nAre you sure you want to continue connecting").first ?? prompt
            return ("\(details)\n\nVerify this fingerprint with your server administrator before trusting it.", .warning)
        case .installing: return ("Installing Tab, then testing the connection…", .muted)
        case .succeeded(let version): return ("Connection succeeded · Tab \(version)", .good)
        case .notInstalled:
            guard let version = RemoteRelease.installableVersion else {
                return ("SSH connected, but Tab isn't installed there. Install a matching build there by hand.", .error)
            }
            return ("SSH connected. Install Tab \(version) there?", .muted)
        case .failed(let error): return (error, .error)
        case .installFailed(let error): return ("Install failed: \(error)", .error)
        }
    }

    public var isRunning: Bool { self == .testing || self == .installing }
}
