import Foundation
import TabCore

/// Downloads or copies plugin `.bundle`s into `TAB_DIR/Plugins/` and removes
/// them on uninstall.
public struct PluginInstaller: Sendable {
    public typealias Downloader = @Sendable (URL) async throws -> Data

    public let dirs: TabDirs
    public let version: String
    public let isDebugBuild: Bool
    public let localSearchDirectories: [URL]
    private let download: Downloader

    public init(
        dirs: TabDirs,
        version: String = Release.version,
        isDebugBuild: Bool = Release.isDebugBuild,
        localSearchDirectories: [URL]? = nil,
        download: @escaping Downloader = { try await PluginInstaller.defaultDownload($0) }
    ) {
        self.dirs = dirs
        self.version = version
        self.isDebugBuild = isDebugBuild
        self.localSearchDirectories = localSearchDirectories ?? Self.defaultLocalDirectories()
        self.download = download
    }

    /// Whether the plugin's `.bundle` is present on disk in `dirs.plugins`.
    public func isBundlePresent(_ id: PluginId) -> Bool {
        FileManager.default.fileExists(atPath: dirs.pluginBundle(id).path)
    }

    /// Installs `descriptor`'s `.bundle` into `dirs.pluginBundle(descriptor.id)`.
    /// In debug builds (or when `TAB_PLUGINS_SOURCE_DIR` is set), checks local
    /// plugin build folders first; otherwise downloads from GitHub Releases.
    @discardableResult
    public func install(_ descriptor: PluginDescriptor) async throws -> URL {
        let destination = dirs.pluginBundle(descriptor.id)
        try FileManager.default.createDirectory(
            at: dirs.plugins,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if let local = findLocalBundle(for: descriptor) {
            try validateBundle(at: local, descriptor: descriptor)
            try replaceBundle(at: destination, with: local)
            return destination
        }

        if isDebugBuild && version == "0.0.0-dev" {
            throw PluginError.bundleNotFound(
                "Plugin “\(descriptor.name)” wasn't found locally. Run scripts/build-plugins.sh debug first."
            )
        }

        let archiveURL = releaseAssetURL(for: descriptor)
        let archiveData: Data
        do {
            archiveData = try await download(archiveURL)
        } catch let error as PluginError {
            throw error
        } catch {
            throw PluginError.downloadFailed(error.localizedDescription)
        }

        guard !archiveData.isEmpty else {
            throw PluginError.downloadFailed("Empty download from \(archiveURL.lastPathComponent).")
        }

        let staging = dirs.plugins.appendingPathComponent(".install-\(descriptor.id.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let zipFile = staging.appendingPathComponent("\(descriptor.id.rawValue).zip")
        try archiveData.write(to: zipFile, options: .atomic)

        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try unzip(zipFile, into: extracted)

        guard let bundleURL = locateExtractedBundle(in: extracted, descriptor: descriptor) else {
            throw PluginError.invalidBundle("Archive didn't contain \(descriptor.id.rawValue).bundle.")
        }
        try validateBundle(at: bundleURL, descriptor: descriptor)
        try verifyCodeSignature(bundleURL)
        try replaceBundle(at: destination, with: bundleURL)
        return destination
    }

    /// Removes `id`'s `.bundle` from `dirs.plugins`.
    public func remove(_ id: PluginId) throws {
        let url = dirs.pluginBundle(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw PluginError.installFailed("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// The GitHub Releases zip URL for `descriptor` matching this build's version.
    public func releaseAssetURL(for descriptor: PluginDescriptor) -> URL {
        let filename = "\(descriptor.releaseAssetPrefix)-\(version)-arm64.zip"
        return URL(string: "\(UpdateFeed.releases)/v\(version)/\(filename)")!
    }

    private func findLocalBundle(for descriptor: PluginDescriptor) -> URL? {
        let names = ["\(descriptor.id.rawValue).bundle", "\(descriptor.bundleName).bundle"]
        for dir in localSearchDirectories {
            for name in names {
                let candidate = dir.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func locateExtractedBundle(in folder: URL, descriptor: PluginDescriptor) -> URL? {
        let names = ["\(descriptor.id.rawValue).bundle", "\(descriptor.bundleName).bundle"]
        for name in names {
            let direct = folder.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
        }
        if let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            return items.first { $0.pathExtension == "bundle" }
        }
        return nil
    }

    private func validateBundle(at url: URL, descriptor: PluginDescriptor) throws {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw PluginError.invalidBundle("Missing Contents/Info.plist.")
        }
        guard let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty else {
            throw PluginError.invalidBundle("Missing CFBundleExecutable.")
        }
        let binary = url.appendingPathComponent("Contents/MacOS/\(executable)")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw PluginError.invalidBundle("Missing executable \(executable).")
        }
        guard let principal = plist["NSPrincipalClass"] as? String, !principal.isEmpty else {
            throw PluginError.invalidBundle("Missing NSPrincipalClass.")
        }
        if let declaredId = plist["TabPluginId"] as? String, declaredId != descriptor.id.rawValue {
            throw PluginError.invalidBundle("Expected plugin “\(descriptor.id.rawValue)”, found “\(declaredId)”.")
        }
    }

    private func verifyCodeSignature(_ bundleURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", bundleURL.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "codesign failed"
            throw PluginError.invalidBundle("Code signature check failed: \(output)")
        }
    }

    private func unzip(_ zipURL: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destination.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "ditto failed"
            throw PluginError.invalidBundle("Could not extract archive: \(output)")
        }
    }

    private func replaceBundle(at destination: URL, with source: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.copyItem(at: source, to: staging)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: staging, to: destination)
        } catch {
            throw PluginError.installFailed(error.localizedDescription)
        }
    }

    public static func defaultLocalDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL
    ) -> [URL] {
        var dirs: [URL] = []
        if let override = environment["TAB_PLUGINS_SOURCE_DIR"], !override.isEmpty {
            dirs.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        // Beside the .app bundle: build/debug/plugins/ when running build/debug/Tab Dev.app.
        dirs.append(bundleURL.deletingLastPathComponent().appendingPathComponent("plugins", isDirectory: true))
        if let execDir = executableURL?.deletingLastPathComponent() {
            dirs.append(execDir.appendingPathComponent("plugins", isDirectory: true))
        }
        return dirs
    }

    public static func defaultDownload(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PluginError.downloadFailed("HTTP \(http.statusCode) from \(url.lastPathComponent).")
        }
        return data
    }
}
