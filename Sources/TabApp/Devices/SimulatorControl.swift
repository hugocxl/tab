import Foundation
import TabCore

/// One iOS, iPadOS, watchOS, tvOS or visionOS simulator on this Mac.
struct SimulatorDevice: Hashable, Sendable {
    enum State: String, Sendable {
        case shutdown = "Shutdown"
        case booting = "Booting"
        case booted = "Booted"
        case shuttingDown = "Shutting Down"
        case unknown
    }

    var udid: String
    var name: String
    /// The OS it runs, such as "iOS 27.0".
    var runtime: String
    var state: State
    /// When it last ran, if ever.
    var lastUsed: Date?

    var isBooted: Bool { state == .booted }
}

/// Which way up a device is held. Its screen's surface stays in the panel's
/// native portrait; the system draws rotated content into it.
enum DeviceOrientation: String, CaseIterable, Sendable {
    case portrait
    case landscapeLeft
    case portraitUpsideDown
    case landscapeRight

    /// Quarter turns counterclockwise from portrait, as the device is held.
    var quarterTurns: Int {
        switch self {
        case .portrait: return 0
        case .landscapeLeft: return 1
        case .portraitUpsideDown: return 2
        case .landscapeRight: return 3
        }
    }

    init(quarterTurns: Int) {
        let turns = ((quarterTurns % 4) + 4) % 4
        self = Self.allCases.first { $0.quarterTurns == turns } ?? .portrait
    }

    var isLandscape: Bool { quarterTurns % 2 == 1 }

    /// A point on the screen as the user sees it, as fractions of its width
    /// and height from the top left, on the panel's portrait surface.
    func panelPoint(_ upright: CGPoint) -> CGPoint {
        switch self {
        case .portrait: return upright
        case .landscapeLeft: return CGPoint(x: 1 - upright.y, y: upright.x)
        case .portraitUpsideDown: return CGPoint(x: 1 - upright.x, y: 1 - upright.y)
        case .landscapeRight: return CGPoint(x: upright.y, y: 1 - upright.x)
        }
    }
}

/// Lists, boots and configures simulators with `xcrun simctl` and
/// `devicectl`, off the main thread.
enum SimulatorControl {
    /// The selected Xcode's Developer folder.
    static func developerDirectory() throws -> String {
        if let path = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !path.isEmpty { return path }
        let output = try runSync("/usr/bin/xcode-select", ["-p"])
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw SimulatorError.unavailable("Xcode is not installed")
        }
        guard FileManager.default.fileExists(atPath: path + "/usr/bin/simctl") else {
            throw SimulatorError.unavailable("Simulators need Xcode, not only the Command Line Tools")
        }
        return path
    }

    /// The available simulators, booted first, then the most recently used.
    static func devices() async throws -> [SimulatorDevice] {
        let output = try await simctl(["list", "devices", "available", "--json"])
        return try parse(Data(output.utf8))
    }

    static func boot(_ udid: String) async throws {
        do {
            _ = try await simctl(["boot", udid])
        } catch SimulatorError.unavailable(let message) where message.contains("current state: Booted") {
            return
        }
    }

    static func shutdown(_ udid: String) async throws {
        _ = try await simctl(["shutdown", udid])
    }

    /// Whether the device shows its dark appearance.
    static func isDark(_ udid: String) async throws -> Bool {
        try await simctl(["ui", udid, "appearance"]).trimmingCharacters(in: .whitespacesAndNewlines) == "dark"
    }

    static func setDark(_ udid: String, _ dark: Bool) async throws {
        _ = try await simctl(["ui", udid, "appearance", dark ? "dark" : "light"])
    }

    static func openURL(_ udid: String, _ url: String) async throws {
        _ = try await simctl(["openurl", udid, url])
    }

    /// The way the device is held; lying flat reads as the last upright
    /// orientation.
    static func orientation(_ udid: String) async throws -> DeviceOrientation {
        try parseOrientation(Data(try await devicectl(["device", "orientation", "get", "--device", udid]).utf8))
    }

    /// Turns the device, returning how it is held now.
    static func setOrientation(_ udid: String, _ orientation: DeviceOrientation) async throws -> DeviceOrientation {
        let output = try await devicectl(["device", "orientation", "set", "--device", udid, orientation.rawValue])
        return try parseOrientation(Data(output.utf8))
    }

    // MARK: Parsing

    private struct OrientationResult: Decodable {
        struct Result: Decodable {
            var deviceOrientationNonFlat: String?
            var deviceOrientation: String?
        }
        var result: Result
    }

    /// The orientation in `devicectl device orientation` JSON output.
    static func parseOrientation(_ data: Data) throws -> DeviceOrientation {
        let result = try JSONDecoder().decode(OrientationResult.self, from: data).result
        let name = result.deviceOrientationNonFlat ?? result.deviceOrientation ?? ""
        return DeviceOrientation(rawValue: name) ?? .portrait
    }

    private struct DeviceList: Decodable {
        var devices: [String: [Entry]]
    }

    private struct Entry: Decodable {
        var udid: String
        var name: String
        var state: String
        var isAvailable: Bool?
        var lastUsedAt: String?
    }

    /// The devices in `simctl list devices --json` output.
    static func parse(_ data: Data) throws -> [SimulatorDevice] {
        let list = try JSONDecoder().decode(DeviceList.self, from: data)
        let dates = ISO8601DateFormatter()
        let devices = list.devices.flatMap { runtime, entries in
            entries.filter { $0.isAvailable ?? true }.map { entry in
                SimulatorDevice(
                    udid: entry.udid, name: entry.name, runtime: runtimeName(runtime),
                    state: SimulatorDevice.State(rawValue: entry.state) ?? .unknown,
                    lastUsed: entry.lastUsedAt.flatMap { dates.date(from: $0) }
                )
            }
        }
        return devices.sorted { a, b in
            if a.isBooted != b.isBooted { return a.isBooted }
            if a.lastUsed != b.lastUsed { return (a.lastUsed ?? .distantPast) > (b.lastUsed ?? .distantPast) }
            if a.runtime != b.runtime { return a.runtime.compare(b.runtime, options: .numeric) == .orderedDescending }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" reads "iOS 27.0".
    static func runtimeName(_ identifier: String) -> String {
        guard let range = identifier.range(of: "SimRuntime.") else { return identifier }
        let parts = identifier[range.upperBound...].split(separator: "-")
        guard let platform = parts.first else { return identifier }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(platform) : "\(platform) \(version)"
    }

    // MARK: Running

    private static func simctl(_ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            _ = try developerDirectory()
            return try runSync("/usr/bin/xcrun", ["simctl"] + arguments)
        }.value
    }

    /// Runs `devicectl` with JSON output on stdout, which Apple keeps stable.
    private static func devicectl(_ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            _ = try developerDirectory()
            return try runSync("/usr/bin/xcrun", ["devicectl"] + arguments + ["--quiet", "--json-output", "-"])
        }.value
    }

    /// Runs a tool to completion, returning its output or throwing its error
    /// output. Call off the main thread.
    private static func runSync(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw SimulatorError.unavailable("\(tool) could not run: \(error.localizedDescription)")
        }
        var errorData = Data()
        let errorReader = DispatchWorkItem { errorData = errors.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .utility).async(execute: errorReader)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errorReader.wait()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            Log.app.error("\(tool, privacy: .public) \(arguments.joined(separator: " "), privacy: .public) failed: \(message, privacy: .public)")
            throw SimulatorError.unavailable(message.isEmpty ? "\(tool) exited with \(process.terminationStatus)" : message)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
