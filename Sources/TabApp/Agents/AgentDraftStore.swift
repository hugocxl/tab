import AppKit
import TabProtocol

struct AgentSavedDraft: Codable, Sendable {
    struct Span: Codable, Sendable { var location: Int; var length: Int; var values: [String: String] }
    var text: String
    var spans: [Span]
    var attachments: [AgentChatAttachment]
    var submission: AgentPrompt?
    var answers: [String: [String: [String]]]
    var reviewComments: [AgentReviewComment]?
    @MainActor
    init(text: NSAttributedString, attachments: [AgentDraftAttachment], submission: AgentPrompt?, answers: [String: [String: [String]]], reviewComments: [AgentReviewComment] = []) {
        self.text = text.string; spans = []
        self.attachments = attachments.map { .init(id: $0.id, name: $0.name, mimeType: $0.mimeType, data: $0.data) }
        self.submission = submission; self.answers = answers
        self.reviewComments = reviewComments.isEmpty ? nil : reviewComments
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var values: [String: String] = [:]
            for key in [NSAttributedString.Key.agentAssistantCitation, .agentAssistantCitationIdentity, .agentThreadMention] {
                if let value = attributes[key] as? String { values[key.rawValue] = value }
            }
            if !values.isEmpty { spans.append(Span(location: range.location, length: range.length, values: values)) }
        }
    }
    @MainActor
    func attributed(theme: AppTheme) -> NSAttributedString {
        let value = NSMutableAttributedString(string: text, attributes: [.font: AppFont.system(14, weight: .light), .foregroundColor: theme.fg])
        let allowed = Set([NSAttributedString.Key.agentAssistantCitation, .agentAssistantCitationIdentity, .agentThreadMention].map(\.rawValue))
        for span in spans where span.location >= 0 && span.length >= 0 && span.location <= value.length && span.length <= value.length - span.location {
            let range = NSRange(location: span.location, length: span.length)
            for (key, text) in span.values where allowed.contains(key) { value.addAttribute(.init(key), value: text, range: range) }
            value.addAttributes([.foregroundColor: theme.accent, .backgroundColor: theme.accent.withAlphaComponent(0.1)], range: range)
        }
        return value
    }
}

/// Disk work is isolated from typing/layout; callers order saves by monotonically increasing revision.
actor AgentDraftStore {
    let url: URL
    private var revision: UInt64 = 0
    init(url: URL) { self.url = url }
    func read() throws -> AgentSavedDraft? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 24 * 1024 * 1024 else {
                throw ModelError("Draft exceeds its size limit.")
            }
            let draft = try JSONDecoder().decode(AgentSavedDraft.self, from: Data(contentsOf: url))
            try AgentChatAttachment.validate(draft.attachments)
            guard draft.text.utf8.count <= 256 * 1024 else { throw ModelError("Draft text exceeds its size limit.") }
            return draft
        } catch {
            let recovery = url.appendingPathExtension("unreadable-" + UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: recovery)
            throw ModelError("Could not restore the draft. Its original bytes are preserved at \(recovery.path).")
        }
    }
    func write(_ draft: AgentSavedDraft, revision: UInt64) throws {
        guard revision >= self.revision else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let bytes = try JSONEncoder().encode(draft)
        guard bytes.count <= 24 * 1024 * 1024 else { throw ModelError("The draft is too large to save.") }
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        self.revision = revision
    }
}
