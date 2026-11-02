import Foundation
import TabCore

/// One Android Virtual Device on this Mac.
struct AndroidVirtualDevice: Hashable, Sendable {
    /// The AVD's name, as `emulator -avd` takes it.
    var name: String
    /// What to show, such as "Pixel 8 API 35".
    var displayName: String
    /// The Android version it runs, such as "Android API 35".
    var runtime: String
    var isTablet: Bool
}

/// A running emulator, as its discovery file describes it.
struct RunningEmulator: Hashable, Sendable {
    var pid: Int32
    var avd: String
    /// The console port, which names it for adb: `emulator-<port>`.
    var consolePort: Int
    /// The gRPC port, if the control API is on.
    var grpcPort: UInt16?
    /// The bearer token the control API wants, if any.
    var grpcToken: String?
    /// Whether the control API wants signed tokens or TLS, which Tab can't
    /// provide.
    var needsUnsupportedAuth: Bool

    var serial: String { "emulator-\(consolePort)" }
}

/// Finds the Android SDK, its virtual devices and running emulators, and
/// starts and controls emulators. Process launches run off the main thread.
enum AndroidEmulators {
    /// The SDK folder: `ANDROID_HOME`, `ANDROID_SDK_ROOT` or the default.
    static var sdk: URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]].compactMap { $0 }
            + [NSHomeDirectory() + "/Library/Android/sdk"]
        return candidates.lazy.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("emulator/emulator").path) }
    }

    /// The folder holding AVDs.
    static var avdHome: URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["ANDROID_AVD_HOME"] { return URL(fileURLWithPath: path) }
        let user = environment["ANDROID_USER_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".android")
        return user.appendingPathComponent("avd")
    }

    /// Where running emulators write their discovery files on macOS.
    static var discoveryFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
    }

    // MARK: Listing

    /// The AVDs, from their `.ini` files; empty without any.
    static func virtualDevices() -> [AndroidVirtualDevice] {
        let files = (try? FileManager.default.contentsOfDirectory(at: avdHome, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "ini" }.compactMap { file in
            let name = file.deletingPathExtension().lastPathComponent
            let pointer = ini(file)
            let folder = pointer["path"].map { URL(fileURLWithPath: $0) } ?? avdHome.appendingPathComponent("\(name).avd")
            let config = ini(folder.appendingPathComponent("config.ini"))
            return device(name: name, config: config)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func device(name: String, config: [String: String]) -> AndroidVirtualDevice {
        let display = config["avd.ini.displayname"] ?? name.replacingOccurrences(of: "_", with: " ")
        let image = config["image.sysdir.1"] ?? ""
        let api = image.split(separator: "/").first { $0.hasPrefix("android-") }.map { $0.dropFirst("android-".count) }
        let runtime = api.map { "Android API \($0)" } ?? "Android"
        let tablet = (config["hw.device.name"] ?? "").localizedCaseInsensitiveContains("tablet")
            || (config["tag.id"] ?? "").localizedCaseInsensitiveContains("tablet")
        return AndroidVirtualDevice(name: name, displayName: display, runtime: runtime, isTablet: tablet)
    }

    /// The emulators running now whose process is alive.
    static func running() -> [RunningEmulator] {
        let files = (try? FileManager.default.contentsOfDirectory(at: discoveryFolder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file -> RunningEmulator? in
            let stem = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "ini", stem.hasPrefix("pid_"), let pid = Int32(stem.dropFirst(4)),
                  kill(pid, 0) == 0 else { return nil }
            return emulator(pid: pid, ini(file))
        }
    }

    static func emulator(pid: Int32, _ values: [String: String]) -> RunningEmulator? {
        guard let avd = values["avd.name"], let console = values["port.serial"].flatMap(Int.init) else { return nil }
        let token = values["grpc.token"]
        let signed = values["grpc.jwks"] != nil || values["grpc.server_cert"] != nil
        return RunningEmulator(pid: pid, avd: avd, consolePort: console, grpcPort: values["grpc.port"].flatMap(UInt16.init),
                               grpcToken: token, needsUnsupportedAuth: signed && token == nil)
    }

    /// `key=value` lines.
    static func ini(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parseINI(text)
    }

    static func parseINI(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { values[key] = value }
        }
        return values
    }

    // MARK: Controlling

    /// Starts `avd` without a window, with the control API on a free port
    /// behind a token. Returns once the emulator has launched, not booted.
    static func start(_ avd: String) async throws {
        guard let sdk else { throw AndroidError.noSDK }
        let port = try freePort()
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = sdk.appendingPathComponent("emulator/emulator")
            process.arguments = ["-avd", avd, "-no-window", "-no-audio", "-no-boot-anim",
                                 "-grpc", String(port), "-grpc-use-token"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw AndroidError.failed("The emulator could not start: \(error.localizedDescription)")
            }
        }.value
    }

    /// Asks the emulator to shut down, or ends its process without adb.
    static func shutdown(_ emulator: RunningEmulator) async throws {
        do {
            _ = try await adb(emulator, ["emu", "kill"])
        } catch AndroidError.noSDK {
            kill(emulator.pid, SIGTERM)
        }
    }

    /// Turns the emulator a quarter counterclockwise.
    static func rotateLeft(_ emulator: RunningEmulator) async throws {
        _ = try await adb(emulator, ["emu", "rotate"])
    }

    static func isDark(_ emulator: RunningEmulator) async throws -> Bool {
        try await adb(emulator, ["shell", "cmd", "uimode", "night"]).contains("yes")
    }

    static func setDark(_ emulator: RunningEmulator, _ dark: Bool) async throws {
        _ = try await adb(emulator, ["shell", "cmd", "uimode", "night", dark ? "yes" : "no"])
    }

    private static func adb(_ emulator: RunningEmulator, _ arguments: [String]) async throws -> String {
        guard let adb = sdk?.appendingPathComponent("platform-tools/adb"),
              FileManager.default.isExecutableFile(atPath: adb.path) else { throw AndroidError.noSDK }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = adb
            process.arguments = ["-s", emulator.serial] + arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                Log.app.error("adb \(arguments.joined(separator: " "), privacy: .public) failed: \(process.terminationStatus)")
                throw AndroidError.failed("adb \(arguments.first ?? "") failed")
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// A TCP port no one listens on now.
    private static func freePort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw AndroidError.failed("no free port") }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { throw AndroidError.failed("no free port") }
        return UInt16(bigEndian: address.sin_port)
    }
}

enum AndroidError: Error, Equatable, CustomStringConvertible {
    case noSDK
    case unsupportedAuth
    case noControlAPI
    case failed(String)

    var description: String {
        switch self {
        case .noSDK:
            return "The Android SDK wasn't found. Install it with Android Studio or set ANDROID_HOME."
        case .unsupportedAuth:
            return "Another app started this emulator with access keys Tab can't use. Shut it down and start it from Tab."
        case .noControlAPI:
            return "This emulator was started without its control API. Shut it down and start it from Tab."
        case .failed(let reason):
            return reason
        }
    }
}
