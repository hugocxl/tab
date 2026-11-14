import Foundation
import TabProtocol

/// What an agent pane's composer holds and hasn't sent: the message, its
/// files, the prompt last submitted (so a retry keeps its identity), and the
/// answers typed into a pending question, without private ones, and comments
/// on the changes of past turns.
public struct AgentDraft: Codable, Hashable, Sendable {
    public var text: String
    public var attachments: [AgentChatAttachment]
    /// The last prompt submitted from this draft; a retry of the same text and
    /// files reuses it, so the server can tell it already took it.
    public var submission: AgentPrompt?
    /// Answers by question request id, then by question id.
    public var answers: [String: [String: [String]]]
    /// Comments on turns' recorded changes, not yet added to the message.
    public var reviewComments: [AgentReviewComment]

    public init(text: String = "", attachments: [AgentChatAttachment] = [], submission: AgentPrompt? = nil,
                answers: [String: [String: [String]]] = [:], reviewComments: [AgentReviewComment] = []) {
        self.text = text
        self.attachments = attachments
        self.submission = submission
        self.answers = answers
        self.reviewComments = reviewComments
    }

    public var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty && submission == nil && answers.isEmpty && reviewComments.isEmpty
    }

    private enum CodingKeys: String, CodingKey { case text, attachments, submission, answers, reviewComments }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments = try c.decodeIfPresent([AgentChatAttachment].self, forKey: .attachments) ?? []
        submission = try? c.decodeIfPresent(AgentPrompt.self, forKey: .submission)
        answers = (try? c.decodeIfPresent([String: [String: [String]]].self, forKey: .answers)) ?? [:]
        reviewComments = (try? c.decodeIfPresent([AgentReviewComment].self, forKey: .reviewComments)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(attachments, forKey: .attachments)
        try c.encodeIfPresent(submission, forKey: .submission)
        try c.encode(answers, forKey: .answers)
        if !reviewComments.isEmpty { try c.encode(reviewComments, forKey: .reviewComments) }
    }
}

/// Each agent pane's draft in its own JSON file, written off the main thread.
/// Saves carry increasing revisions, and an older one never overwrites a newer.
public actor AgentDraftStore {
    private let directory: URL
    private var revisions: [SessionId: UInt64] = [:]
    private static let maximumBytes = 24 * 1024 * 1024

    public init(directory: URL) {
        self.directory = directory
    }

    private func url(_ session: SessionId) -> URL {
        directory.appendingPathComponent("\(session.description).json")
    }

    /// The saved draft, or nil when there is none or it can't be read.
    public func read(_ session: SessionId) -> AgentDraft? {
        let url = url(session)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: url),
              var draft = try? JSONDecoder().decode(AgentDraft.self, from: data) else { return nil }
        if (try? AgentChatAttachment.validate(draft.attachments)) == nil { draft.attachments = [] }
        return draft
    }

    /// Saves `draft`, or removes the file once the draft is empty.
    public func write(_ draft: AgentDraft, session: SessionId, revision: UInt64) throws {
        guard revision >= revisions[session] ?? 0 else { return }
        revisions[session] = revision
        let url = url(session)
        guard !draft.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(draft)
        guard data.count <= Self.maximumBytes else { return }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
