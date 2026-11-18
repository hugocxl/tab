import AppKit
import TabCore
import TabProtocol

/// A draft set aside for later in one conversation: its text with quotations and thread
/// mentions, review comments, the settings it was written for, and its attachments, whose
/// bytes are kept in files of their own.
struct AgentStashedDraft: Codable, Sendable, Identifiable, Equatable {
    struct Settings: Codable, Sendable, Equatable {
        var provider: String
        var model: String?
        var effort: AgentReasoningEffort?
        var planMode: Bool
    }

    var id: String
    var savedAt: Date
    /// Text, citation spans and review comments; attachment bytes are stored beside it.
    var draft: AgentSavedDraft
    var attachments: [AgentChatAttachmentDescriptor]
    var settings: Settings?

    var title: String {
        let line = draft.text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !line.isEmpty { return String(line.prefix(120)) }
        if let first = attachments.first { return attachments.count == 1 ? first.name : "\(first.name) and \(attachments.count - 1) more" }
        return draft.reviewComments?.isEmpty == false ? "Review comments" : "Empty draft"
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.savedAt == rhs.savedAt }
}

/// A stashed draft read back: the attachments still available, and those that aren't.
struct AgentRestoredStash: Sendable {
    var entry: AgentStashedDraft
    var attachments: [AgentChatAttachment]
    var unavailable: [AgentChatAttachmentDescriptor]
}

/// Stashed drafts of one conversation pane, kept beside its draft. The index is written
/// only after an entry's attachment files, and an entry leaves only once restored, so a
/// crash keeps either the old index or a complete new one.
actor AgentDraftStash {
    static let maximumEntries = 20
    nonisolated let directory: URL

    init(draftURL: URL) {
        directory = draftURL.deletingPathExtension().appendingPathExtension("stash")
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func blobURL(entry: String, attachment: String) -> URL {
        // Attachment IDs come from the draft; encode them so they never name a path.
        let safe = Data(attachment.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return directory.appendingPathComponent(entry, isDirectory: true).appendingPathComponent(safe)
    }

    func list() throws -> [AgentStashedDraft] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        guard (try indexURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16 * 1024 * 1024 else {
            throw ModelError("The stashed drafts index exceeds its size limit.")
        }
        return try JSONDecoder().decode([AgentStashedDraft].self, from: Data(contentsOf: indexURL))
    }

    func stash(_ draft: AgentSavedDraft, settings: AgentStashedDraft.Settings?) throws -> AgentStashedDraft {
        var entries = try list()
        guard entries.count < Self.maximumEntries else {
            throw ModelError("This conversation already has \(Self.maximumEntries) stashed drafts. Restore one first.")
        }
        let entry = AgentStashedDraft(id: UUID().uuidString, savedAt: Date(),
                                      draft: AgentSavedDraft(copying: draft, attachments: []),
                                      attachments: draft.attachments.map(\.descriptor), settings: settings)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(entry.id, isDirectory: true),
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for attachment in draft.attachments {
            let url = blobURL(entry: entry.id, attachment: attachment.id)
            try attachment.data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        entries.append(entry)
        try save(entries)
        return entry
    }

    /// The entry with the attachments whose bytes are still intact; the entry stays
    /// stashed until `remove`.
    func read(_ id: String) throws -> AgentRestoredStash {
        guard let entry = try list().first(where: { $0.id == id }) else {
            throw ModelError("That stashed draft is no longer available.")
        }
        var attachments: [AgentChatAttachment] = [], unavailable: [AgentChatAttachmentDescriptor] = []
        for descriptor in entry.attachments {
            let url = blobURL(entry: entry.id, attachment: descriptor.id)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            guard size == descriptor.byteCount, let data = try? Data(contentsOf: url), data.count == descriptor.byteCount else {
                unavailable.append(descriptor)
                continue
            }
            attachments.append(AgentChatAttachment(id: descriptor.id, name: descriptor.name, mimeType: descriptor.mimeType, data: data))
        }
        return AgentRestoredStash(entry: entry, attachments: attachments, unavailable: unavailable)
    }

    func remove(_ id: String) throws {
        let entries = try list()
        guard entries.contains(where: { $0.id == id }) else { return }
        try save(entries.filter { $0.id != id })
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
    }

    private func save(_ entries: [AgentStashedDraft]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        try encoder.encode(entries).write(to: indexURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }
}

extension AgentSavedDraft {
    /// The same draft with other attachments.
    init(copying draft: AgentSavedDraft, attachments: [AgentChatAttachment]) {
        self = draft
        self.attachments = attachments
    }

    /// Nothing worth keeping: no text, attachments or review comments.
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && (reviewComments ?? []).isEmpty
    }
}
