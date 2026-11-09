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
    }
    var records: [Record] = []
    var paused = false
    var visible: [AgentQueuedPrompt] { records.compactMap(\.display) }

    static func fingerprint(_ prompt: AgentPrompt) throws -> String {
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
    func index(_ id: String, revision: UInt64) throws -> Int {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let display = records[index].display, display.revision == revision,
              display.state != .delivering else { throw AgentRuntimeError("This queued prompt changed. Refresh before trying again.") }
        return index
    }
    mutating func recover() {
        paused = !visible.isEmpty || paused
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
