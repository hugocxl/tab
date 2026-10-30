import AppKit
import Darwin
import TabClient
import TabCore

/// Answers `app.sock`: `tab <folder>`, a second launch handing its folder
/// over, and `tab browser`.
@MainActor
public final class AppSocketHandler {
    unowned let model: AppModel
    private var server: AppSocketServer?

    public init(model: AppModel) {
        self.model = model
    }

    /// Listens on the profile's `app.sock`.
    public func listen() throws {
        guard server == nil else { return }
        let socket = model.dirs.appSocket
        server = try AppSocketServer(socket: socket) { [weak self] request in
            await self?.handle(request) ?? .failed("Tab is closing")
        }
    }

    public func close() {
        server?.close()
        server = nil
    }

    public func handle(_ request: AppRequest) async -> AppReply {
        switch request {
        case .open(let path):
            return open(path)
        case .browser(let command, let args):
            do {
                return .ok(try await model.browserAutomation.handle(command: command, args: args))
            } catch {
                return .failed(error.localizedDescription)
            }
        case .unknown(let type):
            return .failed("unknown command \(type)")
        }
    }

    /// Selects the folder's project, adding it first when it isn't one, and
    /// brings the window forward. An empty path only brings the window.
    func open(_ path: String) -> AppReply {
        defer { model.presenter?.bringToFront() }
        guard !path.isEmpty else { return .ok(.bool(true)) }
        let resolved = URL(fileURLWithPath: TabDirs.expandHome(path)).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failed("\(path) is not a folder")
        }
        guard model.addProject(resolved) != nil else { return .failed("Could not open \(path)") }
        return .ok(.bool(true))
    }
}

/// One app per profile: a second launch hands its folder to the running app
/// over `app.sock` and exits.
public enum SingleInstance {
    /// Takes the profile lock, or hands the launch to its owner. A missing
    /// answer is an error, never permission to start another app.
    public static func claim(folder: String?, dirs: TabDirs, patience: TimeInterval = 2) throws -> ProfileLock? {
        try FileManager.default.createDirectory(at: dirs.root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(dirs.root.appendingPathComponent("app.lock").path,
                                     O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return ProfileLock(descriptor: descriptor) }
        let code = errno
        Darwin.close(descriptor)
        guard code == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        _ = try handOver(folder: folder, dirs: dirs, patience: patience)
        return nil
    }

    /// Hands `folder` (or nothing, to bring the window forward) to an app
    /// already running in `dirs`, allowing its socket time to start.
    public static func handOver(folder: String?, dirs: TabDirs, patience: TimeInterval = 2) throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, patience)
        while true {
            do {
                let answer = try AppSocket.call(socket: dirs.appSocket, .open(path: folder ?? ""), timeout: max(0.001, patience))
                guard answer == .bool(true) else { throw ModelError("unexpected reply") }
                return true
            } catch AppSocketError.notRunning where ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: min(0.02, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            } catch AppSocketError.failed(let message) where message != "invalid reply from Tab" {
                return true
            } catch {
                throw ModelError("Tab is already running but did not answer: \(error.localizedDescription)")
            }
        }
    }

    /// The folder a launch was asked to open: the first argument that is one.
    public static func folder(in arguments: [String]) -> String? {
        for argument in arguments.dropFirst() where !argument.hasPrefix("-") {
            let path = URL(fileURLWithPath: argument).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return path
            }
        }
        return nil
    }
}

/// Holds an app's profile for its lifetime. The lock file stays in place so
/// later launches always contend for the same inode.
public final class ProfileLock: @unchecked Sendable {
    private let descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }
}
