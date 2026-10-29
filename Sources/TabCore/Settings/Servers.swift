import Foundation

/// Another computer whose Tab server this app reaches over SSH.
public struct ServerEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: ServerId
    public var name: String
    /// An SSH destination: a `~/.ssh/config` alias, `user@host`, or
    /// `ssh://user@host:port`. It is fully checked when connecting.
    public var ssh: String
    /// A custom command that opens the connection instead of `ssh`.
    public var sshCommand: String?
    /// The private key to log in with, instead of ssh's own choice.
    public var identityFile: String?
    /// The SSH port, when not the destination's default.
    public var port: Int?
    /// Logs in with a password, which the app asks for and never saves.
    public var passwordLogin: Bool
    /// The group the app lists it under; `nil` leaves it ungrouped.
    public var group: String?

    public init(
        id: ServerId = ServerId(),
        name: String,
        ssh: String,
        sshCommand: String? = nil,
        identityFile: String? = nil,
        port: Int? = nil,
        passwordLogin: Bool = false,
        group: String? = nil
    ) {
        self.id = id
        self.name = name
        self.ssh = ssh
        self.sshCommand = sshCommand
        self.identityFile = identityFile
        self.port = port
        self.passwordLogin = passwordLogin
        self.group = group
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ServerId.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        ssh = try container.value(.ssh, "")
        sshCommand = try container.decodeIfPresent(String.self, forKey: .sshCommand)
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        passwordLogin = try container.value(.passwordLogin, false)
        group = try container.decodeIfPresent(String.self, forKey: .group)
    }

    /// What the connection runs: the custom command, else the destination.
    public var destination: String { sshCommand ?? ssh }

    public func validate() throws {
        if id.isLocal {
            throw SettingsError("servers", "this computer's server ID cannot be listed")
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty || name.utf8.count > 256 || name.hasControlCharacter {
            throw SettingsError("servers", "enter a name of 1–256 bytes without control characters")
        }
        if let command = sshCommand {
            if !ssh.isEmpty || identityFile != nil || passwordLogin || port != nil {
                throw SettingsError(
                    "servers",
                    "custom commands cannot be combined with an SSH destination, identity file, port, or password login"
                )
            }
            do {
                _ = try Executable.commandArguments(command)
            } catch {
                throw SettingsError("servers", "\(error)")
            }
        } else if ssh.trimmingCharacters(in: .whitespaces).isEmpty || ssh.hasControlCharacter {
            throw SettingsError("servers", "enter an SSH destination without control characters")
        }
        if let path = identityFile, path.trimmingCharacters(in: .whitespaces).isEmpty || path.hasControlCharacter {
            throw SettingsError("servers", "enter an identity file path without control characters")
        }
        if let port, !(1...65535).contains(port) {
            throw SettingsError("servers", "enter a port from 1 to 65535")
        }
        if let group, group.trimmingCharacters(in: .whitespaces).isEmpty || group.utf8.count > 256 || group.hasControlCharacter {
            throw SettingsError("servers", "enter a group name of 1–256 bytes without control characters")
        }
    }

    static func validate(_ servers: [ServerEntry]) throws {
        var ids = Set<ServerId>()
        for server in servers {
            try server.validate()
            guard ids.insert(server.id).inserted else {
                throw SettingsError("servers", "server IDs must be unique")
            }
        }
    }
}

extension Settings {
    public mutating func addServer(_ server: ServerEntry, in url: URL) throws {
        servers = try Self.editServers(url) { $0.append(server) }
    }

    /// Replaces the entry that has `server`'s id.
    public mutating func updateServer(_ server: ServerEntry, in url: URL) throws {
        servers = try Self.editServers(url) { servers in
            guard let index = servers.firstIndex(where: { $0.id == server.id }) else {
                throw SettingsError("servers", "this server is no longer listed")
            }
            servers[index] = server
        }
    }

    public mutating func removeServers(_ ids: [ServerId], in url: URL) throws {
        servers = try Self.editServers(url) { servers in servers.removeAll { ids.contains($0.id) } }
    }

    /// Moves the listed servers into `group`, or out of theirs, in their
    /// order, before `before` or at the end. Servers no longer listed are
    /// skipped.
    public mutating func placeServers(_ ids: [ServerId], group: String?, before: ServerId?, in url: URL) throws {
        servers = try Self.editServers(url) { servers in
            var moved = servers.filter { ids.contains($0.id) }
            var kept = servers.filter { !ids.contains($0.id) }
            for index in moved.indices { moved[index].group = group }
            let at = before.flatMap { before in kept.firstIndex { $0.id == before } } ?? kept.count
            kept.insert(contentsOf: moved, at: at)
            servers = kept
        }
    }

    /// Puts each listed server in `group`, or none, where it is.
    public mutating func setServersGroup(_ ids: [ServerId], group: String?, in url: URL) throws {
        servers = try Self.editServers(url) { servers in
            for index in servers.indices where ids.contains(servers[index].id) {
                servers[index].group = group
            }
        }
    }

    /// Every group a server is in, in the order they are listed.
    public var serverGroups: [String] {
        var groups: [String] = []
        for group in servers.compactMap(\.group) where !groups.contains(group) {
            groups.append(group)
        }
        return groups
    }

    /// Changes the list as the file holds it now, so entries edited by hand
    /// since loading are kept.
    private static func editServers(_ url: URL, _ change: (inout [ServerEntry]) throws -> Void) throws -> [ServerEntry] {
        var document = try SettingsDocument.read(url)
        var servers: [ServerEntry] = []
        if let list = document.root["servers"] {
            do {
                servers = try SettingsJSON.decode([ServerEntry].self, from: list)
            } catch {
                throw SettingsError("servers", SettingsJSON.describe(error))
            }
        }
        try change(&servers)
        try ServerEntry.validate(servers)
        if servers.isEmpty {
            document.root["servers"] = nil
        } else {
            try document.replace("servers", servers)
        }
        try document.write(to: url)
        return servers
    }
}
