import Foundation
import TabProtocol

/// The source renderer's directory-first, naturally sorted, compacted changed-file hierarchy.
struct AgentChangedFilesTree {
    struct Node: Equatable {
        var name: String
        var path: String
        var file: AgentTurnCheckpoint.File?
        var children: [Node]
        var additions: UInt64?
        var deletions: UInt64?
        var isDirectory: Bool { file == nil }
    }

    private final class Directory {
        var name: String
        var path: String
        var directories: [String: Directory] = [:]
        var files: [AgentTurnCheckpoint.File] = []
        init(name: String, path: String) { self.name = name; self.path = path }
    }

    static func build(_ files: [AgentTurnCheckpoint.File]) -> [Node] {
        let root = Directory(name: "", path: "")
        for file in files {
            let segments = file.path.split(separator: "/").map(String.init)
            guard !segments.isEmpty else { continue }
            var directory = root
            for name in segments.dropLast() {
                if directory.directories[name] == nil {
                    directory.directories[name] = Directory(name: name,
                        path: directory.path.isEmpty ? name : directory.path + "/" + name)
                }
                if let child = directory.directories[name] { directory = child }
            }
            directory.files.append(file)
        }
        return nodes(root)
    }

    private static func total(_ counts: [UInt64?]) -> UInt64? {
        var result: UInt64 = 0
        for count in counts {
            guard let count else { return nil }
            let next = result.addingReportingOverflow(count)
            guard !next.overflow else { return nil }
            result = next.partialValue
        }
        return result
    }

    private static func nodes(_ directory: Directory) -> [Node] {
        let folders = directory.directories.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { child -> Node in
                let children = nodes(child)
                var result = Node(name: child.name, path: child.path, children: children,
                    additions: total(children.map(\.additions)), deletions: total(children.map(\.deletions)))
                while result.children.count == 1, let only = result.children.first, only.isDirectory {
                    result.name += "/" + only.name
                    result.path = only.path
                    result.children = only.children
                }
                return result
            }
        let files = directory.files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.map {
            Node(name: ($0.path as NSString).lastPathComponent, path: $0.path, file: $0, children: [],
                 additions: $0.additions, deletions: $0.deletions)
        }
        return folders + files
    }
}
