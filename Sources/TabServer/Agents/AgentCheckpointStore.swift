import Foundation
import TabProtocol

/// Worktree snapshots use an isolated index, as in the source renderer's GitVcsDriver. Never reset,
/// stash, checkout, or stage through the user's index. Call from a blocking worker.
struct AgentCheckpointStore: Sendable {
    struct Snapshot: Codable, Hashable, Sendable {
        var tree: String
        var reference: String
        var directory: String
    }


    private let git = GitCommand()
    private let config = ["-c", "core.fsmonitor=false", "-c", "core.splitIndex=false",
                          "-c", "core.untrackedCache=false", "-c", "core.sparseCheckout=false"]

    func capture(directory: String) throws -> Snapshot {
        let root = try git.text(directory, ["rev-parse", "--show-toplevel"])
        let index = try git.text(directory, ["rev-parse", "--path-format=absolute", "--git-path", "index"])
        let temporary = URL(fileURLWithPath: index).deletingLastPathComponent()
            .appendingPathComponent("tab-checkpoint-index-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(atPath: temporary.path + ".lock")
        }
        let environment = ["GIT_INDEX_FILE": temporary.path]
        if FileManager.default.fileExists(atPath: index) {
            try FileManager.default.copyItem(atPath: index, toPath: temporary.path)
        } else {
            try git.run(root, config + ["read-tree", "--empty"], environment: environment)
        }
        // Stage from the project directory, preserving other files in a parent
        // repository. The real index (including conflicts) remains untouched.
        try git.run(directory, config + ["add", "--all", "--", "."], environment: environment)
        let tree = try git.text(root, config + ["write-tree"], environment: environment)
        let reference = "refs/tab/checkpoints/" + UUID().uuidString.lowercased()
        try git.run(root, ["update-ref", reference, tree])
        return Snapshot(tree: tree, reference: reference, directory: directory)
    }

    /// Summary capture needs only numstat; detailed patches are read on demand.
    func files(from before: Snapshot, to after: Snapshot) throws -> [AgentTurnCheckpoint.File] {
        guard before.directory == after.directory else { throw gitError("Checkpoint directories differ") }
        let stats = try git.run(before.directory, ["diff", "--numstat", "-z", "--no-renames",
                                                  "--relative", before.tree, after.tree, "--", "."])
        return stats.split(separator: 0).compactMap { record in
            let fields = record.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return .init(path: String(decoding: fields[2], as: UTF8.self),
                         additions: UInt64(String(decoding: fields[0], as: UTF8.self)),
                         deletions: UInt64(String(decoding: fields[1], as: UTF8.self)))
        }
    }

    func diff(from before: Snapshot, to after: Snapshot, path: String) throws -> GitDiff {
        guard before.directory == after.directory else { throw gitError("Checkpoint directories differ") }
        let (data, truncated) = try git.diff(before.directory,
            ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--relative",
             "--src-prefix=a/", "--dst-prefix=b/", "--unified=3", before.tree, after.tree, "--", path], noIndex: false)
        return GitParsing.diff(GitRawDiff(diff: String(decoding: data, as: UTF8.self), truncated: truncated))
    }

    func remove(_ snapshot: Snapshot) throws {
        let prefix = "refs/tab/checkpoints/"
        guard snapshot.reference.hasPrefix(prefix),
              UUID(uuidString: String(snapshot.reference.dropFirst(prefix.count))) != nil,
              [40, 64].contains(snapshot.tree.count), snapshot.tree.allSatisfy(\.isHexDigit) else {
            throw gitError("Invalid private checkpoint reference")
        }
        guard git.optionalText(snapshot.directory, ["rev-parse", "--verify", snapshot.reference]) != nil else { return }
        // Expected-value deletion cannot remove a ref somebody replaced.
        try git.run(snapshot.directory, ["update-ref", "-d", snapshot.reference, snapshot.tree])
    }
}

/// Detailed comparisons stay server-side; transcript summaries can be bounded
/// without losing the full checkpoint or coupling history size to diff size.
struct AgentCheckpointRecord: Codable, Sendable {
    var before: AgentCheckpointStore.Snapshot
    var after: AgentCheckpointStore.Snapshot
    var files: [AgentTurnCheckpoint.File]
}

struct AgentCheckpointPending: Codable, Sendable {
    var turnID: String
    var before: AgentCheckpointStore.Snapshot
}

extension AgentCheckpointRecord {
    func summary(id: String) -> AgentTurnCheckpoint {
        let visible = Array(files.filter { $0.path.utf8.count <= 1024 }.prefix(64))
        return AgentTurnCheckpoint(id: id, files: visible, totalFiles: files.count,
            additions: files.reduce(0) { $0 + ($1.additions ?? 0) },
            deletions: files.reduce(0) { $0 + ($1.deletions ?? 0) }, truncated: visible.count != files.count)
    }
}
