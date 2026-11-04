import Foundation
import TabClient
import TabCore
import TabProtocol

/// `tab device` and `tab forward`.
enum Devices {
    static func run(_ command: CLIDevice, client: ServerClient, json: Bool) async throws {
        switch command {
        case .list:
            let devices = try await client.listDevices()
            Output.list(devices.map(record), columns: ["id", "platform", "name", "runtime", "state"], json: json)
        case .boot(let name):
            let device = try await resolve(name, client: client)
            _ = try await client.deviceAction(.boot, on: device.device)
            Output.ok(json: json)
        case .shutDown(let name):
            let device = try await resolve(name, client: client)
            _ = try await client.deviceAction(.shutDown, on: device.device)
            Output.ok(json: json)
        case .screenshot(let name, let output):
            let device = try await resolve(name, client: client)
            let png = try await client.deviceScreenshot(device.device)
            if let output {
                let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
                do {
                    try png.write(to: url)
                } catch {
                    throw CLIError("can't write \(output): \(error.localizedDescription)")
                }
                Output.ok(json: json)
            } else {
                FileHandle.standardOutput.write(png)
            }
        case .tap(let name, let x, let y):
            let device = try await resolve(name, client: client)
            // Taps are fractions of the screen; the screenshot says its size.
            let size = try pngSize(try await client.deviceScreenshot(device.device))
            guard x < size.width, y < size.height else {
                throw CLIError("the screen is \(Int(size.width))×\(Int(size.height)) pixels")
            }
            let point = (x: x / size.width, y: y / size.height)
            _ = try await client.deviceAction(.input([.touch(x: point.x, y: point.y, down: true),
                                                      .touch(x: point.x, y: point.y, down: false)]), on: device.device)
            Output.ok(json: json)
        case .type(let name, let text):
            let device = try await resolve(name, client: client)
            _ = try await client.deviceAction(.type(text), on: device.device)
            Output.ok(json: json)
        case .press(let name, let button):
            let device = try await resolve(name, client: client)
            _ = try await client.deviceAction(.input([.button(button)]), on: device.device)
            Output.ok(json: json)
        case .open(let name, let url):
            let device = try await resolve(name, client: client)
            _ = try await client.deviceAction(.openURL(url), on: device.device)
            Output.ok(json: json)
        }
    }

    private static func record(_ device: DeviceInfo) -> JSONValue {
        .object([
            "id": .string(device.device.id),
            "platform": .string(device.device.platform.rawValue),
            "name": .string(device.name),
            "runtime": .string(device.runtime),
            "state": .string(device.booted ? "running" : "shut down"),
        ])
    }

    /// The device `name` names by ID or name, or the only running one.
    static func resolve(_ name: String?, client: ServerClient) async throws -> DeviceInfo {
        let devices = try await client.listDevices()
        guard let name else {
            let running = devices.filter(\.booted)
            guard running.count == 1, let only = running.first else {
                throw CLIError(running.isEmpty ? "no device is running; start one with tab device boot DEVICE"
                    : "\(running.count) devices are running; pick one with --device")
            }
            return only
        }
        if let device = devices.first(where: { $0.device.id == name || $0.device.id.lowercased() == name.lowercased() }) {
            return device
        }
        let named = devices.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard named.count <= 1 else {
            throw CLIError("\(named.count) devices are named \(name); use an ID from tab device list")
        }
        guard let device = named.first else { throw CLIError("no device named \(name); see tab device list") }
        return device
    }

    /// The width and height in a PNG's header.
    static func pngSize(_ png: Data) throws -> (width: Double, height: Double) {
        let bytes = [UInt8](png.prefix(24))
        guard bytes.count == 24, bytes[0 ..< 8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else {
            throw CLIError("the server's screenshot isn't a PNG")
        }
        func number(_ at: Int) -> Double { Double(bytes[at ..< at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) }
        return (number(16), number(20))
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
