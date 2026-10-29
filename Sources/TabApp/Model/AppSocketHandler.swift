import AppKit
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
        let socket = model.dirs.appSocket
        try? FileManager.default.removeItem(at: socket)
        server = try AppSocketServer(socket: socket) { [weak self] request in
            await self?.handle(request) ?? .failed("Tab is closing")
        }
    }

    public func close() {
        server?.close()
        server = nil
        try? FileManager.default.removeItem(at: model.dirs.appSocket)
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
            return .failed("unsupported request \(type); update Tab")
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
    /// Hands `folder` (or nothing, to bring the window forward) to an app
    /// already running in `dirs`. Returns whether one answered.
    public static func handOver(folder: String?, dirs: TabDirs) -> Bool {
        let socket = dirs.appSocket
        guard FileManager.default.fileExists(atPath: socket.path) else { return false }
        do {
            _ = try AppSocket.call(socket: socket, .open(path: folder ?? ""), timeout: 2)
            return true
        } catch AppSocketError.notRunning {
            return false
        } catch AppSocketError.failed {
            return true
        } catch {
            return false
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
