import Foundation
import TabCore
import TabProtocol

/// A `.tab` backup: one JSON document holding the profile's configuration
/// files, each base64-encoded under its path. It carries settings, terminal
/// settings, themes, server settings, the remote server list (inside
/// `settings.json`) and the local projects with their layouts. It never
/// carries live sessions, paired devices, remote projects, project files or
/// proxy settings.
public struct BackupArchive: Equatable, Sendable {
    public static let format = "tab-backup"
    public static let version = 1
    public static let fileExtension = "tab"
    /// Where a chosen backup waits for the next launch.
    public static let pendingName = "pending-import.tab"
    static let maxFileBytes = 16 * 1024 * 1024
    static let maxTotalBytes = 64 * 1024 * 1024
    static let maxFiles = 8192
    /// The profile files a backup may hold; `themes/` holds files below it.
    static let roots = ["settings.json", "terminal.json", "server.json", "state.json"]
    static let themesFolder = "themes"

    /// File contents by profile-relative path, such as `themes/Dracula`.
    public var files: [String: Data]
    public var created: Date

    public init(files: [String: Data], created: Date = Date()) {
        self.files = files
        self.created = created
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case notABackup
        case newerVersion(Int)
        case unsafePath(String)
        case tooLarge
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .notABackup: return "This file is not a Tab backup."
            case .newerVersion(let version): return "This backup was made by a newer Tab (format \(version)). Update Tab to restore it."
            case .unsafePath(let path): return "The backup contains an unexpected file: \(path)."
            case .tooLarge: return "The backup is too large."
            case .invalid(let reason): return reason
            }
        }
    }

    // MARK: Collecting

    /// The configuration in `dirs`, with `state` as the projects and layouts.
    public static func collect(from dirs: TabDirs, state: Data?) throws -> BackupArchive {
        var files: [String: Data] = [:]
        let manager = FileManager.default
        for (name, url) in [("settings.json", dirs.settings), ("terminal.json", dirs.terminalSettings), ("server.json", dirs.serverSettings)] {
            guard manager.fileExists(atPath: url.path) else { continue }
            files[name] = try Data(contentsOf: url)
        }
        if files["settings.json"] == nil { files["settings.json"] = try JSONEncoder().encode(Settings()) }
        if let state { files["state.json"] = state }
        if manager.fileExists(atPath: dirs.themes.path) {
            let names = try manager.contentsOfDirectory(atPath: dirs.themes.path)
            for name in names.sorted() where !name.hasPrefix(".") {
                let url = dirs.themes.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                files["\(themesFolder)/\(name)"] = try Data(contentsOf: url)
            }
        }
        let archive = BackupArchive(files: files)
        try archive.validate()
        return archive
    }

    // MARK: Encoding

    private struct Document: Codable {
        var format: String
        var version: Int
        var created: Date
        var files: [String: String]
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let document = Document(
            format: Self.format,
            version: Self.version,
            created: created,
            files: files.mapValues { $0.base64EncodedString() }
        )
        return try encoder.encode(document)
    }

    public init(data: Data) throws {
        guard data.count <= Self.maxTotalBytes * 2 else { throw Failure.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(Document.self, from: data), document.format == Self.format else {
            throw Failure.notABackup
        }
        guard document.version <= Self.version else { throw Failure.newerVersion(document.version) }
        var files: [String: Data] = [:]
        for (path, text) in document.files {
            guard let bytes = Data(base64Encoded: text) else { throw Failure.invalid("The backup's \(path) is damaged.") }
            files[path] = bytes
        }
        self.init(files: files, created: document.created)
        try validate()
    }

    public func write(to url: URL) throws {
        try AtomicFile.write(try encoded(), to: url)
    }

    public static func read(_ url: URL) throws -> BackupArchive {
        try BackupArchive(data: Data(contentsOf: url))
    }

    // MARK: Checking

    /// Whether `path` is a file a backup may restore.
    static func isAllowed(_ path: String) -> Bool {
        if roots.contains(path) { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == Substring(themesFolder) && !parts[1].isEmpty
            && !parts[1].hasPrefix(".") && parts[1] != ".."
    }

    /// Refuses unexpected paths, oversized files and settings that do not
    /// load.
    public func validate() throws {
        guard files.count <= Self.maxFiles else { throw Failure.tooLarge }
        var total = 0
        for (path, data) in files {
            guard Self.isAllowed(path) else { throw Failure.unsafePath(path) }
            guard data.count <= Self.maxFileBytes else { throw Failure.tooLarge }
            total += data.count
        }
        guard total <= Self.maxTotalBytes else { throw Failure.tooLarge }
        guard let settings = files["settings.json"] else {
            throw Failure.invalid("The backup does not contain settings.json.")
        }
        do {
            try Settings.decode(settings).validate()
            if let terminal = files["terminal.json"] { _ = try TerminalSettings.decode(terminal) }
            if let state = files["state.json"] { _ = try AppStateStore.decode(state) }
            for name in ["server.json", "state.json"] {
                guard let data = files[name] else { continue }
                guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                    throw SettingsError(name, "is not a JSON object")
                }
            }
            if let data = files["server.json"] {
                let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ServerSettingsDoc())) as? [String: Any] ?? [:]
                let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let merged = defaults.merging(values) { _, new in new }
                let server = try JSONDecoder().decode(ServerSettingsDoc.self, from: JSONSerialization.data(withJSONObject: merged))
                try server.validate()
            }
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.invalid("The backup's settings do not load: \(error.localizedDescription)")
        }
    }

    /// The number of projects the backup's state holds, for the summary.
    public var projectCount: Int {
        guard let data = files["state.json"],
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [Any]
        else { return 0 }
        return projects.count
    }

    public var summary: String {
        "Restore settings and \(projectCount) saved projects with their layouts on the next launch. Existing projects are kept; matching projects receive the saved layouts. A recovery copy is saved in the profile’s Backups folder. Restart the server from Settings to apply restored server settings."
    }

    // MARK: Restoring

    /// Saves the backup to restore on the next launch, replacing one already
    /// waiting.
    public func stage(in dirs: TabDirs) throws {
        try validate()
        try write(to: Self.pendingURL(dirs))
    }

    public static func pendingURL(_ dirs: TabDirs) -> URL {
        dirs.root.appendingPathComponent(pendingName, isDirectory: false)
    }

    public static func hasPending(_ dirs: TabDirs) -> Bool {
        FileManager.default.fileExists(atPath: pendingURL(dirs).path)
    }

    public static func cancelPending(_ dirs: TabDirs) throws {
        do {
            try FileManager.default.removeItem(at: pendingURL(dirs))
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    /// Restores a waiting backup, at launch before anything reads the
    /// profile. The files it replaces are first copied to
    /// `Backups/pre-import-<time>/`. `mergeState` combines the backup's
    /// projects with the current `state.json` (or `nil` without one),
    /// keeping existing projects and applying matched layouts. Returns the
    /// recovery folder, or `nil` when nothing was waiting.
    @discardableResult
    public static func applyPending(
        in dirs: TabDirs,
        now: Date = Date(),
        mergeState: (_ imported: Data, _ current: Data?) throws -> Data
    ) throws -> URL? {
        let pending = pendingURL(dirs)
        guard FileManager.default.fileExists(atPath: pending.path) else { return nil }
        var archive = try read(pending)
        let manager = FileManager.default
        let stateURL = dirs.state
        if let imported = archive.files["state.json"] {
            archive.files["state.json"] = try mergeState(imported, try? Data(contentsOf: stateURL))
        }
        let stamp = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let recovery = dirs.backups.appendingPathComponent("pre-import-\(stamp)-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: recovery, withIntermediateDirectories: true)
        let replacesThemes = archive.files.keys.contains { $0.hasPrefix(themesFolder + "/") }
        var replaced = archive.files.keys.filter { !$0.hasPrefix(themesFolder + "/") }
        if replacesThemes { replaced.append(themesFolder) }
        for path in replaced {
            let current = dirs.root.appendingPathComponent(path)
            guard manager.fileExists(atPath: current.path) else { continue }
            try manager.copyItem(at: current, to: recovery.appendingPathComponent(path))
        }
        do {
            if replacesThemes {
                if manager.fileExists(atPath: dirs.themes.path) { try manager.removeItem(at: dirs.themes) }
                try manager.createDirectory(at: dirs.themes, withIntermediateDirectories: true)
            }
            for (path, data) in archive.files.sorted(by: { $0.key < $1.key }) {
                try AtomicFile.write(data, to: dirs.root.appendingPathComponent(path))
            }
            try manager.removeItem(at: pending)
        } catch {
            let failure = error
            do {
                for path in replaced {
                    let destination = dirs.root.appendingPathComponent(path)
                    let original = recovery.appendingPathComponent(path)
                    if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                    if manager.fileExists(atPath: original.path) { try manager.copyItem(at: original, to: destination) }
                }
            } catch {
                throw Failure.invalid("Restore failed and could not roll back: \(error.localizedDescription). Your original files are in \(recovery.path).")
            }
            throw failure
        }
        return recovery
    }
}
