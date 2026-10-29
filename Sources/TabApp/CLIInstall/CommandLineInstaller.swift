import AppKit
import Foundation
import TabCore
import TabProtocol

/// Install Command Line Tool…: links `~/.local/bin/tab` to the `tab` inside
/// the running app's bundle, so the CLI always matches the app.
public enum CommandLineInstaller {
    public struct InstallError: Error, Equatable, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// Installs the link for the running app off the main thread, then shows
    /// the result as an alert, as a sheet on `window` when there is one.
    @MainActor
    public static func installAndReport(on window: NSWindow?) {
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, InstallError> in
                do {
                    return .success(try install())
                } catch let error as InstallError {
                    return .failure(error)
                } catch {
                    return .failure(InstallError(error.localizedDescription))
                }
            }.value
            let (title, message) = Self.message(for: result)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.window.appearance = AppTheme.shared.nsAppearance
            if let window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }

    /// The alert's title and text for an installation's result.
    static func message(for result: Result<URL, InstallError>,
                        path: String? = ProcessInfo.processInfo.environment["PATH"]) -> (String, String) {
        switch result {
        case .success(let link):
            let folder = link.deletingLastPathComponent().standardizedFileURL.path
            let onPath = (path ?? "").split(separator: ":").contains {
                URL(fileURLWithPath: String($0)).standardizedFileURL.path == folder
            }
            let guidance = onPath
                ? "Run tab --help in your terminal."
                : "Add ~/.local/bin to your PATH. For this shell, run:\nexport PATH=\"$HOME/.local/bin:$PATH\""
            return ("Command Line Tool Installed", "Installed \(link.path).\n\n\(guidance)")
        case .failure(let error):
            return ("Could Not Install Command Line Tool", error.description)
        }
    }

    /// Links `<home>/.local/bin/tab` to the running bundle's `tab`.
    static func install(executable: URL? = Executable.currentURL(),
                        home: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())) throws -> URL {
        guard let executable else { throw InstallError("This app's executable was not found.") }
        let target = try installedTool(executable: executable)
        return try installBundledTool(target: target, home: home)
    }

    /// Installs only a CLI and server matching the app that requested it.
    static func installBundledTool(target: URL, home: URL, expected: BuildInfo = BuildInfo(version: Release.version)) throws -> URL {
        do {
            let build = try BundledBuild.check(in: target.deletingLastPathComponent(), version: expected.version)
            guard build == expected else { throw InstallError("Build changed") }
        } catch {
            throw InstallError("The installed app changed. Reopen it before installing the command line tool.")
        }
        let destination = home.appendingPathComponent(".local/bin/tab")
        if target.standardizedFileURL != destination.standardizedFileURL {
            try installLink(target: target, destination: destination)
        }
        return destination
    }

    /// The `tab` inside the app bundle at `executable`. An app run from a
    /// disk image, a temporary folder or App Translocation is not installed,
    /// and a link into it would not last.
    static func installedTool(executable: URL) throws -> URL {
        let appName = Release.appName
        let macOS = executable.deletingLastPathComponent()
        let bundle = macOS.deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app", macOS.lastPathComponent == "MacOS",
              macOS.deletingLastPathComponent().lastPathComponent == "Contents"
        else {
            throw InstallError("Install and open \(appName).app before installing its command line tool.")
        }
        let path = bundle.standardizedFileURL.path
        let temporary = ["/Volumes/", "/tmp/", "/private/tmp/", "/private/var/folders/"].contains { path.hasPrefix($0) }
        let translocated = bundle.pathComponents.contains { $0 == "AppTranslocation" || $0.hasPrefix(".tab-update-") }
        if executable.lastPathComponent != Executable.app || temporary || translocated
            || bundle.lastPathComponent == "previous.app"
        {
            throw InstallError("Move \(appName).app to Applications and reopen it before installing its command line tool.")
        }
        return macOS.appendingPathComponent(Executable.cli)
    }

    /// Points `destination` at `target`, creating its folder. A link this
    /// installer made before, even to a bundle since moved, is replaced; any
    /// other file or link is left alone. The receipt beside it records which
    /// targets were ours.
    static func installLink(target: URL, destination: URL) throws {
        guard target.path.hasPrefix("/"), ((try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true) else {
            throw InstallError("The bundled tab executable is missing.")
        }
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = try FileLock.tryLock(folder.appendingPathComponent(".tab-cli-install.lock"))
        defer { lock.unlock() }
        let receipt = folder.appendingPathComponent(".tab-cli-link.json")
        var managed: [String] = []
        if FileManager.default.fileExists(atPath: receipt.path) {
            managed = try JSONDecoder().decode([String].self, from: Data(contentsOf: receipt))
        }
        var info = stat()
        var previous: (device: dev_t, inode: ino_t, target: String)?
        if lstat(destination.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFLNK else {
                throw InstallError("\(destination.path) already exists; move it before installing Tab.")
            }
            let existing = try FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
            guard existing == target.path || managed.contains(existing) else {
                throw InstallError("\(destination.path) is an unrelated link; move it before installing Tab.")
            }
            previous = (info.st_dev, info.st_ino, existing)
        } else if errno != ENOENT {
            throw InstallError(String(cString: strerror(errno)))
        }
        let staging = folder.appendingPathComponent(".tab-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let link = staging.appendingPathComponent("tab")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let record = staging.appendingPathComponent("receipt")
        try AtomicFile.write(JSONEncoder().encode([target.path] + (previous.map { [$0.target] } ?? [])), to: record)
        var now = stat()
        let unchanged: Bool
        if lstat(destination.path, &now) == 0 {
            unchanged = previous.map { $0.device == now.st_dev && $0.inode == now.st_ino } ?? false
        } else {
            unchanged = previous == nil && errno == ENOENT
        }
        guard unchanged else { throw InstallError("The command path changed during installation; try again.") }
        guard rename(record.path, receipt.path) == 0, rename(link.path, destination.path) == 0 else {
            throw InstallError(String(cString: strerror(errno)))
        }
        try AtomicFile.syncDirectory(folder)
    }
}
