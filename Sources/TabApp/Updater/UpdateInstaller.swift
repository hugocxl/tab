import Darwin
import Foundation
import Security
import TabCore
import TabProtocol

/// The installed app that updates replace: a signed `Tab.app` outside a
/// disk image and App Translocation.
public struct Installation: Equatable, Sendable {
    public let bundle: URL
    /// The Developer ID team that signed the running app; updates must be
    /// signed by the same team.
    public let team: String

    public init(bundle: URL, team: String) {
        self.bundle = bundle
        self.team = team
    }

    /// The running app, when it can update itself. Debug builds, unsigned or
    /// ad-hoc signed apps, and apps run from a disk image can't.
    public static func detect(bundle: URL = Bundle.main.bundleURL) throws -> Installation {
        guard !Release.isDebugBuild else { throw UpdateError.unavailable("Debug builds don't update themselves.") }
        guard ReleaseVersion(Release.version) != nil else { throw UpdateError.notARelease }
        let bundle = bundle.standardizedFileURL
        guard bundle.pathExtension == "app" else {
            throw UpdateError.unavailable("Automatic updates require an installed \(Release.appName).app.")
        }
        if bundle.path.hasPrefix("/Volumes/") || bundle.pathComponents.contains("AppTranslocation") {
            throw UpdateError.unavailable("Move \(Release.appName).app to Applications and reopen it before updating.")
        }
        guard let team = CodeSignature.teamIdentifier(of: bundle) else {
            throw UpdateError.unavailable("Automatic updates require a Developer ID signed app.")
        }
        let installation = Installation(bundle: bundle, team: team)
        try installation.verifyApp(bundle, version: Release.version)
        return installation
    }

    var directory: URL { bundle.deletingLastPathComponent() }
    static let stagingPrefix = ".tab-update-"

    /// Unpacks a verified download next to the installed app and checks the
    /// app inside: same team, same bundle identifier, the expected version.
    public func prepare(archive: URL, manifest: UpdateManifest) throws -> PreparedUpdate {
        let lock = try replacementLock()
        defer { lock.unlock() }
        try UpdateDownloader.verify(archive, sha256: manifest.sha256, size: manifest.size)
        if archive.pathExtension.lowercased() == "dmg" {
            let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            guard CodeSignature.isValid(archive, requirement: requirement, nested: false) else {
                throw UpdateError.invalidBundle("The update disk image isn't signed by the same developer as this app.")
            }
        }
        let staging = directory.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            throw UpdateError.install("Can't write next to \(bundle.lastPathComponent): \(error.localizedDescription)")
        }
        do {
            let candidate = staging.appendingPathComponent(bundle.lastPathComponent, isDirectory: true)
            try Self.extract(archive, appName: bundle.lastPathComponent, to: candidate)
            try verifyApp(candidate, version: manifest.version)
            var verified = manifest
            verified.protocolVersions = try BundledBuild.check(in: candidate.appendingPathComponent("Contents/MacOS"),
                                                               version: manifest.version).protocolVersions
            return PreparedUpdate(manifest: verified, installation: self, staging: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Extracts the app from a `.zip` with `ditto`, or copies it out of a
    /// mounted `.dmg`.
    static func extract(_ archive: URL, appName: String, to candidate: URL) throws {
        let unpacked = candidate.deletingLastPathComponent().appendingPathComponent("unpacked", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        if archive.pathExtension.lowercased() == "dmg" {
            let mount = FileManager.default.temporaryDirectory.appendingPathComponent("tab-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, archive.path])
            defer {
                _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
                try? FileManager.default.removeItem(at: mount)
            }
            try run("/usr/bin/ditto", [mount.appendingPathComponent(appName).path, candidate.path])
            return
        }
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let found = unpacked.appendingPathComponent(appName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: found.path) else {
            throw UpdateError.invalidBundle("The update doesn't contain \(appName).")
        }
        try FileManager.default.moveItem(at: found, to: candidate)
    }

    /// Checks an app's signature, identifier, version and executables.
    func verifyApp(_ app: URL, version: String) throws {
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(Release.bundleIdentifier)\""
        guard CodeSignature.isValid(app, requirement: requirement) else {
            throw UpdateError.invalidBundle("The update isn't signed by the same developer as this app.")
        }
        for name in [try DesktopExecutable.name(in: app), Executable.cli, Executable.server] {
            try Self.run("/usr/bin/lipo", [app.appendingPathComponent("Contents/MacOS/" + name).path, "-verify_arch", "arm64"])
        }
        try Self.checkContents(app, version: version)
        _ = try BundledBuild.check(in: app.appendingPathComponent("Contents/MacOS"), version: version)
    }

    /// The parts of a bundle the signature doesn't vouch for by itself.
    static func checkContents(_ app: URL, version: String) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.invalidBundle("The update has no Info.plist.")
        }
        guard info["CFBundleIdentifier"] as? String == Release.bundleIdentifier else {
            throw UpdateError.invalidBundle("The update has an unexpected bundle identifier.")
        }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError.invalidBundle("The update's version doesn't match the update feed.")
        }
        let appExecutable = try DesktopExecutable.name(in: app)
        let executables = app.appendingPathComponent("Contents/MacOS")
        for name in [appExecutable, Executable.server, Executable.cli]
            where !Executable.isExecutableFile(executables.appendingPathComponent(name))
        {
            throw UpdateError.invalidBundle("The update is missing \(name).")
        }
    }

    func replacementLock() throws -> FileLock {
        try FileLock.tryLock(directory.appendingPathComponent(".tab-bundle-update.lock"))
    }

    /// Whether `url` is one of this installation's staging folders.
    func owns(_ url: URL) -> Bool {
        var info = stat()
        return url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
            && url.lastPathComponent.hasPrefix(Self.stagingPrefix)
            && lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Removes old bundles kept for servers that have since exited, and
    /// downloads that were never installed, except `keeping`.
    public func cleanUp(keeping: URL? = nil) {
        guard let lock = try? replacementLock() else { return }
        defer { lock.unlock() }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where owns(entry) && entry.standardizedFileURL != keeping?.standardizedFileURL {
            let previous = entry.appendingPathComponent(PreparedUpdate.previousName)
            if FileManager.default.fileExists(atPath: previous.path), RunningProcesses.anyRunning(inside: previous) {
                continue
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    @discardableResult
    static func run(_ program: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.install("\(program) failed: \(error.localizedDescription)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw UpdateError.install("\((program as NSString).lastPathComponent) failed: \(text)")
        }
        return text
    }
}

/// A downloaded and verified release waiting in a staging folder next to
/// the installed app.
public struct PreparedUpdate: Equatable, Sendable {
    static let previousName = "previous.app"
    public let manifest: UpdateManifest
    public let installation: Installation
    public let staging: URL

    public var version: String { manifest.version }
    var candidate: URL { staging.appendingPathComponent(installation.bundle.lastPathComponent, isDirectory: true) }
    var backup: URL { staging.appendingPathComponent(Self.previousName, isDirectory: true) }

    /// Checks the staged app again right before installing it.
    func validate() throws {
        guard installation.owns(staging) else { throw UpdateError.install("The staged update moved. Check for updates again.") }
        try installation.verifyApp(candidate, version: version)
        try installation.verifyApp(installation.bundle, version: Release.version)
        let build = try BundledBuild.check(in: candidate.appendingPathComponent("Contents/MacOS"), version: version)
        guard build.protocolVersions == manifest.protocolVersions else {
            throw UpdateError.invalidBundle("The staged update metadata changed. Check for updates again.")
        }
    }

    /// Swaps the staged app in, keeping the old one in the staging folder
    /// until its server exits, and starts the new app once this one quits.
    /// On failure the installed app is left as it was.
    public func install(processIdentifier: pid_t = getpid()) throws {
        let lock = try installation.replacementLock()
        defer { lock.unlock() }
        try validate()
        try BundleReplacement.replace(current: installation.bundle, next: candidate, backup: backup) {
            try Self.relaunch(installation.bundle, after: processIdentifier)
        }
    }

    /// Starts `bundle` once the process `pid` has exited.
    static func relaunch(_ bundle: URL, after pid: pid_t) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$2\"",
            "tab-relaunch", String(pid), bundle.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.install("Could not schedule the relaunch: \(error.localizedDescription)")
        }
    }

    /// Removes the download unless an old bundle waits there for its server.
    public func discard() {
        guard let lock = try? installation.replacementLock() else { return }
        defer { lock.unlock() }
        guard installation.owns(staging), !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.removeItem(at: staging)
    }
}

/// Moves app bundles with a rollback at every step.
public enum BundleReplacement {
    /// Moves `current` to `backup` and `next` to `current`, then runs
    /// `then`. When a step fails, `current` is restored.
    public static func replace(current: URL, next: URL, backup: URL, then: () throws -> Void = {}) throws {
        try move(current, to: backup, failure: "Could not move the installed app aside")
        do {
            try move(next, to: current, failure: "Could not install the update")
        } catch {
            do {
                try move(backup, to: current, failure: "")
            } catch {
                throw UpdateError.install("Could not install the update or restore the previous app. The previous app is at \(backup.path).")
            }
            throw error
        }
        do {
            try then()
        } catch {
            do {
                try move(current, to: next, failure: "Could not move the new app aside")
                try move(backup, to: current, failure: "Could not restore the previous app")
            } catch {
                throw UpdateError.install("Could not relaunch or restore the previous app. The previous app is at \(backup.path).")
            }
            throw error
        }
    }

    private static func move(_ source: URL, to destination: URL, failure: String) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw UpdateError.install("\(failure): \(String(cString: strerror(errno)))")
        }
    }
}

/// Code signature checks through the Security framework.
enum CodeSignature {
    /// The team identifier of a signed app; `nil` when unsigned or ad hoc.
    static func teamIdentifier(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, team.allSatisfy({ ($0.isUppercase || $0.isNumber) && $0.isASCII })
        else { return nil }
        return team
    }

    /// Whether every piece of `bundle`'s code is intact and meets `requirement`.
    static func isValid(_ bundle: URL, requirement text: String, nested: Bool = true) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | (nested ? kSecCSCheckAllArchitectures | kSecCSCheckNestedCode : 0))
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}

/// Which processes run executables from a folder, such as a server still
/// running from the bundle an update replaced.
enum RunningProcesses {
    static func anyRunning(inside folder: URL) -> Bool {
        guard let resolved = realpath(folder.path, nil) else { return false }
        defer { free(resolved) }
        let prefix = String(cString: resolved) + "/"
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return true }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return true }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { continue }
            let executable = String(decoding: path.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if executable.hasPrefix(prefix) { return true }
        }
        return false
    }
}
