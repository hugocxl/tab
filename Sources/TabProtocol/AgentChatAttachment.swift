import Foundation

/// Bytes travel to the project host, never a client-local file path.
public struct AgentChatAttachment: Codable, Hashable, Sendable, Identifiable {
    // 8 MiB expands to ~10.7 MiB base64, leaving ample envelope/escaped-text
    // space below the 16 MiB frame cap without introducing partial uploads.
    public static let maxFileBytes = 8 * 1024 * 1024
    public static let maxTotalBytes = 8 * 1024 * 1024
    public static let maxCount = 10

    public var id: String
    public var name: String
    public var mimeType: String
    public var data: Data

    public init(id: String = UUID().uuidString, name: String, mimeType: String, data: Data) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
    }

    public var descriptor: AgentChatAttachmentDescriptor {
        .init(id: id, name: name, mimeType: mimeType, byteCount: data.count)
    }

    public static func validate(_ attachments: [Self]) throws(ErrorCode) {
        guard attachments.count <= maxCount,
              Set(attachments.map(\.id)).count == attachments.count else { throw .badRequest }
        var total = 0
        for attachment in attachments {
            try attachment.descriptor.validate()
            guard attachment.data.count <= maxFileBytes else { throw .badRequest }
            total += attachment.data.count
            guard total <= maxTotalBytes else { throw .badRequest }
        }
    }
}

/// Lightweight persisted transcript metadata. Payloads are kept only in host storage.
public struct AgentChatAttachmentDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var byteCount: Int

    public init(id: String, name: String, mimeType: String, byteCount: Int) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.byteCount = byteCount
    }

    public func validate() throws(ErrorCode) {
        guard !id.isEmpty, id.utf8.count <= 128,
              !name.isEmpty, name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !mimeType.isEmpty, mimeType.utf8.count <= 128,
              mimeType.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              byteCount >= 0, byteCount <= AgentChatAttachment.maxFileBytes else { throw .badRequest }
    }

    public var transcriptByteCount: Int { 128 + id.utf8.count + name.utf8.count + mimeType.utf8.count }
}
