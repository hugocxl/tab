import Darwin
import Foundation
import TabProtocol

/// A folder agents and restores meet in, however its path is spelled: its identity and those
/// of the physical folders around it, so work in a folder meets work in one inside it.
/// Reading one touches the disk, so build it off the sessions queue.
struct AgentWorkspaceFolder: Hashable, Sendable {
    /// The folder's device and inode, or its resolved path when it can't be read.
    let identity: String
    /// Its identity and each enclosing folder's, out to the root.
    let lineage: Set<String>
    /// The folder's resolved path, and the path it was given as, for comparing with folders
    /// not read from disk.
    let path: String
    let given: String

    init(_ directory: String) {
        let given = URL(fileURLWithPath: directory).standardizedFileURL.path
        self.given = given
        var resolved = URL(fileURLWithPath: given).resolvingSymlinksInPath().path
        if let real = realpath(given, nil) {
            resolved = String(cString: real)
            free(real)
        }
        let identity = Self.identity(resolved)
        var lineage: Set<String> = [identity]
        var folder = resolved
        while folder != "/", !folder.isEmpty {
            folder = (folder as NSString).deletingLastPathComponent
            lineage.insert(Self.identity(folder))
        }
        self.identity = identity
        self.lineage = lineage
        self.path = resolved
    }

    private static func identity(_ path: String) -> String {
        var status = stat()
        if stat(path, &status) == 0 { return "\(status.st_dev):\(status.st_ino)" }
        return path
    }

    /// Whether work in one may change files the other holds: it is the same folder, or one
    /// is inside the other.
    func overlaps(_ other: AgentWorkspaceFolder) -> Bool {
        lineage.contains(other.identity) || other.lineage.contains(identity)
    }

    /// Whether `directory`, a path not read from disk, is this folder, inside it or around it,
    /// as its spelling says. For conversations newer than the folders read; touches no disk,
    /// so it may run on the sessions queue.
    func overlaps(path directory: String) -> Bool {
        let other = URL(fileURLWithPath: directory).standardizedFileURL.path
        return [path, given].contains { mine in
            other == mine || other.hasPrefix(mine + "/") || mine.hasPrefix(other + "/")
        }
    }
}

/// A restore being applied: the folder whose files it changes, when it changes any, and the
/// conversations that may not start work until it ends.
struct AgentRestoreReservation: Sendable {
    var folder: AgentWorkspaceFolder?
    var holds: Set<SessionId>

    func blocks(_ session: SessionId, directory: String) -> Bool {
        holds.contains(session) || folder?.overlaps(path: directory) == true
    }
}

/// The file work of a revert or a rewind, run on a blocking worker under a reservation.
enum AgentRestoreWork {
    /// Puts `paths` of `record`'s turn, or all of them, back as they were before it. Files
    /// already so are listed as unchanged; files changed since the turn stop it, unless `force`.
    static func revert(_ record: AgentCheckpointRecord, paths: [String]?, force: Bool,
                       store: AgentCheckpointStore) throws -> AgentRevertReply {
        let changed = Set(record.files.map(\.path))
        let targets = paths ?? record.files.map(\.path)
        guard !targets.isEmpty, targets.allSatisfy(changed.contains) else {
            throw ServiceError(.badRequest, "Only files this turn changed can be reverted")
        }
        return try restore(targets, to: record.before, latest: { _ in record.after }, force: force, store: store)
    }

    /// Puts every file `records`' turns changed back as it was before the first of them.
    /// `records` run oldest first; each file must still match the last turn that changed it.
    static func rewind(_ records: [AgentCheckpointRecord], force: Bool,
                       store: AgentCheckpointStore) throws -> AgentRevertReply {
        guard let first = records.first else { return AgentRevertReply() }
        var latest: [String: AgentCheckpointStore.Snapshot] = [:]
        var order: [String] = []
        for record in records {
            guard record.before.directory == first.before.directory else {
                throw AgentRuntimeError("These turns ran in different folders, so their files can't be restored together.")
            }
            for file in record.files {
                if latest[file.path] == nil { order.append(file.path) }
                latest[file.path] = record.after
            }
        }
        guard !order.isEmpty else { return AgentRevertReply() }
        return try restore(order, to: first.before, latest: { latest[$0] ?? first.after }, force: force, store: store)
    }

    private static func restore(_ targets: [String], to before: AgentCheckpointStore.Snapshot,
                                latest: (String) -> AgentCheckpointStore.Snapshot, force: Bool,
                                store: AgentCheckpointStore) throws -> AgentRevertReply {
        let unchanged = Set(try store.matching(before, paths: targets))
        let remaining = targets.filter { !unchanged.contains($0) }
        if !force {
            var conflicts: [String] = []
            for path in remaining where try !store.changedSince(latest(path), paths: [path]).isEmpty {
                conflicts.append(path)
            }
            if !conflicts.isEmpty { return AgentRevertReply(conflicts: conflicts) }
        }
        if !remaining.isEmpty { try store.restore(before, paths: remaining) }
        return AgentRevertReply(reverted: remaining, unchanged: unchanged.isEmpty ? nil : targets.filter(unchanged.contains))
    }

    /// Why work in a conversation stops a restore of files it may change, or nil.
    static func blocker(own: Bool, submitting: Bool, delivering: Bool, status: AgentChatStatus,
                        runningAgents: Bool, capturing: Bool, resetting: Bool) -> String? {
        if resetting { return own ? "The conversation is being cleared. Try again shortly." : nil }
        if submitting || delivering || status == .working || status == .waiting {
            return own ? "Stop the agent first: it may be changing these files."
                : "An agent in another conversation is working in this folder. Wait for it to finish or stop it first."
        }
        if runningAgents {
            return own ? "This conversation's agents are still running and may change these files. Wait for them or stop them first."
                : "Agents of another conversation are running in this folder. Wait for them or stop them first."
        }
        if capturing { return "Tab is still recording a turn's changes in this folder. Try again shortly." }
        return nil
    }
}

extension AgentChatTurn {
    /// The checkpoint status a ready checkpoint gives a turn.
    static let checkpointReady = AgentTurnCheckpointStatus(state: .ready)
    static let checkpointCapturing = AgentTurnCheckpointStatus(state: .capturing)
}
