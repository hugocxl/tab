import Foundation
import TabProtocol

/// The steps of each agent a conversation started, saved so a finished agent's steps stay
/// readable after its provider process ends or the server restarts.
///
/// Each agent is scoped to its parent conversation, the tool call that started it and the
/// conversation's project, and lives in this server's store, under
/// `subagents/<conversation>/`: a record of its newest steps (the window the provider
/// keeps) and an archive of older steps that rolled out of that window, one JSON line
/// each. The archive stops at `maxArchivedSteps` or `maxArchiveBytes`; later roll-outs are
/// only counted, so a reader can say how many steps weren't kept. A conversation keeps at
/// most `maxAgents` agents, dropping the oldest saved. Removing a conversation removes its
/// folder (`removeConversation(_:)`), the one cleanup hook for every retention path.
///
/// Content revisions live on the sessions queue; records and files on the persistence
/// queue, which writes a changed record at most once a second while its agent runs and
/// right away when it ends.
final class AgentSubagentStore: @unchecked Sendable {
    struct Record: Codable {
        var parent: SessionId
        var project: ProjectId
        var toolUseID: String
        var agentID: String?
        var description: String?
        var status: AgentSubagent.Status?
        var revision: UInt64
        /// The newest steps, as the provider keeps them.
        var items: [AgentChatItem]
        /// Lines in the archive.
        var archivedSteps: Int
        /// Steps that rolled out after the archive was full.
        var omittedSteps: Int
        var savedAt: Date?
    }

    static let folder = "subagents"
    static let maxAgents = 32
    static let maxArchivedSteps = 1000
    static let maxArchiveBytes = 2 * 1024 * 1024

    private struct Key: Hashable {
        var session: SessionId
        var toolUseID: String
    }

    private let root: URL
    private let writer: DispatchQueue
    /// Sessions queue only: each live agent's content revision.
    private var revisions: [Key: UInt64] = [:]
    /// Persistence queue only.
    private var records: [Key: Record] = [:]
    private var dirty: Set<Key> = []
    private var flushScheduled = false

    init(root: URL, writer: DispatchQueue) {
        self.root = root.appendingPathComponent(Self.folder, isDirectory: true)
        self.writer = writer
    }

    func directory(_ session: SessionId) -> URL {
        root.appendingPathComponent(session.description, isDirectory: true)
    }

    private func recordFile(_ key: Key) -> URL {
        directory(key.session).appendingPathComponent(AgentToolImages.directoryName(item: key.toolUseID) + ".json")
    }

    private func archiveFile(_ key: Key) -> URL {
        directory(key.session).appendingPathComponent(AgentToolImages.directoryName(item: key.toolUseID) + ".jsonl")
    }

    // MARK: Sessions queue

    /// The content revision of a live agent's steps, if it changed since the server started.
    func revision(session: SessionId, toolUseID: String) -> UInt64? {
        revisions[Key(session: session, toolUseID: toolUseID)]
    }

    /// Saves an agent's newest steps, read on the sessions queue. Steps in `previous` that
    /// are no longer in `items` rolled out of the provider's window and go to the archive.
    /// Returns the new content revision, `revision`, or nil when nothing changed.
    func record(session: SessionId, project: ProjectId, toolUseID: String, agent: AgentSubagent?,
                previous: [AgentChatItem]?, items: [AgentChatItem], revision: UInt64) -> UInt64? {
        guard previous != items else { return nil }
        let key = Key(session: session, toolUseID: toolUseID)
        // Strictly increasing per agent, even when the conversation's revision didn't move.
        let revision = max(revision, (revisions[key] ?? 0) &+ 1)
        revisions[key] = revision
        // The provider's window drops its oldest steps first; while its first step stays,
        // nothing rolled out, and streamed text costs no set of IDs.
        var rolled: [AgentChatItem] = []
        if let previous, !previous.isEmpty, previous.first?.id != items.first?.id {
            let kept = Set(items.map(\.id))
            rolled = previous.filter { !kept.contains($0.id) }
        }
        let lines = rolled.compactMap { item -> Data? in
            guard var data = try? JSONEncoder().encode(item) else { return nil }
            data.append(0x0A)
            return data
        }
        writer.async { [self] in
            var record = load(key) ?? Record(parent: session, project: project, toolUseID: toolUseID, revision: revision,
                                             items: [], archivedSteps: 0, omittedSteps: 0)
            record.items = items
            record.revision = revision
            record.agentID = agent?.id ?? record.agentID
            record.description = agent?.description ?? record.description
            record.status = agent?.status ?? record.status
            if !lines.isEmpty { archive(lines, key: key, record: &record) }
            records[key] = record
            markDirty(key, now: agent.map { $0.status != .running } ?? false)
        }
        return revision
    }

    /// The agent `agent` changed status; a finished one is saved right away.
    func update(session: SessionId, agent: AgentSubagent) {
        guard let toolUseID = agent.toolUseID else { return }
        let key = Key(session: session, toolUseID: toolUseID)
        guard revisions[key] != nil else { return }
        writer.async { [self] in
            guard var record = load(key), record.status != agent.status || record.description != agent.description else { return }
            record.status = agent.status
            record.description = agent.description
            record.agentID = agent.id
            records[key] = record
            markDirty(key, now: agent.status != .running)
        }
    }

    /// The conversation's provider process ended, and every agent it ran with it.
    func providerEnded(session: SessionId) {
        let keys = revisions.keys.filter { $0.session == session }
        guard !keys.isEmpty else { return }
        for key in keys { revisions.removeValue(forKey: key) }
        writer.async { [self] in
            for key in keys {
                guard var record = load(key) else { continue }
                AgentSessions.finishItems(&record.items)
                if record.status == .running || record.status == nil { record.status = .stopped }
                records[key] = record
                dirty.insert(key)
            }
            flush()
        }
    }

    // MARK: Persistence queue

    private func load(_ key: Key) -> Record? {
        if let record = records[key] { return record }
        guard let data = try? Data(contentsOf: recordFile(key)),
              var record = try? JSONDecoder().decode(Record.self, from: data),
              record.toolUseID == key.toolUseID else { return nil }
        // A cleared conversation's archive holds its agents in its own folder.
        record.parent = key.session
        records[key] = record
        return record
    }

    private func archive(_ lines: [Data], key: Key, record: inout Record) {
        let file = archiveFile(key)
        var size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var accepted = Data()
        for line in lines {
            guard record.archivedSteps < Self.maxArchivedSteps, size + line.count <= Self.maxArchiveBytes else {
                record.omittedSteps += 1
                continue
            }
            accepted.append(line)
            size += line.count
            record.archivedSteps += 1
        }
        guard !accepted.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: accepted)
        } catch {
            ServerLog.error("agent steps not archived: \(error)")
        }
    }

    private func markDirty(_ key: Key, now: Bool) {
        dirty.insert(key)
        if now { flush(); return }
        guard !flushScheduled else { return }
        flushScheduled = true
        writer.asyncAfter(deadline: .now() + 1) { [self] in
            flushScheduled = false
            flush()
        }
    }

    /// Writes every changed record. Persistence queue only.
    func flush() {
        let keys = dirty
        dirty.removeAll()
        for session in Set(keys.map(\.session)) {
            try? FileManager.default.createDirectory(at: directory(session), withIntermediateDirectories: true)
        }
        for key in keys {
            guard var record = records[key] else { continue }
            record.savedAt = Date()
            records[key] = record
            do { try JSONEncoder().encode(record).write(to: recordFile(key), options: .atomic) }
            catch { ServerLog.error("agent steps not saved: \(error)") }
        }
        for session in Set(keys.map(\.session)) { prune(session) }
    }

    /// Keeps a conversation's newest `maxAgents` saved agents.
    private func prune(_ session: SessionId) {
        let folder = directory(session)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let saved = files.filter { $0.pathExtension == "json" }
        guard saved.count > Self.maxAgents else { return }
        let dated = saved.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 < $1.1 }
        for (file, _) in dated.prefix(saved.count - Self.maxAgents) {
            let name = file.deletingPathExtension().lastPathComponent
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name + ".jsonl"))
            records = records.filter { $0.key.session != session || AgentToolImages.directoryName(item: $0.key.toolUseID) != name }
        }
    }

    /// Before a conversation's folder is copied or removed: writes its changed records and
    /// forgets those it holds. Persistence queue only.
    func release(_ session: SessionId) {
        if dirty.contains(where: { $0.session == session }) { flush() }
        records = records.filter { $0.key.session != session }
    }

    /// Removes everything saved for a conversation's agents. Persistence queue only.
    func removeConversation(_ session: SessionId) {
        dirty = dirty.filter { $0.session != session }
        records = records.filter { $0.key.session != session }
        try? FileManager.default.removeItem(at: directory(session))
    }

    // MARK: Reading, on a blocking worker

    /// The saved steps of the agent `toolUseID` in `session`, if any were saved for it in
    /// `project`. `live` are the steps its provider still holds, newer than the record; a
    /// `listed` agent without any yet just hasn't taken a step.
    func steps(session: SessionId, project: ProjectId, toolUseID: String, live: [AgentChatItem]?,
               listed: Bool = false) -> AgentSubagentSteps {
        let key = Key(session: session, toolUseID: toolUseID)
        let record: Record? = writer.sync { load(key) }
        guard let record, record.project == project else {
            return AgentSubagentSteps(toolUseID: toolUseID, items: live ?? [], unavailable: live == nil && !listed ? true : nil)
        }
        var items = live ?? record.items
        if live == nil { AgentSessions.finishItems(&items) }
        return AgentSubagentSteps(toolUseID: toolUseID, items: items, revision: record.revision,
                                  earlierSteps: record.archivedSteps, omittedSteps: record.omittedSteps)
    }

    /// Archived steps before position `before`, newest last.
    func earlier(session: SessionId, project: ProjectId, toolUseID: String, before: Int?, limit: Int) -> AgentEarlierItems {
        let key = Key(session: session, toolUseID: toolUseID)
        let file = archiveFile(key)
        let record: Record? = writer.sync { load(key) }
        guard let record, record.project == project, let data = try? Data(contentsOf: file) else {
            return AgentEarlierItems(items: [], start: 0, total: 0)
        }
        let lines = Array(data.split(separator: 0x0A, omittingEmptySubsequences: true).prefix(record.archivedSteps))
        let end = min(before ?? lines.count, lines.count)
        var items: [AgentChatItem] = []
        var bytes = 0
        var start = end
        while start > 0, items.count < limit {
            guard let item = try? JSONDecoder().decode(AgentChatItem.self, from: Data(lines[start - 1])) else { start -= 1; continue }
            guard bytes + item.transcriptByteCount <= AgentEarlierItems.maxBytes else { break }
            bytes += item.transcriptByteCount
            items.insert(item, at: 0)
            start -= 1
        }
        AgentSessions.finishItems(&items)
        return AgentEarlierItems(items: items, start: start, total: lines.count)
    }
}
