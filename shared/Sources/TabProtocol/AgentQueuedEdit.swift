import Foundation

/// A queued prompt's new text, settings and attachments, applied at once against the
/// revision the client edited. Attachments the server already holds are named by ID and
/// keep their bytes there; only new ones travel. A server that predates it can't decode
/// `AgentChatRequest.editQueuedPrompt` and replies `unsupported`, leaving the prompt as it was.
public struct AgentQueuedEdit: Codable, Hashable, Sendable {
    public var text: String
    /// Replacement settings, or nil to keep the prompt's own.
    public var settings: AgentQueuedSettings?
    /// IDs of the prompt's current attachments to keep, in their new order.
    public var keptAttachments: [String]
    /// New attachments, after the kept ones.
    public var addedAttachments: [AgentChatAttachment]

    public init(text: String, settings: AgentQueuedSettings? = nil, keptAttachments: [String] = [],
                addedAttachments: [AgentChatAttachment] = []) {
        self.text = text; self.settings = settings
        self.keptAttachments = keptAttachments; self.addedAttachments = addedAttachments
    }

    /// The attachment IDs the prompt holds after the edit, in order.
    public var attachmentIDs: [String] { keptAttachments + addedAttachments.map(\.id) }

    /// Why the edit would leave nothing to send, if it would.
    public static let emptyPromptMessage = "A queued prompt needs text or an attachment. Remove it from the queue instead."

    public func validate() throws(ErrorCode) {
        guard text.utf8.count <= 64 * 1024, !text.contains("\0") else { throw .badRequest }
        if let model = settings?.model { try Validation.message(model, limit: 256) }
        try settings?.effort?.validate()
        let ids = attachmentIDs
        guard ids.count <= AgentChatAttachment.maxCount, Set(ids).count == ids.count,
              keptAttachments.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw .badRequest }
        try AgentChatAttachment.validate(addedAttachments)
        // An edit never empties a prompt: removing it is a separate, explicit request.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ids.isEmpty else { throw .badRequest }
    }
}
