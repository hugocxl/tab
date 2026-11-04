import AppKit
import TabClient
import TabCore
import TabProtocol

extension AppModel {
    /// A remote server's forwarded ports, each with a way to stop it, and a
    /// way to add one.
    func portForwardItems(_ server: ServerId) -> [NSMenuItem] {
        var items: [NSMenuItem] = (portForwards[server] ?? [:]).sorted { $0.key < $1.key }.map { remote, forwarder in
            ClosureMenuItem("Stop Forwarding \(remote) → localhost:\(forwarder.localPort)") { [weak self] in
                self?.stopForwarding(remote, on: server)
            }
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(ClosureMenuItem("Forward a Port to This Mac…") { [weak self] in self?.askToForwardPort(on: server) })
        return items
    }

    /// Asks which port of `server` to reach on this Mac.
    func askToForwardPort(on server: ServerId) {
        let name = serverName(server) ?? "the server"
        let alert = NSAlert()
        alert.messageText = "Forward a Port from \(name)"
        alert.informativeText = "Connections to localhost on this Mac reach the same port on \(name), "
            + "such as a phone on your desk reaching its Metro bundler."
        let field = NSTextField(string: "8081")
        field.placeholderString = "Port"
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Forward")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let port = UInt16(field.stringValue.trimmingCharacters(in: .whitespaces)), port > 0 else {
            report(ModelError("A port is a number from 1 to 65535"))
            return
        }
        forwardPort(port, on: server)
    }

    /// Listens on this Mac's `localhost:port`, or a free port when that one is
    /// taken, and tunnels each connection to the server's `localhost:port`.
    func forwardPort(_ port: UInt16, on server: ServerId) {
        guard portForwards[server]?[port] == nil else { return }
        let open: @Sendable (UInt16) async throws -> Tunnel = { [weak self] port in
            guard let api = await self?.sideAPI(server) else {
                throw ModelError("The server isn't connected")
            }
            return try await api.openTunnel(host: "localhost", port: port)
        }
        let forwarder: PortForwarder
        do {
            forwarder = try (try? PortForwarder(remotePort: port, localPort: port, open: open))
                ?? PortForwarder(remotePort: port, localPort: nil, open: open)
        } catch {
            report(error)
            return
        }
        portForwards[server, default: [:]][port] = forwarder
        let name = serverName(server) ?? "the server"
        presenter?.showToast("localhost:\(forwarder.localPort) on this Mac now reaches port \(port) on \(name)", error: false)
    }

    func stopForwarding(_ port: UInt16, on server: ServerId) {
        portForwards[server]?.removeValue(forKey: port)?.stop()
    }
}
