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
    /// Rounds and edges the images as one frame, like every other image surface.
    private let frameView = NSView()
    var hasImages: Bool { !tiles.isEmpty }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(frameView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ item: AgentChatItem, theme: AppTheme) {
        let descriptors = (item.attachments ?? []).filter { $0.mimeType.hasPrefix("image/") }
        if self.item != item.id || self.descriptors != descriptors {
            tiles.forEach { $0.removeFromSuperview() }
            self.item = item.id; self.descriptors = descriptors
            tiles = descriptors.enumerated().map { index, descriptor in
                let tile = AgentMediaTile(name: "Tool output image")
                tile.isToolResult = true
                tile.transparentBackground = descriptors.count == 1
                tile.onPress = { [weak self, weak tile] in
                    guard let self, let tile else { return }
                    if tile.image != nil { self.onPreview?(self.item, self.descriptors, index) }

                }
                frameView.addSubview(tile); load(tile, descriptor: descriptor)
                return tile
            }
        }
        AgentMediaStyle.applyFrame(to: frameView, theme: theme)
        tiles.forEach { $0.apply(theme) }
        needsLayout = true
    }
    /// Loads again the images that failed, as when the server is back.
    func retryFailed() {
        for (tile, descriptor) in zip(tiles, descriptors) where tile.hasFailed { load(tile, descriptor: descriptor) }
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
    private static let maximumWidth: CGFloat = 480
    private static let maximumHeight: CGFloat = 256

    static func imageSize(_ original: NSSize?, width: CGFloat) -> NSSize {
        guard let original, original.width > 0, original.height > 0 else {
            let width = min(maximumWidth, max(1, width))
            return NSSize(width: width, height: min(maximumHeight, width * 9 / 16))
        }
        return AgentMediaStyle.fittedSize(original, maxWidth: min(max(1, width), maximumWidth), maxHeight: maximumHeight)
    }
    /// One image at its own shape, several as a mosaic, and ones that couldn't load as
    /// short cards; returns the height.
    @discardableResult
    func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        guard !tiles.isEmpty else { if apply { frameView.frame = .zero }; return 0 }
        let size: NSSize, frames: [NSRect]
        if tiles.allSatisfy(\.isCompact) {
            size = AgentMediaStyle.compactSize(count: tiles.count, width: width)
            frames = AgentMediaStyle.compactFrames(count: tiles.count, width: size.width)
        } else if tiles.count == 1 {
            size = Self.imageSize(tiles[0].image?.size, width: width)
            frames = [NSRect(origin: .zero, size: size)]
        } else {
            let collage = min(max(1, width), Self.maximumWidth)
            size = NSSize(width: collage, height: AgentMediaCollage.compact.height(count: tiles.count))
            frames = AgentMediaCollage.compact.frames(count: tiles.count, width: collage)
        }
        if apply {
            frameView.frame = NSRect(origin: .zero, size: size)
            for (tile, frame) in zip(tiles, frames) { tile.frame = frame }
        }
        return size.height
    }
    override func layout() { super.layout(); arrange(width: bounds.width, apply: true) }
}
