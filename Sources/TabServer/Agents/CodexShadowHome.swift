import Foundation
import TabCore

/// A Codex home of one account's own: its sign-in stays in the shadow folder while
/// everything else, such as conversations, skills, plugins and `config.toml`, is a
/// link into the shared `CODEX_HOME`. Several accounts then see the same history.
enum CodexShadowHome {
    /// Folders Codex creates later, linked from the start so each account shares them.
    static let sharedFolders = ["sessions", "archived_sessions", "sqlite", "shell_snapshots", "worktrees",
                                "skills", "plugins", "cache", "logs", "mcp-oauth-locks", "thread-writer-locks"]
    /// The account's own: its sign-in and the models it may use.
    static let privateEntries: Set<String> = ["auth.json", "auth.lock", "models_cache.json"]
    /// Kept apart in each home without holding account state.
    static let localEntries: Set<String> = ["log", "memories", "tmp", ".DS_Store"]
    /// Lock folders a shadow home may have made for itself before it was linked; they
    /// guard shared state, so they become links.
    static let replaceableEntries: Set<String> = ["mcp-oauth-locks", "thread-writer-locks", ".sqlite-maintenance.lock"]

    /// Codex loads bundled plugins only from under `CODEX_HOME`, but the shared config
    /// names the shared home, so a shadow home points Codex at its own linked copy.
    static let bundledMarketplace = "openai-bundled"

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// Links every shared entry into `shadow`, creating both folders, and leaves the
    /// account's own entries alone. Runs before each launch, so entries Codex adds to
    /// the shared home later are linked too.
    static func prepare(shared: URL, shadow: URL, fileManager: FileManager = .default) throws {
        let shared = shared.standardizedFileURL, shadow = shadow.standardizedFileURL
        guard shared.path != shadow.path else {
            throw Failure(description: "The account folder must differ from the shared Codex folder \(shared.path).")
        }
        do {
            for folder in [shared, shadow] + sharedFolders.map({ shared.appendingPathComponent($0, isDirectory: true) }) {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            var names = Set(sharedFolders)
            for name in try fileManager.contentsOfDirectory(atPath: shared.path)
            where !privateEntries.contains(name) && !localEntries.contains(name) {
                names.insert(name)
            }
            for name in privateEntries where name != "auth.json" {
                let path = shadow.appendingPathComponent(name).path
                if (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil { try fileManager.removeItem(atPath: path) }
            }
            for name in names.sorted() { try link(name, shared: shared, shadow: shadow, fileManager: fileManager) }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(description: "Couldn't prepare the Codex account folder \(shadow.path): \(error.localizedDescription)")
        }
        let auth = shadow.appendingPathComponent("auth.json").path
        if (try? fileManager.destinationOfSymbolicLink(atPath: auth)) != nil {
            throw Failure(description: "\(auth) links to another sign-in. Remove it, then sign in again.")
        }
    }

    private static func link(_ name: String, shared: URL, shadow: URL, fileManager: FileManager) throws {
        let target = shared.appendingPathComponent(name).path
        let link = shadow.appendingPathComponent(name).path
        if let existing = try? fileManager.destinationOfSymbolicLink(atPath: link) {
            let resolved = URL(fileURLWithPath: existing, relativeTo: shadow).standardizedFileURL.path
            guard resolved != target else { return }
            try fileManager.removeItem(atPath: link)
        } else if fileManager.fileExists(atPath: link) {
            guard replaceableEntries.contains(name) else {
                throw Failure(description: "\(link) already exists and isn't a link to \(target). Move it away to share it.")
            }
            if name == "thread-writer-locks", let locks = try? fileManager.contentsOfDirectory(atPath: link),
               locks.contains(where: { $0.hasSuffix(".lock") && $0 != ".coordination.lock" }) {
                // A conversation still holds it; it is shared once that one ends.
                return
            }
            try fileManager.removeItem(atPath: link)
        }
        try fileManager.createSymbolicLink(atPath: link, withDestinationPath: target)
    }

    /// The arguments that point Codex at the shadow home's bundled plugins.
    static func arguments(shadow: URL) -> [String] {
        let source = shadow.appendingPathComponent(".tmp/bundled-marketplaces/\(bundledMarketplace)").path
        let quoted = "\"" + source.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return ["-c", "marketplaces.\(bundledMarketplace).source=\(quoted)"]
    }
}
