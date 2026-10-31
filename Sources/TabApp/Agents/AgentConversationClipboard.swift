import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The source ClipboardItem contract preserves binary PNG and textual MIME flavors.
@MainActor
enum AgentConversationClipboard {
    static let maximumBytes = 10 * 1024 * 1024

    static func write(_ payload: [String: Any], to pasteboard: NSPasteboard, pngBytes: Data? = nil) throws {
        guard (payload["flavors"] == nil || payload["flavors"] is [String: String]),
              (payload["binary"] == nil || payload["binary"] is [String: String]) else {
            throw ModelError("Invalid clipboard MIME content.")
        }
        let item = NSPasteboardItem()
        var cost = 0, hasContent = false
        var flavors = payload["flavors"] as? [String: String] ?? [:]
        if let text = payload["text"] as? String { flavors["text/plain"] = text }
        if let html = payload["html"] as? String { flavors["text/html"] = html }
        guard flavors.count <= 8 else { throw ModelError("Too many clipboard MIME types.") }
        for (mime, value) in flavors {
            guard mime.utf8.count <= 128, mime.hasPrefix("text/") || mime.hasPrefix("web text/") || ["web application/x-tab-context-fragment+json", "web application/x-t3-context-fragment+json"].contains(mime), !mime.contains("\0") else {
                throw ModelError("Unsupported clipboard MIME type.")
            }
            cost += value.utf8.count
            guard cost <= maximumBytes else { throw ModelError("Clipboard content exceeds 10 MiB.") }
            let type = try pasteboardType(forMIME: mime)
            guard item.setString(value, forType: type) else { throw ModelError("The clipboard MIME flavor could not be encoded.") }
            hasContent = true
        }
        var imageBytes = pngBytes
        if let binary = payload["binary"] as? [String: String], !binary.isEmpty {
            guard imageBytes == nil, binary.count == 1, let encoded = binary["image/png"],
                  encoded.utf8.count <= ((maximumBytes + 2) / 3) * 4,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= maximumBytes - cost else {
                throw ModelError("Invalid PNG clipboard content.")
            }
            imageBytes = bytes
        }
        if let bytes = imageBytes {
            guard let image = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(image) > 0,
                  CGImageSourceGetType(image) as String? == UTType.png.identifier else {
                throw ModelError("Invalid PNG clipboard content.")
            }
            guard item.setData(bytes, forType: .png) else { throw ModelError("The PNG clipboard flavor could not be encoded.") }
            hasContent = true
        }
        guard hasContent else { throw ModelError("The clipboard content is empty.") }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw ModelError("The clipboard could not be written.") }
    }
    /// ClipboardItem's `web ` prefix marks a custom web format; it is not part of
    /// the MIME type. AppKit requires the corresponding native UTI identifier.
    static func pasteboardType(forMIME mime: String) throws -> NSPasteboard.PasteboardType {
        let normalized = mime.hasPrefix("web ") ? String(mime.dropFirst(4)) : mime
        if normalized == "text/plain" { return .string }
        if normalized == "text/html" { return .html }
        guard let type = UTType(mimeType: normalized) else { throw ModelError("The clipboard MIME type has no native representation.") }
        return .init(type.identifier)
    }

}
