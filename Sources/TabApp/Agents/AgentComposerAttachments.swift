import AppKit
import ImageIO
import TabProtocol
import UniformTypeIdentifiers

/// A draft owns bytes, never a client filesystem path, and survives failed sends.
struct AgentDraftAttachment: Identifiable, @unchecked Sendable {
    let id: String
    let name: String
    let mimeType: String
    let data: Data
    let thumbnail: NSImage?

    init(id: String = UUID().uuidString, name: String, mimeType: String, data: Data, thumbnail: NSImage? = nil) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
        self.thumbnail = thumbnail
    }
}

enum AgentAttachmentImportError: LocalizedError {
    case notRegularFile(String), tooLarge(String), tooManyFiles, batchTooLarge, invalidImage

    var errorDescription: String? {
        switch self {
        case .notRegularFile(let name): return "\(name) is not a regular file. Choose files rather than folders or aliases."
        case .tooLarge(let name): return "\(name) exceeds the attachment size limit (8 MiB)."
        case .tooManyFiles: return "Attach at most 10 files at a time."
        case .batchTooLarge: return "Attachments must total no more than 8 MiB at a time."
        case .invalidImage: return "This image could not be read. Try exporting it as PNG or JPEG."
        }
    }
}

enum AgentAttachmentImporter {
    static let maximumFileSize = AgentChatAttachment.maxFileBytes
    static let maximumBatchSize = AgentChatAttachment.maxTotalBytes
    static let maximumFileCount = AgentChatAttachment.maxCount

    /// Atomic import, bounded even if a file grows after its metadata was checked.
    static func load(urls: [URL], maximumFileSize: Int = maximumFileSize) async throws -> [AgentDraftAttachment] {
        guard urls.count <= maximumFileCount else { throw AgentAttachmentImportError.tooManyFiles }
        guard maximumFileSize > 0 else { throw AgentAttachmentImportError.batchTooLarge }
        let worker = Task.detached(priority: .userInitiated) {
            var attachments: [AgentDraftAttachment] = []
            var total = 0
            for url in urls {
                try Task.checkCancellation()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let name = url.lastPathComponent
                guard url.isFileURL else { throw AgentAttachmentImportError.notRegularFile(name) }
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true else {
                    throw AgentAttachmentImportError.notRegularFile(name)
                }
                guard (info.fileSize ?? 0) <= maximumFileSize else { throw AgentAttachmentImportError.tooLarge(name) }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var data = Data()
                while true {
                    try Task.checkCancellation()
                    let chunk = try handle.read(upToCount: min(64 * 1024, maximumFileSize - data.count + 1)) ?? Data()
                    if chunk.isEmpty { break }
                    guard data.count + chunk.count <= maximumFileSize else { throw AgentAttachmentImportError.tooLarge(name) }
                    data.append(chunk)
                }
                let type = info.contentType ?? UTType(filenameExtension: url.pathExtension)
                let attachment = try prepare(data: data, name: name, type: type, limit: maximumFileSize)
                total += attachment.data.count
                guard total <= maximumBatchSize else { throw AgentAttachmentImportError.batchTooLarge }
                attachments.append(attachment)
            }
            return attachments
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    /// Invoke off-main for clipboard images; normalization can decode image data.
    static func fromImage(data: Data, mimeType: String) throws -> AgentDraftAttachment {
        guard data.count <= maximumFileSize else { throw AgentAttachmentImportError.tooLarge("Pasted image") }
        guard let type = UTType(mimeType: mimeType), type.conforms(to: .image) else {
            throw AgentAttachmentImportError.invalidImage
        }
        return try prepare(data: data, name: "Pasted image.\(type.preferredFilenameExtension ?? "png")", type: type, limit: maximumFileSize)
    }

    /// Lazy popover preview: no full-resolution decode or larger draft cache.
    /// Like draft thumbnails, the immutable image is handed to the main actor
    /// only after the background worker has finished constructing it.
    static func previewImage(data: Data) async -> NSImage? {
        guard !data.isEmpty, data.count <= maximumFileSize else { return nil }
        let worker = Task.detached(priority: .userInitiated) { () -> PreviewImage? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = makeThumbnail(source, pixels: 1200),
                  !Task.isCancelled else { return nil }
            return PreviewImage(image: NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height))))
        }
        return await withTaskCancellationHandler(operation: { await worker.value?.image }, onCancel: { worker.cancel() })
    }

    private struct PreviewImage: @unchecked Sendable {
        let image: NSImage
    }

    private static func prepare(data: Data, name: String, type: UTType?, limit: Int) throws -> AgentDraftAttachment {
        var bytes = data
        var filename = name
        var mime = type?.preferredMIMEType ?? "application/octet-stream"
        var thumbnail: NSImage?
        if type?.conforms(to: .image) == true {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw AgentAttachmentImportError.invalidImage
            }
            let actualType = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
            let actualMIME = actualType?.preferredMIMEType ?? mime
            // Common provider formats remain intact. HEIC/TIFF become an
            // orientation-correct PNG, downsampled to bound decode memory.
            if !["image/png", "image/jpeg", "image/gif", "image/webp"].contains(actualMIME) {
                guard let image = makeThumbnail(source, pixels: 4096) else { throw AgentAttachmentImportError.invalidImage }
                bytes = try pngData(image)
                guard bytes.count <= limit else { throw AgentAttachmentImportError.tooLarge(name) }
                filename = (name as NSString).deletingPathExtension + ".png"
                mime = "image/png"
            } else {
                mime = actualMIME
            }
            guard let image = makeThumbnail(source, pixels: 128) else { throw AgentAttachmentImportError.invalidImage }
            thumbnail = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return AgentDraftAttachment(name: filename, mimeType: mime, data: bytes, thumbnail: thumbnail)
    }

    private static func makeThumbnail(_ source: CGImageSource, pixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw AgentAttachmentImportError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AgentAttachmentImportError.invalidImage }
        return output as Data
    }
}

/// Shared paste/drop interpretation. Finder file URLs outrank incidental text
/// or image representations. Remote URLs remain ordinary text.
@MainActor
enum AgentAttachmentPasteboard {
    enum Payload {
        case files([URL])
        case image(Data, String)
    }

    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        if !fileURLs(pasteboard).isEmpty { return true }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    static func payload(_ pasteboard: NSPasteboard) -> Payload? {
        let urls = fileURLs(pasteboard)
        if !urls.isEmpty { return .files(urls) }
        if let data = pasteboard.data(forType: .png) { return .image(data, "image/png") }
        // Conversion belongs on the import worker, not in the AppKit event loop.
        if let data = pasteboard.data(forType: .tiff) { return .image(data, "image/tiff") }
        return nil
    }

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    @discardableResult
    static func receive(_ pasteboard: NSPasteboard, onFiles: (([URL]) -> Void)?, onImage: ((Data, String) -> Void)?) -> Bool {
        switch payload(pasteboard) {
        case .files(let urls): onFiles?(urls); return true
        case .image(let data, let mime): onImage?(data, mime); return true
        case nil: return false
        }
    }
}

@MainActor
final class AgentAttachmentStrip: NSView {
    var onRemove: ((String) -> Void)?
    var onPreview: ((String) -> Void)? { didSet { rebuild() } }
    private(set) var hasAttachments = false
    private var chatTheme: AppTheme = .shared
    private let scroll = NSScrollView()
    private let content = NSView()
    private var attachments: [AgentDraftAttachment] = []
    private var chips: [AgentAttachmentChip] = []
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: hasAttachments ? 76 : 0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = content
        addSubview(scroll)
        setAccessibilityLabel("Message attachments")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ attachments: [AgentDraftAttachment], theme: AppTheme) {
        let sameDrafts = self.attachments.map(\.id) == attachments.map(\.id)
        self.attachments = attachments
        chatTheme = theme
        hasAttachments = !attachments.isEmpty
        // Streaming/theme refreshes must not replace focused Remove buttons or
        // interrupt the user's horizontal scroll through an unchanged draft.
        if sameDrafts {
            chips.forEach { $0.chatTheme = theme }
        } else {
            rebuild()
        }
        invalidateIntrinsicContentSize()
    }

    func updateTheme(_ theme: AppTheme) {
        chatTheme = theme
        chips.forEach { $0.chatTheme = theme }
    }

    private func rebuild() {
        chips.forEach { $0.removeFromSuperview() }
        chips = attachments.map { attachment in
            let chip = AgentAttachmentChip(attachment: attachment)
            chip.chatTheme = chatTheme
            chip.onRemove = { [weak self] in self?.onRemove?(attachment.id) }
            if onPreview != nil { chip.onPreview = { [weak self] in self?.onPreview?(attachment.id) } }
            content.addSubview(chip)
            return chip
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width)
        let height = max(0, min(76, bounds.height))
        scroll.isHidden = width == 0 || height == 0
        scroll.frame = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: height)
        content.frame = NSRect(x: 0, y: 0, width: max(width, CGFloat(chips.count) * 226), height: height)
        for (index, chip) in chips.enumerated() {
            chip.frame = NSRect(x: CGFloat(index) * 226, y: min(8, height), width: 218, height: max(0, min(60, height - 16)))
        }
    }
}

@MainActor
private final class AgentAttachmentChip: NSView {
    var onRemove: (() -> Void)?
    var onPreview: (() -> Void)? { didSet { preview.isEnabled = onPreview != nil } }
    var chatTheme: AppTheme = .shared { didSet { applyTheme() } }
    private let image = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let size = NSTextField(labelWithString: "")
    private let remove = NSButton()
    private let preview = NSButton()
    override var isFlipped: Bool { true }

    init(attachment: AgentDraftAttachment) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        image.image = attachment.thumbnail ?? NSWorkspace.shared.icon(for: UTType(mimeType: attachment.mimeType) ?? .data)
        image.imageScaling = .scaleProportionallyUpOrDown
        name.stringValue = attachment.name
        name.font = AppFont.small
        name.lineBreakMode = .byTruncatingMiddle
        size.stringValue = ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)
        size.font = AppFont.system(10)
        remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove attachment")
        remove.isBordered = false
        remove.target = self
        remove.action = #selector(removePressed)
        remove.toolTip = "Remove \(attachment.name)"
        remove.setAccessibilityLabel("Remove \(attachment.name)")
        preview.isBordered = false
        preview.title = ""
        preview.isEnabled = false
        preview.target = self
        preview.action = #selector(previewPressed)
        preview.setAccessibilityLabel("Preview \(attachment.name)")
        for view in [image, name, size, preview, remove] { addSubview(view) }
        toolTip = "\(attachment.name) — \(size.stringValue)"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(attachment.name), \(size.stringValue), attachment")
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applyTheme() {
        layer?.backgroundColor = chatTheme.fg.withAlphaComponent(0.035).cgColor
        layer?.borderColor = chatTheme.border.cgColor
        name.textColor = chatTheme.fg
        size.textColor = chatTheme.fgMuted
        remove.contentTintColor = chatTheme.fgMuted
    }

    override func layout() {
        super.layout()
        image.frame = NSRect(x: 8, y: 8, width: 44, height: 44)
        name.frame = NSRect(x: 60, y: 11, width: 126, height: 18)
        size.frame = NSRect(x: 60, y: 32, width: 126, height: 16)
        preview.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - 28), height: max(0, bounds.height))
        remove.frame = NSRect(x: max(0, bounds.width - 27), y: 5, width: 22, height: 22)
    }
    @objc private func removePressed() { onRemove?() }
    @objc private func previewPressed() { onPreview?() }
}
