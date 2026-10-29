import Foundation
import TabClient
import TabProtocol

/// `mobile`: let phones connect, pair them, and revoke them.
enum Mobile {
    static func run(_ command: CLIMobile, client: ServerClient) async throws {
        switch command {
        case .status:
            printState(try await client.remoteAccess())
        case .enable(let port):
            let current = try await client.remoteAccess().settings
            let state = try await client.writeRemoteAccess(RemoteAccessSettings(enabled: true,
                                                                                port: port ?? current.port))
            printState(state)
            if case .failed(let message) = state.status {
                throw CLIError("mobile access could not start: \(message)")
            }
        case .disable:
            var settings = try await client.remoteAccess().settings
            settings.enabled = false
            printState(try await client.writeRemoteAccess(settings))
        case .pair(let addresses):
            try await pair(client, addresses: addresses)
        case .revoke(let prefix):
            let state = try await client.remoteAccess()
            let matches = state.devices.filter { $0.id.description.hasPrefix(prefix.lowercased()) }
            guard let device = matches.first else { throw CLIError("no paired device starts with \(prefix)") }
            guard matches.count == 1 else {
                throw CLIError("more than one device starts with \(prefix); use more characters")
            }
            _ = try await client.revokeDevice(device.id)
            Output.line("Revoked \(Output.escape(device.name)).")
        }
    }

    static func printState(_ state: RemoteAccessState) {
        switch (state.status, state.settings.enabled) {
        case (.listening, _): Output.line("Mobile access: on, listening on port \(state.settings.port)")
        case (.failed(let message), _): Output.line("Mobile access: not listening: \(message)")
        case (.disabled, true): Output.line("Mobile access: starting")
        case (.disabled, false): Output.line("Mobile access: off")
        case (.unknown, _): Output.line("Mobile access: status unknown to this version of tab")
        }
        guard !state.devices.isEmpty else { return Output.line("No paired devices.") }
        Output.line("Paired devices:")
        let now = UInt64(Date().timeIntervalSince1970)
        for device in state.devices {
            let seen = if device.connected {
                "connected"
            } else if let lastSeen = device.lastSeen {
                "last seen \(ago(now > lastSeen ? now - lastSeen : 0))"
            } else {
                "never connected"
            }
            Output.line("  \(device.id.description.prefix(8))  \(Output.escape(device.name))  \(seen)")
        }
    }

    static func ago(_ seconds: UInt64) -> String {
        switch seconds {
        case ..<60: "just now"
        case ..<3600: "\(seconds / 60) min ago"
        case ..<86400: "\(seconds / 3600) h ago"
        default: "\(seconds / 86400) d ago"
        }
    }

    /// Shows a pairing code until a new device pairs, the code expires, or
    /// Ctrl-C closes the connection, which cancels the code.
    static func pair(_ client: ServerClient, addresses: [String]) async throws {
        let known = Set(try await client.remoteAccess().devices.map(\.id))
        let offer = try await client.startPairing(hosts: addresses)
        let link = offer.invite.link
        guard let code = QRCode(link) else { throw CLIError("the pairing link does not fit in a QR code") }
        Output.line(code.terminalText)
        Output.line("""

        Scan with the Tab app on the phone, or open this link on the phone:
        \(link)

        Waiting for the phone. The code expires in 5 minutes; Ctrl-C cancels it.
        """)
        let now = UInt64(Date().timeIntervalSince1970)
        let lifetime = TimeInterval(offer.expiresAt > now ? offer.expiresAt - now : 0)
        let paired: String = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                for await event in client.events {
                    switch event {
                    case .changed(.remoteAccess, _):
                        let state = try await client.remoteAccess()
                        if let device = state.devices.first(where: { !known.contains($0.id) }) {
                            return device.name
                        }
                        if state.pairingExpiresAt == nil { throw CLIError("pairing was cancelled") }
                    case .disconnected, .serverRestarting:
                        throw CLIError("disconnected from the server")
                    default:
                        continue
                    }
                }
                throw CLIError("disconnected from the server")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let name = first else {
                throw CLIError("the pairing code expired")
            }
            return name
        }
        Output.line("Paired \(Output.escape(paired)).")
    }
}
