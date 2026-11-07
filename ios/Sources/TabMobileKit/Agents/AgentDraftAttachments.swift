import Foundation
import TabProtocol
import UniformTypeIdentifiers

/// The files a message will carry, kept within what the server accepts.
public enum AgentDraftAttachments {
    /// The image types agents read natively; other images are sent as JPEG.
    public static let imageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// The MIME type the server is told for a file of this name.
    public static func mimeType(forFilename name: String) -> String {
        let pathExtension = (name as NSString).pathExtension
        return UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Whether a file of this type is an image the agent can't read as it is.
    public static func needsConversion(mimeType: String) -> Bool {
        let type = mimeType.lowercased()
        return type.hasPrefix("image/") && !imageTypes.contains(type)
    }

    /// Why `attachment` can't join `draft`, or nil when it can.
    public static func problem(adding attachment: AgentChatAttachment, to draft: [AgentChatAttachment]) -> String? {
        if draft.count >= AgentChatAttachment.maxCount {
            return "A message can carry up to \(AgentChatAttachment.maxCount) files."
        }
        let limit = ByteCountFormatter.string(fromByteCount: Int64(AgentChatAttachment.maxTotalBytes), countStyle: .file)
        if attachment.data.count > AgentChatAttachment.maxFileBytes {
            return "\(attachment.name) is larger than \(limit)."
        }
        if draft.reduce(attachment.data.count, { $0 + $1.data.count }) > AgentChatAttachment.maxTotalBytes {
            return "A message's files can add up to \(limit)."
        }
        return nil
    }
}
