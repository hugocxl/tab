import Foundation

/// What a computer is, so agents can tell the user's Macs apart and pick one
/// for heavy work.
public struct MachineInfo: Hashable, Codable, Sendable {
    /// The computer's name, such as "Hugo's MacBook Air".
    public var name: String
    /// The chip, such as "Apple M2 Pro" or "Intel(R) Core(TM) i5-8500B".
    public var chip: String?
    /// `arm64` or `x86_64`.
    public var architecture: String?
    public var cores: Int?
    public var memoryBytes: UInt64?
    /// Such as "macOS 15.2".
    public var system: String?

    public init(name: String, chip: String? = nil, architecture: String? = nil, cores: Int? = nil,
                memoryBytes: UInt64? = nil, system: String? = nil) {
        self.name = name
        self.chip = chip
        self.architecture = architecture
        self.cores = cores
        self.memoryBytes = memoryBytes
        self.system = system
    }

    /// One line, such as "Apple M2 Pro, arm64, 12 cores, 32 GB, macOS 15.2".
    public var summary: String {
        var parts: [String] = []
        if let chip { parts.append(chip) }
        if let architecture { parts.append(architecture) }
        if let cores { parts.append("\(cores) cores") }
        if let memoryBytes, memoryBytes > 0 {
            parts.append("\(Int((Double(memoryBytes) / 1_073_741_824).rounded())) GB")
        }
        if let system { parts.append(system) }
        return parts.joined(separator: ", ")
    }
}

/// The user's computers as their app describes them to each server it
/// connects to, so the server's agents know where they run, where the user
/// sits, and how to reach the others. The server keeps the last one it got.
public struct Infrastructure: Hashable, Codable, Sendable {
    public struct Computer: Hashable, Codable, Sendable {
        public enum Role: Hashable, Codable, Sendable {
            /// The Mac running the app the user is looking at.
            case seat
            /// A remote Mac running Tab's server.
            case tabServer
            /// A computer reached only with SSH; Tab isn't installed there.
            case sshHost
            /// A role a newer app sent.
            case unknown(String)

            public init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                switch raw {
                case "seat": self = .seat
                case "tabServer": self = .tabServer
                case "sshHost": self = .sshHost
                default: self = .unknown(raw)
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .seat: try container.encode("seat")
                case .tabServer: try container.encode("tabServer")
                case .sshHost: try container.encode("sshHost")
                case .unknown(let raw): try container.encode(raw)
                }
            }
        }

        /// Stable within one app's description.
        public var id: String
        public var name: String
        public var role: Role
        /// The command the seat runs to reach it, such as `ssh mac-mini` or
        /// `ssh -p 2222 me@host`.
        public var ssh: String?
        /// A custom command the seat runs instead of `ssh`.
        public var sshCommand: String?
        /// `user@host`, with `-p PORT` when needed, as the seat's SSH config
        /// resolves it, for computers where the seat's alias doesn't exist.
        public var address: String?
        public var group: String?
        /// What the computer is, when its server told the app.
        public var machine: MachineInfo?

        public init(id: String, name: String, role: Role, ssh: String? = nil, sshCommand: String? = nil,
                    address: String? = nil, group: String? = nil, machine: MachineInfo? = nil) {
            self.id = id
            self.name = name
            self.role = role
            self.ssh = ssh
            self.sshCommand = sshCommand
            self.address = address
            self.group = group
            self.machine = machine
        }
    }

    public var computers: [Computer]
    /// The computer the server receiving this runs on, when the app knows.
    public var receiver: String?

    public init(computers: [Computer], receiver: String? = nil) {
        self.computers = computers
        self.receiver = receiver
    }

    /// The same computers, as the server `receiver` should read them.
    public func received(by receiver: String) -> Infrastructure {
        Infrastructure(computers: computers, receiver: receiver)
    }

    public var seat: Computer? { computers.first { $0.role == .seat } }
}
