import Foundation
import TabProtocol

/// Watches a working tree and the Git metadata that changes its status
/// (HEAD, index, refs, config), and calls `changed` once things settle.
final class RepositoryWatch: @unchecked Sendable {
    static let debounce: TimeInterval = 0.8

    struct Roots: Equatable {
        var worktree: String
        var git: String
        var common: String

        /// Whether a change at `path` can change what Git reports.
        func relevant(_ path: String) -> Bool {
            if let relative = Self.relative(path, to: git) {
                return Self.metadataRelevant(relative, worktree: true, common: git == common)
            }
            if let relative = Self.relative(path, to: common) {
                return Self.metadataRelevant(relative, worktree: false, common: true)
            }
            return Self.relative(path, to: worktree) != nil
        }

        static func relative(_ path: String, to root: String) -> [Substring]? {
            if path == root { return [] }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            guard path.hasPrefix(prefix) else { return nil }
            return path.dropFirst(prefix.count).split(separator: "/")
        }

        static func metadataRelevant(_ components: [Substring], worktree: Bool, common: Bool) -> Bool {
            guard let first = components.first else { return true }
            if worktree, first == "HEAD" || first == "index" { return true }
            guard common else { return false }
            // A linked worktree added or removed, not work inside one.
            return first == "config" || first == "packed-refs" || first == "refs"
                || (first == "worktrees" && components.count <= 2)
        }
    }

    private let watcher: FileSystemWatcher

    init(roots: Roots, changed: @escaping @Sendable () -> Void) throws {
        var folders = [roots.worktree]
        if Roots.relative(roots.common, to: roots.worktree) == nil { folders.append(roots.common) }
        if Roots.relative(roots.git, to: roots.worktree) == nil, Roots.relative(roots.git, to: roots.common) == nil {
            folders.append(roots.git)
        }
        watcher = try FileSystemWatcher(roots: folders, debounce: Self.debounce, label: "tab.git-watch") { batch in
            if batch.rescan || batch.paths.contains(where: roots.relevant) { changed() }
        }
    }

    /// The roots of the repository at `directory`, with symbolic links resolved
    /// the way FSEvents reports paths.
    static func roots(of repository: GitRepository) throws -> Roots {
        Roots(worktree: canonical(try repository.absolute("--show-toplevel")),
              git: canonical(try repository.absolute("--git-dir")),
              common: canonical(try repository.absolute("--git-common-dir")))
    }

    func stop() {
        watcher.stop()
    }
}
