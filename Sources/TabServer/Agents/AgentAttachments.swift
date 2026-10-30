import Foundation
import TabProtocol

/// Only constructed from bytes accepted by the session owner. Never accepts a client path.
internal struct StagedAgentAttachment: Sendable {
    let attachment: AgentChatAttachment
    let url: URL
}

internal enum AgentAttachments {
    static let imageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    static func stage(_ attachments: [AgentChatAttachment], root: URL) throws -> [StagedAgentAttachment] {
        try AgentChatAttachment.validate(attachments)
        // Reject unsupported native images explicitly instead of silently sending them as text.
        for attachment in attachments where attachment.mimeType.lowercased().hasPrefix("image/") {
            guard imageTypes.contains(attachment.mimeType.lowercased()) else {
                throw AgentRuntimeError("Unsupported image type for \(attachment.name): \(attachment.mimeType). Use PNG, JPEG, GIF or WebP.")
            }
        }
        guard !attachments.isEmpty else { return [] }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        do {
            return try attachments.map { attachment in
                // Neither the supplied ID nor name can select a filesystem location.
                let ext = (attachment.name as NSString).pathExtension
                let safeExtension = !ext.isEmpty && ext.count <= 16 && ext.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                } ? "." + ext : ""
                let url = directory.appendingPathComponent(UUID().uuidString + safeExtension)
                try attachment.data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return StagedAgentAttachment(attachment: attachment, url: url)
            }
        } catch {
            // Only remove this request's fresh directory; previously sent files remain resumable.
            try? FileManager.default.removeItem(at: directory)
            throw AgentRuntimeError("Could not stage attachments: \(error.localizedDescription)")
        }
    }

    static func prompt(text: String, attachments: [StagedAgentAttachment]) -> String {
        guard !attachments.isEmpty else { return text }
        let references = attachments.map { staged in
            // JSON quoting preserves boundaries even with unusual display names.
            let reference = ["name": staged.attachment.name, "path": staged.url.path]
            // These are plain strings, so JSON encoding cannot fail.
            let encoded = (try? WireJSON.encode(reference)) ?? Data()
            return String(decoding: encoded, as: UTF8.self)
        }.joined(separator: "\n")
        return text + "\n\nAttached files (stored on this host; read these paths for their full contents):\n" + references
    }

    static func claudeContent(text: String, attachments: [StagedAgentAttachment]) -> Any {
        guard !attachments.isEmpty else { return text }
        var content: [[String: Any]] = [["type": "text", "text": prompt(text: text, attachments: attachments)]]
        for staged in attachments {
            let attachment = staged.attachment
            let mime = attachment.mimeType.lowercased()
            if imageTypes.contains(mime) || mime == "application/pdf" {
                content.append(["type": mime == "application/pdf" ? "document" : "image",
                                "source": ["type": "base64", "media_type": mime,
                                           "data": attachment.data.base64EncodedString()]])
            }
        }
        return content
    }

    static func codexInput(text: String, attachments: [StagedAgentAttachment]) -> [[String: Any]] {
        var input: [[String: Any]] = [["type": "text", "text": prompt(text: text, attachments: attachments), "text_elements": []]]
        for staged in attachments where imageTypes.contains(staged.attachment.mimeType.lowercased()) {
            input.append(["type": "image", "url": "data:\(staged.attachment.mimeType.lowercased());base64,\(staged.attachment.data.base64EncodedString())"])
        }
        return input
    }
}
