import Foundation
import TabProtocol

/// The Files panel's tree: folder listings loaded lazily, which folders are
/// expanded, which listings are on their way, and the selection. It decides
/// which folders to list again when files change on disk, so only affected
/// folders are read.
public struct FilesTree: Sendable {
    /// A file or folder in a listing.
    public struct Node: Equatable, Sendable {
        public var path: String
        public var name: String
        public var isDirectory: Bool
        /// Hidden or ignored by Git, drawn muted.
        public var dimmed: Bool
    }

    /// A row of the flattened tree.
    public struct Row: Equatable, Sendable {
        public var node: Node
        public var depth: Int
    }

    private var directories: [String: [Node]] = [:]
    private var expandedPaths: Set<String> = []
    private var pending: Set<String> = []
    private var refreshAgain: Set<String> = []
    public var selected: String?

    public init() {}

    /// Whether `path`'s listing has arrived.
    public func isLoaded(_ path: String) -> Bool { directories[path] != nil }

    /// Marks `path` as being listed; `false` when it is loaded or already asked for.
    public mutating func request(_ path: String) -> Bool {
        guard directories[path] == nil else { return false }
        return pending.insert(path).inserted
    }

    /// Stores `dir`'s listing. Returns whether changes that arrived while it
    /// was being listed need another listing.
    @discardableResult
    public mutating func setEntries(_ dir: String, _ entries: [FileEntry]) -> Bool {
        pending.remove(dir)
        if !dir.isEmpty && node(dir)?.isDirectory != true {
            refreshAgain.remove(dir)
            return false
        }
        var nodes: [Node] = entries.compactMap { entry in
            let path = entry.path.rawValue
            let name = entry.name.rawValue
            guard !path.isEmpty, NativePath.parent(path) == dir else { return nil }
            return Node(path: path, name: name, isDirectory: entry.isDirectory,
                        dimmed: entry.isIgnored || name.hasPrefix("."))
        }
        nodes.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let (la, lb) = (a.name.lowercased(), b.name.lowercased())
            if la != lb { return la < lb }
            return a.name < b.name
        }
        if let previous = directories[dir] {
            let keys = Set(nodes.map { Key(path: $0.path, isDirectory: $0.isDirectory) })
            let removed = previous.filter { !keys.contains(Key(path: $0.path, isDirectory: $0.isDirectory)) }.map(\.path)
            for path in removed {
                directories = directories.filter { !NativePath.isWithin($0.key, path) }
                expandedPaths = expandedPaths.filter { !NativePath.isWithin($0, path) }
                pending = pending.filter { !NativePath.isWithin($0, path) }
                refreshAgain = refreshAgain.filter { !NativePath.isWithin($0, path) }
                if let selected, NativePath.isWithin(selected, path) {
                    self.selected = dir.isEmpty ? nil : dir
                }
            }
        }
        directories[dir] = nodes
        if refreshAgain.remove(dir) != nil {
            pending.insert(dir)
            return true
        }
        return false
    }

    private struct Key: Hashable {
        var path: String
        var isDirectory: Bool
    }

    public func isExpanded(_ path: String) -> Bool { expandedPaths.contains(path) }

    /// Expands `path`; returns whether it needs listing.
    @discardableResult
    public mutating func expand(_ path: String) -> Bool {
        expandedPaths.insert(path)
        return request(path)
    }

    public mutating func collapse(_ path: String) {
        expandedPaths.remove(path)
        if let selected, selected != path, NativePath.isWithin(selected, path) {
            self.selected = path
        }
    }

    public mutating func collapseAll() {
        expandedPaths.removeAll()
        if let selected {
            self.selected = selected.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init)
        }
    }

    public func node(_ path: String) -> Node? {
        directories[NativePath.parent(path)]?.first { $0.path == path }
    }

    /// The rows shown: loaded entries of expanded folders, depth first.
    public func visible() -> [Row] {
        var rows: [Row] = []
        var stack: [Row] = (directories[""] ?? []).reversed().map { Row(node: $0, depth: 0) }
        while let row = stack.popLast() {
            rows.append(row)
            guard row.node.isDirectory, isExpanded(row.node.path) else { continue }
            stack.append(contentsOf: (directories[row.node.path] ?? []).reversed().map { Row(node: $0, depth: row.depth + 1) })
        }
        return rows
    }

    /// Moves the selection one visible row down or up.
    public mutating func step(forward: Bool) {
        let rows = visible()
        let index = selected.flatMap { path in rows.firstIndex { $0.node.path == path } }
        let next: Int
        if let index {
            next = forward ? min(index + 1, max(rows.count - 1, 0)) : max(index - 1, 0)
        } else {
            next = 0
        }
        selected = rows.indices.contains(next) ? rows[next].node.path : nil
    }

    /// Left arrow: collapses the selected folder, else selects its parent.
    public mutating func left() {
        guard let path = selected else { return }
        if isExpanded(path) {
            collapse(path)
        } else if !NativePath.parent(path).isEmpty {
            selected = NativePath.parent(path)
        }
    }

    /// Right arrow: expands the selected folder, else selects its first
    /// child. Returns a folder to list.
    public mutating func right() -> String? {
        guard let path = selected, node(path)?.isDirectory == true else { return nil }
        if isExpanded(path) {
            if let child = directories[path]?.first { selected = child.path }
            return nil
        }
        return expand(path) ? path : nil
    }

    private func isVisibleDirectory(_ directory: String) -> Bool {
        var directory = directory
        while !directory.isEmpty {
            if !isExpanded(directory) { return false }
            directory = NativePath.parent(directory)
        }
        return true
    }

    /// Files changed on disk: returns the folders to list again, sorted.
    /// Hidden folders forget their listing so they read fresh when shown.
    public mutating func refresh(paths: [String], rescan: Bool) -> [String] {
        let candidates = Set(directories.keys).union(pending).union(expandedPaths)
        var affected = candidates.filter { dir in
            rescan || paths.contains { NativePath.parent($0) == dir || NativePath.isWithin(dir, $0) }
        }
        if rescan && !isLoaded("") { affected.insert("") }
        var requests: [String] = []
        for dir in affected {
            if isVisibleDirectory(dir) {
                if pending.insert(dir).inserted {
                    requests.append(dir)
                } else {
                    refreshAgain.insert(dir)
                }
            } else {
                directories.removeValue(forKey: dir)
            }
        }
        return requests.sorted()
    }

    /// Forgets listings in flight after a failure, so they can be asked again.
    public mutating func retry() {
        pending.removeAll()
        refreshAgain.removeAll()
    }

    /// Expands the folders holding `path` and selects it. Returns folders to list.
    public mutating func reveal(_ path: String) -> [String] {
        var requests: [String] = []
        var ancestors: [String] = []
        var directory = NativePath.parent(path)
        while !directory.isEmpty {
            ancestors.append(directory)
            directory = NativePath.parent(directory)
        }
        for ancestor in ancestors.reversed() where expand(ancestor) {
            requests.append(ancestor)
        }
        selected = path
        return requests
    }

    /// The folder new files go in: the selected folder, or the selected file's folder.
    public var selectedDirectory: String {
        guard let selected else { return "" }
        return node(selected)?.isDirectory == true ? selected : NativePath.parent(selected)
    }
}
