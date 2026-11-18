import Foundation
import TabCore
import TabProtocol

/// A conversation deleted for good, as the cleanups registered with
/// `AgentSessions.registerDeletionCleanup` see it.
struct AgentDeletedConversation: Sendable {
    var session: SessionId
    var project: ProjectId
    /// The sessions store's folder.
    var root: URL
    /// Checkpoint snapshots other conversations still reference, which must stay.
    var sharedReferences: Set<String>
}

/// Closed conversations stay until the user deletes them or chose a retention that
/// expired. Records saved by builds that predate this carry no close date or retention:
/// they are kept, never aged out by file dates as those builds did after 30 days.
extension AgentSessions {
    /// Lets another store remove what it keeps for a conversation when the conversation
    /// is permanently deleted, by the user or its chosen retention. Cleanups run on the
    /// persistence queue after Tab's own files are gone, so they may block on disk.
    func registerDeletionCleanup(_ cleanup: @escaping @Sendable (AgentDeletedConversation) -> Void) {
        writer.sync { deletionCleanups.append(cleanup) }
    }

    /// Whether a saved closed conversation's chosen retention has run out by `date`.
    static func expired(_ saved: Saved, at date: Date) -> Bool {
        guard saved.snapshot.status == .closed, let days = saved.retention?.deleteAfterDays,
              let closedAt = saved.closedAt else { return false }
        return date.timeIntervalSince(closedAt) > TimeInterval(days) * 86_400
    }

    /// Tab's conversations for `project` that no pane shows, newest first.
    func savedConversations(project: ProjectId) -> [AgentSavedConversation] {
        queue.sync {
            entries.values.filter { $0.snapshot.project == project && $0.snapshot.status == .closed }
                .map { entry in
                    let snapshot = entry.snapshot
                    let first = snapshot.items.first { $0.kind == .user && !$0.isProviderTurn }?.text
                        .split(whereSeparator: \.isNewline).first.map { String($0.prefix(160)) }
                    let updated = snapshot.items.compactMap { $0.updatedAt ?? $0.createdAt }.max()
                    let expires = entry.retention.deleteAfterDays.flatMap { days in
                        entry.closedAt.map { $0.addingTimeInterval(TimeInterval(days) * 86_400) }
                    }
                    let review = entry.inbox.visible.contains { $0.state == .uncertain || $0.state == .failed || $0.state == .delivering }
                    return AgentSavedConversation(session: snapshot.session, project: snapshot.project, provider: snapshot.provider,
                                                  title: first.map { $0.isEmpty ? "Untitled conversation" : $0 } ?? "Untitled conversation",
                                                  updatedAt: updated, closedAt: entry.closedAt, archived: entry.archived,
                                                  retention: entry.retention, expiresAt: expires, needsReview: review ? true : nil)
                }
                .sorted { ($0.closedAt ?? $0.updatedAt ?? .distantPast) > ($1.closedAt ?? $1.updatedAt ?? .distantPast) }
                .prefix(AgentHistoryReply.maxEntries).map { $0 }
        }
    }

    /// Opens a closed or archived conversation again with its identity, transcript,
    /// checkpoints, attachments and acceptance ledger. Prompts that may have reached the
    /// agent stay held for review; nothing is delivered until the user says so.
    func reopen(_ session: SessionId) throws -> AgentChatSnapshot {
        guard let entry = entries[session] else { throw ServiceError.unknownSession(session) }
        guard entry.snapshot.status == .closed else { return entry.snapshot }
        guard !stopping else { throw ServiceError(.badRequest, "The server is stopping") }
        do { try checkDirectory(entry.directory) } catch {
            throw ServiceError(.badPath, "This conversation's folder is no longer available: \(entry.directory)")
        }
        entry.generation = UUID()
        entry.snapshot.status = .idle
        entry.closedAt = nil
        entry.archived = false
        if !entry.inbox.records.isEmpty {
            try mutateInbox(entry) { inbox in
                inbox.recover()
                inbox.paused = true
            }
        }
        touch(entry)
        persist(entry)
        return entry.snapshot
    }

    func setRetention(_ session: SessionId, _ retention: AgentConversationRetention) throws -> AgentChatSnapshot {
        guard let entry = entries[session] else { throw ServiceError.unknownSession(session) }
        entry.retention = retention
        persist(entry)
        return entry.snapshot
    }

    /// Deletes a closed conversation and what only it uses; checkpoint snapshots shared
    /// with another conversation, such as the archive Clear made, stay.
    func delete(_ session: SessionId) async throws -> AgentConversationDeletion {
        let saved = try queue.sync { () throws -> Saved in
            guard let entry = entries[session] else { throw ServiceError.unknownSession(session) }
            guard entry.snapshot.status == .closed, entry.runtime == nil, !entry.submitting, !entry.resetting else {
                throw ServiceError(.badRequest, "Close this conversation before deleting it.")
            }
            entries.removeValue(forKey: session)
            changed(session, entry.snapshot.revision &+ 1)
            return Saved(snapshot: entry.snapshot, directory: entry.directory, archived: entry.archived ? true : nil,
                         closedAt: entry.closedAt, retention: entry.retention)
        }
        let writer = writer
        return try await runBlocking { writer.sync { self.deleteConversationFiles(saved) } }
    }

    /// Writer queue only. Removes the conversation's file and everything kept beside it:
    /// checkpoints and their refs unless another conversation's checkpoint uses them,
    /// tool outputs, attachments, archived items and its prompt inbox; then the
    /// registered cleanups.
    @discardableResult
    func deleteConversationFiles(_ saved: Saved) -> AgentConversationDeletion {
        let session = saved.snapshot.session
        let checkpoints = root.appendingPathComponent("checkpoints", isDirectory: true).appendingPathComponent(session.description, isDirectory: true)
        let shared = checkpointReferences(excluding: session)
        let store = checkpointStore
        var removed = 0, kept = 0
        for record in (try? FileManager.default.contentsOfDirectory(at: checkpoints, includingPropertiesForKeys: nil)) ?? []
            where record.pathExtension == "json" {
            guard let data = try? Data(contentsOf: record) else { continue }
            var snapshots: [AgentCheckpointStore.Snapshot] = []
            if let finished = try? JSONDecoder().decode(AgentCheckpointRecord.self, from: data) {
                snapshots = [finished.before, finished.after]
            } else if let pending = try? JSONDecoder().decode(AgentCheckpointPending.self, from: data) {
                snapshots = [pending.before]
            }
            for snapshot in snapshots {
                if shared.contains(snapshot.reference) { kept += 1; continue }
                do { try store.remove(snapshot); removed += 1 }
                catch { ServerLog.error("agent checkpoint not removed: \(error)") }
            }
        }
        let earlier = root.appendingPathComponent("earlier/" + session.description
            + (saved.snapshot.resetID.map { "-" + $0.description } ?? "") + ".jsonl")
        for path in [checkpoints,
                     root.appendingPathComponent("outputs", isDirectory: true).appendingPathComponent(session.description, isDirectory: true),
                     root.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent(session.description, isDirectory: true),
                     earlier,
                     root.appendingPathComponent("inbox/" + session.description + ".json"),
                     root.appendingPathComponent(session.description + ".json")] {
            try? FileManager.default.removeItem(at: path)
        }
        subagentStore.removeConversation(session)
        retainedCheckpointIDs.removeValue(forKey: session)
        let deleted = AgentDeletedConversation(session: session, project: saved.snapshot.project, root: root, sharedReferences: shared)
        for cleanup in deletionCleanups { cleanup(deleted) }
        return AgentConversationDeletion(session: session, removedCheckpoints: removed, sharedCheckpoints: kept)
    }

    /// Every checkpoint ref another conversation's records name. Writer queue only.
    private func checkpointReferences(excluding session: SessionId) -> Set<String> {
        let folder = root.appendingPathComponent("checkpoints", isDirectory: true)
        var references = Set<String>()
        for directory in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where directory.lastPathComponent != session.description {
            for record in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                where record.pathExtension == "json" {
                guard let data = try? Data(contentsOf: record) else { continue }
                if let finished = try? JSONDecoder().decode(AgentCheckpointRecord.self, from: data) {
                    references.insert(finished.before.reference)
                    references.insert(finished.after.reference)
                } else if let pending = try? JSONDecoder().decode(AgentCheckpointPending.self, from: data) {
                    references.insert(pending.before.reference)
                }
            }
        }
        return references
    }

    // MARK: Usage limits and scheduled prompts

    /// Keeps a usage-limit stop and its reset time on the turn that hit it.
    func noteRateLimit(_ entry: Entry) {
        guard let activity = entry.snapshot.activity, activity.kind == .rateLimited,
              let index = entry.snapshot.turns?.indices.last, entry.snapshot.turns?[index].completedAt == nil else { return }
        entry.snapshot.turns?[index].rateLimit = AgentRateLimitStop(resetsAt: activity.resumesAt, message: activity.message)
    }

    /// Delivers the queue's scheduled prompt when its time comes.
    func wakeInbox(_ entry: Entry, at date: Date) {
        let delay = max(0, date.timeIntervalSince(now()))
        let session = entry.snapshot.session
        queue.asyncAfter(deadline: .now() + delay + 0.01) { [weak self] in
            guard let self, self.entries[session] === entry, !self.stopping else { return }
            self.drainInbox(entry)
        }
    }

    /// The request an approval answer settles, for `approve` and `decide`.
    static func answeredRequest(_ request: AgentChatRequest) -> String? {
        switch request {
        case .approve(_, let id, _, _, _), .decide(_, let id, _, _): id
        default: nil
        }
    }
}
