import Foundation

/// Retrieves a payload owned by one persisted message, without accepting a filesystem path.
public struct AgentAttachmentRequest: Codable, Hashable, Sendable {
    public var session: SessionId
    public var item: String
    public var attachment: String
    public init(session: SessionId, item: String, attachment: String) {
        self.session = session; self.item = item; self.attachment = attachment
    }
    public func validate() throws(ErrorCode) {
        guard !item.isEmpty, item.utf8.count <= 1024, !item.contains("\0"), !attachment.isEmpty, attachment.utf8.count <= 128 else { throw .badRequest }
    }
}

public struct AgentAttachmentReply: Codable, Hashable, Sendable {
    public var attachment: AgentChatAttachment
    public init(attachment: AgentChatAttachment) { self.attachment = attachment }
    public func validate() throws(ErrorCode) {
        try attachment.descriptor.validate()
        guard attachment.data.count <= AgentChatAttachment.maxPayloadBytes else { throw .badRequest }
    }
}
