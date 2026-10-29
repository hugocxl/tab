import Foundation
import TabCore

/// The folders under the Open Project search root, found once in the
/// background: a few levels deep, skipping hidden folders and the usual
/// dependency and build folders.
@MainActor
final class FolderSearch {
    nonisolated static let maxDepth = 4
    nonisolated static let maxFolders = 20_000
    nonisolated static let skipped: Set<String> = [
        "node_modules", "Library", "Applications", "target", "build", "dist", "vendor", "Pods", "DerivedData", ".build",
    ]

    private(set) var found: [String] = []
    private(set) var searching = false
    private var root: String?
    private var task: Task<Void, Never>?
    var onChange: (() -> Void)?

    func start(root: String) {
        guard root != self.root || found.isEmpty else { return }
        self.root = root
        task?.cancel()
        found = []
        searching = true
        task = Task {
            let folders = await Task.detached(priority: .userInitiated) { Self.walk(root) }.value
            guard !Task.isCancelled else { return }
            found = folders
            searching = false
            onChange?()
        }
    }

    nonisolated static func walk(_ root: String) -> [String] {
        var result: [String] = []
        var queue: [(URL, Int)] = [(URL(fileURLWithPath: root, isDirectory: true), 0)]
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        while !queue.isEmpty, result.count < maxFolders {
            let (url, depth) = queue.removeFirst()
            guard let children = try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            for child in children {
                guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                      values.isSymbolicLink != true, values.isPackage != true,
                      !skipped.contains(child.lastPathComponent) else { continue }
                result.append(child.path)
                if depth + 1 < maxDepth { queue.append((child, depth + 1)) }
            }
        }
        return result
    }
}

/// Browsing by typed path: `~/code/ap` lists the folders of `~/code` that
/// start with `ap`, and Tab completes to their longest shared prefix.
enum FolderBrowse {
    /// The folder a typed path is in and the name typed after it.
    static func split(_ query: String, home: String = NSHomeDirectory()) -> (folder: String, prefix: String) {
        let expanded = TabDirs.expandHome(query, home: home)
        if expanded.hasSuffix("/") { return (expanded, "") }
        let folder = (expanded as NSString).deletingLastPathComponent
        return (folder.isEmpty ? "/" : folder, (expanded as NSString).lastPathComponent)
    }

    static func matches(_ query: String, home: String = NSHomeDirectory()) -> [String] {
        let (folder, prefix) = split(query, home: home)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        let lowered = prefix.lowercased()
        return names.filter { name in
            guard !name.hasPrefix(".") || prefix.hasPrefix(".") else { return false }
            guard lowered.isEmpty || name.lowercased().hasPrefix(lowered) else { return false }
            var isDirectory: ObjCBool = false
            let path = (folder as NSString).appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        .map { (folder as NSString).appendingPathComponent($0) }
    }

    /// The typed folder itself first when it exists, then its matches.
    static func items(_ query: String, home: String = NSHomeDirectory()) -> [String] {
        var items: [String] = []
        let expanded = TabDirs.expandHome(query, home: home)
        let trimmed = expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory), isDirectory.boolValue {
            items.append(trimmed)
        }
        items += matches(query, home: home).filter { $0 != trimmed }.prefix(200)
        return items
    }

    /// The query completed to the longest prefix its matches share, with a
    /// trailing `/` when only one folder matches.
    static func complete(_ query: String, home: String = NSHomeDirectory()) -> String? {
        let found = matches(query, home: home)
        guard let first = found.first else { return nil }
        var common = first
        for path in found.dropFirst() {
            while !path.lowercased().hasPrefix(common.lowercased()) { common.removeLast() }
        }
        let completed = found.count == 1 ? common + "/" : common
        let display = query.hasPrefix("~") ? (TabDirs.abbreviateHome(completed, home: home) ?? completed) : completed
        return display.count >= query.count ? display : nil
    }
}
