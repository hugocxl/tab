import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The image action contract shared by inline media and the expanded viewer.
@MainActor
final class AgentImageActions: NSObject {
    var name: String
    var mimeType = "image/png"
    var fetch: (() async throws -> Data)?
    /// The media's link; with it the menu offers Copy link, and Open link with `onOpenLink`.
    var link: String?
    var onOpenLink: ((String) -> Void)?
    /// False for video and audio, whose menu offers only the link items.
    var includesImageItems = true
    weak var view: NSView?
    private var task: Task<Void, Never>?

    init(name: String) { self.name = name }
    deinit { task?.cancel() }
    func cancel() { task?.cancel(); task = nil }

    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, selector) in [("Save image", #selector(saveImage)), ("Copy image", #selector(copyImage))] where includesImageItems {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.isEnabled = fetch != nil
            menu.addItem(item)
        }
        guard let link, !link.isEmpty else { return menu }
        if includesImageItems { menu.addItem(.separator()) }
        let copyLink = NSMenuItem(title: "Copy link", action: #selector(copyLink), keyEquivalent: "")
        copyLink.target = self
        menu.addItem(copyLink)
        if onOpenLink != nil {
            let open = NSMenuItem(title: "Open link", action: #selector(openLink), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }
        return menu
    }

    func copy(to pasteboard: NSPasteboard) async throws {
        guard let fetch else { throw ModelError("This media is unavailable. Try reopening the preview.") }
        let mimeType = mimeType
        let data = try await fetch()
        let worker = Task.detached(priority: .userInitiated) { try Self.png(data, mimeType: mimeType) }
        let png = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    @objc func copyLink() {
        guard let link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        announce("Link copied")
    }

    @objc func openLink() {
        guard let link else { return }
        onOpenLink?(link)
    }

    @objc func copyImage() {
        task?.cancel()
        announce("Copying image…")
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.copy(to: .general); self.announce("Image copied") }
            catch is CancellationError {}
            catch { self.announce("Could not copy image: " + error.localizedDescription, error: true) }
        }
    }

    @objc func saveImage() {
        guard let fetch else { return }
        let name = name
        task?.cancel()
        announce("Preparing image download…")
        task = Task { [weak self] in
            do {
                let data = try await fetch()
                try Task.checkCancellation()
                guard let self else { return }
                AgentFilePreviewWindow.save(data, name: name, window: self.view?.window) { [weak self] error in
                    self?.announce("Could not save image: " + error.localizedDescription, error: true)
                }
            } catch is CancellationError {}
            catch { self?.announce("Could not save image: " + error.localizedDescription, error: true) }
        }
    }

    private func announce(_ text: String, error: Bool = false) {
        guard let root = view?.window?.contentView else { return }
        Toast.show(text, style: error ? .error : .info, in: root)
    }

    nonisolated static func png(_ data: Data, mimeType: String) throws -> Data {
        try Task.checkCancellation()
        // source preserves PNG bytes, including metadata and animation, verbatim.
        if mimeType.split(separator: ";", maxSplits: 1).first == "image/png" { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw ModelError("This image could not be decoded for copying. Try saving it instead.")
        }
        guard width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 64_000_000 else {
            throw ModelError("This image is too large or has no usable dimensions. Try saving it instead.")
        }
        // ImageIO applies EXIF orientation just as the browser's decoded image does.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ModelError("This image could not be decoded for copying. Try saving it instead.")
        }
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ModelError("The image could not be converted to PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ModelError("The image could not be converted to PNG.") }
        return output as Data
    }
}

@MainActor
class AgentActionImageView: NSImageView {
    var imageActions: AgentImageActions?
    override func menu(for event: NSEvent) -> NSMenu? { imageActions?.menu() }
}
