import Foundation
import TabClient
import TabCore

extension AppModel {
    /// The user's computers as this app sees them: this Mac, where the user
    /// sits, then every remote server in Settings.
    var infrastructure: Infrastructure {
        let seat = Infrastructure.Computer(id: ServerId.local.description, name: Self.thisMac.name, role: .seat,
                                           machine: Self.thisMac)
        let servers = settings.servers.map { entry in
            Infrastructure.Computer(
                id: entry.id.description, name: entry.name, role: entry.isTabServer ? .tabServer : .sshHost,
                ssh: entry.sshCommand == nil ? entry.interactiveSSHCommand : nil,
                sshCommand: entry.sshCommand, address: resolvedAddresses[entry.ssh], group: entry.group,
                machine: serverMachines[entry.id])
        }
        return Infrastructure(computers: [seat] + servers)
    }

    private static let thisMac = MachineInfo.current()

    /// Sends every connected server the user's computers, marking which one
    /// it is, so its agents know where they run. Resolves SSH addresses first.
    func describeInfrastructure() {
        resolveAddresses()
        let description = infrastructure
        for (server, connection) in connections {
            guard let main = connection.main, connection.state.isReady else { continue }
            let received = description.received(by: server.description)
            guard describedInfrastructure[server] != received else { continue }
            describedInfrastructure[server] = received
            Task {
                do {
                    try await main.describeInfrastructure(received)
                } catch {
                    // A server that predates it still works, without telling its agents.
                    Log.app.debug("server \(server.description, privacy: .public) kept no infrastructure: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Looks up each destination with `ssh -G` once, off the main thread,
    /// then describes the computers again with the addresses.
    private func resolveAddresses() {
        let pending = settings.servers.filter { $0.sshCommand == nil && !$0.ssh.isEmpty && resolvedAddresses[$0.ssh] == nil }
        guard !pending.isEmpty else { return }
        for entry in pending { resolvedAddresses[entry.ssh] = "" }
        Task.detached { [weak self] in
            var found: [String: String] = [:]
            for entry in pending {
                let port = entry.port.flatMap { UInt16(exactly: $0) }
                guard let target = try? SSHTarget(destination: entry.ssh, port: port, identity: entry.identityFile),
                      let login = try? target.login() else { continue }
                found[entry.ssh] = port.map { "\(login) -p \($0)" } ?? login
            }
            guard !found.isEmpty else { return }
            let resolved = found
            await MainActor.run { [weak self] in
                guard let self else { return }
                resolvedAddresses.merge(resolved) { _, new in new }
                describeInfrastructure()
            }
        }
    }
}
