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
        try validateForStaging(attachments)
        return try write(attachments, root: root)
    }

    /// The checks `stage` makes before writing anything, cheap enough for the sessions queue.
    static func validateForStaging(_ attachments: [AgentChatAttachment]) throws {
        try AgentChatAttachment.validate(attachments)
        // Reject unsupported native images explicitly instead of silently sending them as text.
        for attachment in attachments where attachment.mimeType.lowercased().hasPrefix("image/") {
            guard imageTypes.contains(attachment.mimeType.lowercased()) else {
                throw AgentRuntimeError("Unsupported image type for \(attachment.name): \(attachment.mimeType). Use PNG, JPEG, GIF or WebP.")
            }
        }
    }

    /// Writes and records `attachments` on a blocking worker, off the sessions queue.
    static func stageOffQueue(_ attachments: [AgentChatAttachment], root: URL) async throws -> [StagedAgentAttachment] {
        guard !attachments.isEmpty else { return [] }
        return try await runBlocking {
            let staged = try write(attachments, root: root)
            try record(staged, root: root)
            return staged
        }
    }

    static func stageToolImages(_ attachments: [AgentChatAttachment], root: URL) throws -> [StagedAgentAttachment] {
        guard attachments.count <= 8 else { throw AgentRuntimeError("Too many tool images.") }
        for attachment in attachments {
            try attachment.descriptor.validate()
            guard imageTypes.contains(attachment.mimeType), attachment.data.count <= AgentChatAttachment.maxPayloadBytes else {
                throw AgentRuntimeError("Invalid tool image.")
            }
        }
        return try write(attachments, root: root)
    }

    private static func write(_ attachments: [AgentChatAttachment], root: URL) throws -> [StagedAgentAttachment] {
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

    private struct Record: Codable {
        let descriptor: AgentChatAttachmentDescriptor
        let path: String
    }

    static func record(_ staged: [StagedAgentAttachment], root: URL) throws {
        guard !staged.isEmpty else { return }
        let records = staged.map {
            Record(descriptor: $0.attachment.descriptor,
                   path: $0.url.deletingLastPathComponent().lastPathComponent + "/" + $0.url.lastPathComponent)
        }
        let url = root.appendingPathComponent("index.json")
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func retrieve(_ descriptor: AgentChatAttachmentDescriptor, root: URL) throws -> AgentChatAttachment {
        try descriptor.validate()
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let index = base.appendingPathComponent("index.json")
        guard index.resolvingSymlinksInPath().standardizedFileURL == index,
              let size = try index.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 else {
            throw AgentRuntimeError("Attachment preview index is unavailable.")
        }
        let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: index))
        guard let record = records.first(where: { $0.descriptor == descriptor }) else {
            throw AgentRuntimeError("Attachment preview is unavailable for this message.")
        }
        let components = record.path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, UUID(uuidString: String(components[0])) != nil,
              UUID(uuidString: (String(components[1]) as NSString).deletingPathExtension) != nil else {
            throw AgentRuntimeError("Invalid stored attachment path.")
        }
        let file = base.appendingPathComponent(record.path).standardizedFileURL
        guard file.path.hasPrefix(base.path + "/"), file.resolvingSymlinksInPath().standardizedFileURL == file else {
            throw AgentRuntimeError("Invalid stored attachment path.")
        }
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, info.fileSize == descriptor.byteCount else {
            throw AgentRuntimeError("Stored attachment is missing or has changed.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: AgentChatAttachment.maxPayloadBytes + 1) ?? Data()
        guard data.count == descriptor.byteCount else { throw AgentRuntimeError("Stored attachment size changed.") }
        return AgentChatAttachment(id: descriptor.id, name: descriptor.name, mimeType: descriptor.mimeType, data: data)
    }

    static func prompt(text: String, attachments: [StagedAgentAttachment]) -> String {
        let text = AgentAssistantCitation.expandForProvider(text)
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
        guard !attachments.isEmpty else { return prompt(text: text, attachments: attachments) }
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
