import Foundation
import CryptoKit
import TabProtocol

/// Durable acceptance ledger. A delivering entry is never automatically replayed after a crash.
struct AgentPromptInbox: Codable {
    struct Record: Codable {
        var id: String
        var fingerprint: String
        var prompt: AgentPrompt?
        var display: AgentQueuedPrompt?
        /// Delivered no earlier than this, as the user scheduled it.
        var notBefore: Date?
        /// The agent this conversation started that the prompt reports on, written by the
        /// server; see `AgentReports`.
        var report: SessionId?
        /// The agent that started this conversation queued it, so the turn it starts is
        /// reported back to that agent.
        var byParent: Bool?
    }
    var records: [Record] = []
    var paused = false
    var visible: [AgentQueuedPrompt] { records.compactMap(\.display) }

    static func fingerprint(_ prompt: AgentPrompt) throws -> String {
        var prompt = prompt
        // Generated skill instructions are server-resolved, not part of the client's
        // delivery identity. A retry must not replay work when a skill file changed.
        if AgentSlashCommand(text: prompt.text)?.name.hasPrefix("skill:") == true {
            prompt.attachments.removeAll { $0.id == "skill-instructions" || $0.id == "native-skill" }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(prompt)).map { String(format: "%02x", $0) }.joined()
    }
    mutating func submit(_ prompt: AgentPrompt) throws {
        try prompt.validate()
        let fingerprint = try Self.fingerprint(prompt)
        if let existing = records.first(where: { $0.id == prompt.id }) {
            guard existing.fingerprint == fingerprint else { throw AgentRuntimeError("This submission ID belongs to a different prompt.") }
            return
        }
        guard visible.count < 16, records.count < 4096 else {
            throw AgentRuntimeError("This conversation's queue is full. Remove pending prompts or start a new conversation.")
        }
        guard records.compactMap(\.prompt).flatMap(\.attachments).reduce(0, { $0 + $1.data.count })
                + prompt.attachments.reduce(0, { $0 + $1.data.count }) <= 64 * 1024 * 1024 else {
            throw AgentRuntimeError("Queued attachments exceed 64 MB. Send or remove a queued prompt first.")
        }
        records.append(Record(id: prompt.id, fingerprint: fingerprint, prompt: prompt, display: .init(prompt: prompt)))
    }
    /// Queues `prompt` as the report on `agent`. A report on it still waiting in the queue
    /// takes the new text instead, so the parent hears only how the agent stands now.
    mutating func report(_ prompt: AgentPrompt, on agent: SessionId) throws {
        if let index = records.firstIndex(where: { $0.report == agent && $0.display?.state == .queued }),
           var queued = records[index].prompt {
            queued.text = prompt.text
            try queued.validate()
            records[index].prompt = queued
            records[index].fingerprint = try Self.fingerprint(queued)
            records[index].display?.text = queued.text
            records[index].display?.revision += 1
            return
        }
        try submit(prompt)
        records[records.count - 1].report = agent
    }

    /// Drops the report on `agent` still waiting in the queue, as when the parent read the
    /// agent itself. Reports already being delivered stay. Returns whether one went.
    mutating func withdrawReport(on agent: SessionId) -> Bool {
        guard let index = records.firstIndex(where: { $0.report == agent && $0.display?.state == .queued }) else {
            return false
        }
        records[index].prompt = nil
        records[index].display = nil
        return true
    }

    /// Whether the queued prompt `id` is a report from an agent this conversation started.
    func isReport(_ id: String) -> Bool { records.contains { $0.id == id && $0.report != nil } }

    func index(_ id: String, revision: UInt64) throws -> Int {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let display = records[index].display, display.revision == revision,
              display.state != .delivering else { throw AgentRuntimeError("This queued prompt changed. Refresh before trying again.") }
        return index
    }
    /// Applies text, settings and attachment changes to the queued prompt `id` at once, or
    /// nothing: a stale revision, a prompt that started, or an edit that would leave it
    /// empty or over a limit throws before anything changes.
    mutating func edit(_ id: String, revision: UInt64, _ edit: AgentQueuedEdit) throws {
        let index = try index(id, revision: revision)
        guard var prompt = records[index].prompt else {
            throw AgentRuntimeError("This queued prompt changed. Refresh before trying again.")
        }
        var kept: [AgentChatAttachment] = []
        for attachmentID in edit.keptAttachments {
            guard let attachment = prompt.attachments.first(where: { $0.id == attachmentID }) else {
                throw AgentRuntimeError("An attachment of this queued prompt changed. Refresh before trying again.")
            }
            kept.append(attachment)
        }
        prompt.attachments = kept + edit.addedAttachments
        prompt.text = edit.text
        if let settings = edit.settings {
            prompt.model = settings.model
            prompt.effort = settings.effort
            prompt.planMode = settings.planMode
        }
        guard !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !prompt.attachments.isEmpty else {
            throw AgentRuntimeError(AgentQueuedEdit.emptyPromptMessage)
        }
        do { try AgentChatAttachment.validate(prompt.attachments) } catch {
            throw AgentRuntimeError("Attach up to \(AgentChatAttachment.maxCount) files, totaling at most \(AgentChatAttachment.maxTotalBytes / 1024 / 1024) MB.")
        }
        do { try prompt.validate() } catch { throw AgentRuntimeError("This edit is not a valid prompt.") }
        let others = records.indices.filter { $0 != index }.compactMap { records[$0].prompt }
        guard others.flatMap(\.attachments).reduce(0, { $0 + $1.data.count })
                + prompt.attachments.reduce(0, { $0 + $1.data.count }) <= 64 * 1024 * 1024 else {
            throw AgentRuntimeError("Queued attachments exceed 64 MB. Send or remove a queued prompt first.")
        }
        records[index].prompt = prompt
        records[index].display?.text = prompt.text
        records[index].display?.attachments = prompt.attachments.map(\.descriptor)
        records[index].display?.revision += 1
    }

    mutating func recover() {
        // A prompt the user scheduled for later keeps its schedule; anything else waits for review.
        paused = paused || visible.contains { $0.scheduledAt == nil || $0.state != .queued }
        for index in records.indices where records[index].display?.state == .delivering {
            records[index].display?.state = .uncertain
            records[index].display?.error = "Delivery was interrupted. It may have reached the agent. Review the conversation before sending again."
            records[index].display?.revision += 1
        }
    }
    static func load(_ url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 96 * 1024 * 1024 else {
            throw AgentRuntimeError("The prompt queue exceeds its storage limit.")
        }
        var value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        value.recover()
        return value
    }
    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
