import AppKit
import TabProtocol

@MainActor
final class AgentToolImagesView: NSView {
    override var isFlipped: Bool { true }
    var fetch: AgentAttachmentCache.Fetch?
    var onHeightChanged: (() -> Void)?
    var onPreview: ((String, [AgentChatAttachmentDescriptor], Int) -> Void)?
    private var item = ""
    private var descriptors: [AgentChatAttachmentDescriptor] = []
    private var tiles: [AgentMediaTile] = []
    private var hasHadWindow = false
    var hasImages: Bool { !tiles.isEmpty }

    func update(_ item: AgentChatItem, theme: AppTheme) {
        let descriptors = (item.attachments ?? []).filter { $0.mimeType.hasPrefix("image/") }
        if self.item != item.id || self.descriptors != descriptors {
            tiles.forEach { $0.removeFromSuperview() }
            self.item = item.id; self.descriptors = descriptors
            tiles = descriptors.enumerated().map { index, descriptor in
                let tile = AgentMediaTile(name: "Tool output image")
                tile.isToolResult = true
                tile.wantsLayer = true; tile.transparentBackground = true
                tile.layer?.cornerRadius = 8; tile.layer?.borderWidth = 1; tile.layer?.masksToBounds = true
                tile.onPress = { [weak self, weak tile] in
                    guard let self, let tile else { return }
                    if tile.image != nil { self.onPreview?(self.item, self.descriptors, index) }

                }
                addSubview(tile); load(tile, descriptor: descriptor)
                return tile
            }
        }
        tiles.forEach { $0.apply(theme); $0.layer?.borderColor = theme.border.withAlphaComponent(theme.border.alphaComponent * 0.4).cgColor }
        needsLayout = true
    }
    private func load(_ tile: AgentMediaTile, descriptor: AgentChatAttachmentDescriptor) {
        guard let fetch else { tile.fail("Preview unavailable"); return }
        let item = item
        tile.imageActions.name = descriptor.name
        tile.imageActions.mimeType = descriptor.mimeType
        tile.imageActions.fetch = { try await fetch(item, descriptor) }
        tile.load {
            let data = try await fetch(item, descriptor)
            guard let image = await AgentAttachmentImporter.previewImage(data: data, pixels: 600) else {
                throw ModelError("This image could not be decoded.")
            }
            return image
        } changed: { [weak self] in self?.onHeightChanged?() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, hasHadWindow { tiles.forEach { $0.suspend() } }
        else if window != nil {
            if hasHadWindow { for (tile, descriptor) in zip(tiles, descriptors) where tile.image == nil { load(tile, descriptor: descriptor) } }
            hasHadWindow = true
        }
    }
    static func imageSize(_ original: NSSize?, width: CGFloat) -> NSSize {
        guard let original, original.width > 0, original.height > 0 else {
            let width = min(480, max(1, width))
            return NSSize(width: width, height: min(256, width * 9 / 16))
        }
        let scale = min(1, min(max(1, width), 480) / original.width, 256 / original.height)
        return NSSize(width: original.width * scale, height: original.height * scale)
    }
    @discardableResult
    func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var y: CGFloat = 0
        for (index, tile) in tiles.enumerated() {
            if index > 0 { y += 6 }
            let size = Self.imageSize(tile.image?.size, width: width)
            if apply { tile.frame = NSRect(origin: NSPoint(x: 0, y: y), size: size) }
            y += size.height
        }
        return y
    }
    override func layout() { super.layout(); arrange(width: bounds.width, apply: true) }
}
