import Foundation
import TabClient
import TabCore
import TabProtocol

/// `tab simulator` and `tab forward`.
enum Simulators {
    static func run(_ command: CLISimulator, client: ServerClient, json: Bool) async throws {
        switch command {
        case .list:
            let simulators = try await client.listSimulators()
            Output.list(simulators.map(record), columns: ["id", "platform", "name", "runtime", "state"], json: json)
        case .boot(let name):
            let simulator = try await resolve(name, client: client)
            _ = try await client.simulatorAction(.boot, on: simulator.simulator)
            Output.ok(json: json)
        case .shutDown(let name):
            let simulator = try await resolve(name, client: client)
            _ = try await client.simulatorAction(.shutDown, on: simulator.simulator)
            Output.ok(json: json)
        case .action(let name, let action):
            let simulator = try await resolve(name, client: client)
            _ = try await client.simulatorAction(action, on: simulator.simulator)
            Output.ok(json: json)
        case .drive(let name, let drive, let output):
            let simulator = try await resolve(name, client: client)
            let result = try await client.simulatorDrive(drive, on: simulator.simulator)
            try print(result, output: output, flat: drive.snapshot?.interactiveOnly ?? false, json: json)
        }
    }

    private static func print(_ result: SimulatorDriveResult, output: CLISimulatorOutput, flat: Bool, json: Bool) throws {
        if let image = result.image {
            if let file = output.file {
                let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
                do {
                    try image.write(to: url)
                } catch {
                    throw CLIError("can't write \(file): \(error.localizedDescription)")
                }
                if let screen = result.screen {
                    let n = SimulatorTarget.number
                    Output.line("\(url.path) \(n(screen.width))x\(n(screen.height)) points")
                } else {
                    Output.ok(json: json)
                }
            } else {
                FileHandle.standardOutput.write(image)
            }
            return
        }
        if json {
            try Output.wire(result)
        } else {
            Output.line(SimulatorOutput.text(result, frames: output.frames, flat: flat))
        }
    }

    private static func record(_ simulator: SimulatorInfo) -> JSONValue {
        .object([
            "id": .string(simulator.simulator.id),
            "platform": .string(simulator.simulator.platform.rawValue),
            "name": .string(simulator.name),
            "runtime": .string(simulator.runtime),
            "state": .string(simulator.booted ? "running" : "shut down"),
        ])
    }

    /// The simulator `name` names by ID or name, or the only running one.
    static func resolve(_ name: String?, client: ServerClient) async throws -> SimulatorInfo {
        let simulators = try await client.listSimulators()
        guard let name else {
            let running = simulators.filter(\.booted)
            guard running.count == 1, let only = running.first else {
                throw CLIError(running.isEmpty ? "no simulator is running; start one with tab simulator boot SIMULATOR"
                    : "\(running.count) simulators are running; pick one with --simulator")
            }
            return only
        }
        if let simulator = simulators.first(where: { $0.simulator.id == name || $0.simulator.id.lowercased() == name.lowercased() }) {
            return simulator
        }
        let named = simulators.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard named.count <= 1 else {
            throw CLIError("\(named.count) simulators are named \(name); use an ID from tab simulator list")
        }
        guard let simulator = named.first else { throw CLIError("no simulator named \(name); see tab simulator list") }
        return simulator
    }

    // MARK: Forwarding

    static func forward(remote: UInt16, local: UInt16?, client: ServerClient, target: Target) async throws {
        let forwarder: PortForwarder
        do {
            forwarder = try PortForwarder(remotePort: remote, localPort: local) { port in
                try await client.openTunnel(host: "localhost", port: port)
            }
        } catch {
            throw CLIError("\(error)")
        }
        let place = target.isRemote ? "the server's" : "this computer's server's"
        Output.line("Forwarding 127.0.0.1:\(forwarder.localPort) to \(place) localhost:\(remote). Press Control-C to stop.")
        while !(await client.waitUntilClosed(timeout: 24 * 60 * 60)) {}
        forwarder.stop()
        throw CLIError("the connection to the server closed")
    }
}
