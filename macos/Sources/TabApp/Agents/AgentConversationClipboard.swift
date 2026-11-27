import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One clipboard item with textual MIME flavors and an optional PNG, written
/// atomically: invalid content never clears what the pasteboard held before.
@MainActor
enum AgentConversationClipboard {
    static let maximumBytes = 10 * 1024 * 1024

    /// `flavors` maps MIME types (`text/plain`, `text/html`, `web text/markdown`, …) to text.
    static func write(flavors: [String: String], png: Data? = nil, to pasteboard: NSPasteboard) throws {
        guard flavors.count <= 8 else { throw ModelError("Too many clipboard MIME types.") }
        let item = NSPasteboardItem()
        var cost = 0, hasContent = false
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
        if let png {
            guard !png.isEmpty, let image = CGImageSourceCreateWithData(png as CFData, nil), CGImageSourceGetCount(image) > 0,
                  CGImageSourceGetType(image) as String? == UTType.png.identifier else {
                throw ModelError("Invalid PNG clipboard content.")
            }
            guard item.setData(png, forType: .png) else { throw ModelError("The PNG clipboard flavor could not be encoded.") }
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
