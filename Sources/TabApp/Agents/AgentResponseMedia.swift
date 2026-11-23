import AppKit

/// An image-only paragraph of an assistant message: one bounded tile, or a collage of
/// several. Media load through the conversation's `AgentMediaLoader` only while the
/// section is in a window; a click opens the message's images as a gallery, and video
/// or audio in the isolated media window.
@MainActor
final class AgentResponseMedia: AgentResponseSection {
    override var kind: Int { 10 }
    /// A single image is never taller than this, nor upscaled past its pixel size.
    static let maximumHeight: CGFloat = 480
    static let collageWidth: CGFloat = 560
    static let placeholderSize = NSSize(width: 320, height: 200)
    static let playerHeight: CGFloat = 56

    weak var services: AgentConversationLinkServices? {
        didSet { if oldValue !== services { resubscribe() } }
    }
    /// A tile was activated; the response view turns it into a gallery or a player.
    var onOpenMedia: ((AgentMarkdownMedia) -> Void)?
    private(set) var items: [AgentMarkdownMedia] = []
    private(set) var tiles: [NSControl] = []
    /// Original pixel sizes of loaded images, kept while tiles are suspended so the
    /// section keeps its height when it leaves and re-enters a window.
    private var pixelSizes: [Int: CGSize] = [:]
    private var observations: [AgentLazyRequestObservation] = []
    private let frameView = NSView()
    private var theme: AppTheme?
    private var frameSize = NSSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        frameView.wantsLayer = true
        addSubview(frameView)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        guard case .media(let next) = part else { return }
        self.theme = theme
        if next != items {
            items = next
            rebuild()
        }
        // Images share a hairline frame; a video or audio card is a card of its own.
        AgentMediaStyle.applyFrame(to: frameView, theme: theme)
        if !items.contains(where: { $0.kind == .image }) { frameView.layer?.borderWidth = 0 }
        for tile in tiles {
            (tile as? AgentMediaTile)?.apply(theme)
            (tile as? AgentMediaPlayTile)?.apply(theme)
        }
    }

    private func rebuild() {
        observations.forEach { $0.cancel() }
        observations.removeAll()
        tiles.forEach { $0.removeFromSuperview() }
        tiles.removeAll()
        pixelSizes.removeAll()
        for media in items {
            let tile: NSControl
            if media.kind == .image {
                let image = AgentMediaTile(name: media.name)
                image.isToolResult = true
                image.keepsNameToolTip = true
                image.imageActions.name = media.fileName
                image.imageActions.mimeType = media.mimeType
                image.imageActions.link = media.link
                image.onPress = { [weak self] in self?.onOpenMedia?(media) }
                tile = image
            } else {
                let player = AgentMediaPlayTile(media: media)
                player.onPress = { [weak self] in self?.onOpenMedia?(media) }
                tile = player
            }
            frameView.addSubview(tile)
            tiles.append(tile)
        }
        configureActions()
        resubscribe()
    }

    private func configureActions() {
        let loader = services?.mediaLoader
        let openLink = services?.openLink
        for (index, tile) in tiles.enumerated() {
            let media = items[index]
            let actions = (tile as? AgentMediaTile)?.imageActions ?? (tile as? AgentMediaPlayTile)?.actions
            actions?.onOpenLink = openLink
            guard let tile = tile as? AgentMediaTile else { continue }
            tile.imageActions.fetch = loader.map { loader in { try await loader.entry(for: media).data } }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resubscribe()
    }

    /// Observes every image while the section is in a window; out of a window the tiles
    /// drop their pixels and pending requests are released.
    private func resubscribe() {
        observations.forEach { $0.cancel() }
        observations.removeAll()
        configureActions()
        guard window != nil, let loader = services?.mediaLoader else {
            for tile in tiles { (tile as? AgentMediaTile)?.suspend() }
            return
        }
        for (index, media) in items.enumerated() where media.kind == .image {
            guard let tile = tiles[index] as? AgentMediaTile else { continue }
            observations.append(loader.observe(media) { [weak self, weak tile] state in
                guard let self, let tile else { return }
                self.render(state, tile: tile, index: index)
            })
        }
    }

    private func render(_ state: AgentMediaLoader.State, tile: AgentMediaTile, index: Int) {
        switch state {
        case .loading: tile.unblock(); return
        case .blocked(let host, let clickable):
            let media = items[index]
            if clickable {
                tile.block("Image from \(host) · Click to load") { [weak self] in self?.services?.mediaLoader?.approve(media.source) }
                placeholderChanged()
            } else {
                let openLink = services?.openLink
                tile.block("Image from \(host) not loaded · Click to open the link") {
                    if let url = AgentMediaSource(media.source).flatMap({ if case .remote(let url) = $0 { return url } else { return nil } }) {
                        openLink?(url.absoluteString)
                    }
                }
                placeholderChanged()
            }
        case .failed(let message): tile.fail(message); placeholderChanged()
        case .loaded(let entry):
            guard let image = entry.image else { tile.fail("Image unavailable"); placeholderChanged(); return }
            if tile.image !== image { tile.show(image) }
            let size = entry.pixelSize ?? image.size
            guard pixelSizes[index] != size else { return }
            pixelSizes[index] = size
            guard items.count == 1 else { return }
            invalidateMeasurement()
            onHeightChanged?()
        }
    }

    /// A lone image that failed or waits for a click shrinks to a short card, and grows
    /// back when it loads.
    private func placeholderChanged() {
        guard items.count == 1 else { return }
        invalidateMeasurement()
        onHeightChanged?()
    }

    /// The bounded size of a single image of `pixelSize` in a column `width` wide.
    static func fittedSize(_ pixelSize: CGSize?, width: CGFloat) -> NSSize {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return NSSize(width: min(width, placeholderSize.width), height: placeholderSize.height)
        }
        return AgentMediaStyle.fittedSize(pixelSize, maxWidth: width, maxHeight: maximumHeight)
    }

    /// The single tile or collage size for `items` in a column `width` wide.
    func contentSize(for width: CGFloat) -> NSSize {
        let width = max(1, width)
        guard !items.isEmpty else { return .zero }
        if items.count == 1 {
            if items[0].kind != .image { return NSSize(width: min(width, Self.placeholderSize.width + 40), height: Self.playerHeight) }
            if (tiles.first as? AgentMediaTile)?.isCompact == true { return AgentMediaStyle.compactSize(count: 1, width: width) }
            let cached = pixelSizes[0] ?? services?.mediaLoader?.state(for: items[0].source)?.entry.flatMap { $0.pixelSize }
            return Self.fittedSize(cached, width: width)
        }
        return NSSize(width: min(width, Self.collageWidth), height: AgentMediaCollage.response.height(count: items.count))
    }

    override func height(for width: CGFloat) -> CGFloat {
        frameSize = contentSize(for: width)
        return frameSize.height
    }

    override func layoutSection(width: CGFloat) {
        frameView.frame = NSRect(origin: .zero, size: frameSize)
        let frames = tiles.count == 1 ? [frameView.bounds] : AgentMediaCollage.response.frames(count: tiles.count, width: frameSize.width)
        for (tile, frame) in zip(tiles, frames) { tile.frame = frame }
    }
}

/// A video or audio reference: a card that opens the isolated media window.
@MainActor
final class AgentMediaPlayTile: NSControl {
    let media: AgentMarkdownMedia
    let actions: AgentImageActions
    var onPress: (() -> Void)?
    private let icon = NSImageView()
    private let title = makeLabel("", font: AppFont.system(14, weight: .medium))
    private let detail = makeLabel("", font: AppFont.system(12))
    private var background = NSColor.windowBackgroundColor
    private var iconFill = NSColor.clear
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(media: AgentMarkdownMedia) {
        self.media = media
        actions = AgentImageActions(name: media.fileName)
        actions.includesImageItems = false
        actions.link = media.link
        super.init(frame: .zero)
        actions.view = self
        title.stringValue = media.name
        title.lineBreakMode = .byTruncatingMiddle
        detail.stringValue = media.kind == .video ? "Video" : "Audio"
        for child in [icon, title, detail] as [NSView] { addSubview(child) }
        setAccessibilityRole(.button)
        setAccessibilityLabel("Play " + media.name)
        toolTip = media.name
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ theme: AppTheme) {
        background = AgentMediaStyle.fill(theme)
        iconFill = AgentMediaStyle.iconFill(theme)
        title.textColor = theme.fg
        detail.textColor = theme.fgMuted
        icon.image = AppIcon.play.image(size: 16, scale: AppIcon.inlineScale, color: theme.fgMuted)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8 + (AgentMediaStyle.iconBox - 16) / 2, y: bounds.midY - 8, width: 16, height: 16)
        let x: CGFloat = 8 + AgentMediaStyle.iconBox + 12, width = max(0, bounds.width - x - 12)
        if bounds.height < 48 {
            title.frame = NSRect(x: x, y: bounds.midY - 10, width: width, height: 20)
            detail.isHidden = true
        } else {
            detail.isHidden = false
            title.frame = NSRect(x: x, y: bounds.midY - 19, width: width, height: 20)
            detail.frame = NSRect(x: x, y: bounds.midY + 2, width: width, height: 16)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        iconFill.setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: bounds.midY - AgentMediaStyle.iconBox / 2, width: AgentMediaStyle.iconBox,
                                         height: AgentMediaStyle.iconBox), xRadius: 8, yRadius: 8).fill()
        guard window?.firstResponder === self else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        outline.lineWidth = 3
        outline.stroke()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onPress?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onPress?() } else { super.keyDown(with: event) }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func menu(for event: NSEvent) -> NSMenu? { actions.menu() }
}

/// A Markdown image inside a sentence: a small thumbnail of at most 1.5 line heights,
/// drawn by its attachment cell so loading never changes the text layout.
@MainActor
final class AgentInlineMediaCell: NSTextAttachmentCell {
    let media: AgentMarkdownMedia
    let size: NSSize
    var thumbnail: NSImage?
    var failed = false
    var placeholder = NSColor.quaternaryLabelColor
    var border = NSColor.separatorColor
    var muted = NSColor.secondaryLabelColor

    init(media: AgentMarkdownMedia, fontSize: CGFloat) {
        self.media = media
        let height = (fontSize * 1.5).rounded()
        size = NSSize(width: (height * 4 / 3).rounded(), height: height)
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override func cellSize() -> NSSize { MainActor.assumeIsolated { size } }
    nonisolated override func cellBaselineOffset() -> NSPoint {
        MainActor.assumeIsolated { NSPoint(x: 0, y: -(size.height * 0.28).rounded()) }
    }

    nonisolated override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        MainActor.assumeIsolated { drawThumbnail(in: cellFrame.insetBy(dx: 1, dy: 0)) }
    }

    private func drawThumbnail(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        path.addClip()
        placeholder.setFill()
        rect.fill()
        if let image = thumbnail, image.size.width > 0, image.size.height > 0 {
            let scale = max(rect.width / image.size.width, rect.height / image.size.height)
            let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if failed {
            let side = min(12, rect.height - 4)
            AppIcon.triangleAlert.image(size: side, scale: AppIcon.inlineScale, color: muted)?.draw(
                in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Swaps inline Markdown images for thumbnail attachments.
@MainActor
enum AgentInlineMedia {
    static let linkURL = URL(string: "tab-agent-media:inline")

    /// Replaces each run marked `agentInlineMediaSource` in `content` with one attachment
    /// character showing a thumbnail; `cells` reuses attachments across renders so
    /// unchanged prose stays equal. Returns the cells in reading order.
    @discardableResult
    static func substitute(_ content: NSMutableAttributedString, theme: AppTheme,
                           cells: inout [String: NSTextAttachment]) -> [AgentInlineMediaCell] {
        var runs: [(NSRange, String)] = []
        content.enumerateAttribute(.agentInlineMediaSource, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            if let source = value as? String { runs.append((range, source)) }
        }
        guard !runs.isEmpty else { return [] }
        let colors = AgentMarkdownPalette(theme: theme)
        var result: [AgentInlineMediaCell] = []
        var used: [String: NSTextAttachment] = [:]
        for (range, source) in runs.reversed() {
            guard AgentMediaSource(source) != nil else {
                content.removeAttribute(.agentInlineMediaSource, range: range)
                continue
            }
            var alt = (content.string as NSString).substring(with: range)
            if alt == "\u{FFFC}" { alt = "" }
            var attributes = content.attributes(at: range.location, effectiveRange: nil)
            let font = attributes[.font] as? NSFont ?? AppFont.system(14)
            let extensionKind = AgentMarkdownMedia.kind(extension: ((AgentMediaSource(source)?.path ?? "") as NSString).pathExtension)
            let media = AgentMarkdownMedia(source: source, alt: alt, kind: extensionKind ?? .image)
            let key = "\(font.pointSize)|\(alt.utf8.count):\(alt)|\(source)"
            let attachment = used[key] ?? cells[key] ?? {
                let attachment = NSTextAttachment()
                attachment.attachmentCell = AgentInlineMediaCell(media: media, fontSize: font.pointSize)
                return attachment
            }()
            used[key] = attachment
            guard let cell = attachment.attachmentCell as? AgentInlineMediaCell else { continue }
            cell.placeholder = AgentMediaStyle.fill(theme)
            cell.border = AgentMediaStyle.hairline(theme)
            cell.muted = colors.muted
            attributes[.agentInlineMediaSource] = nil
            attributes[.attachment] = attachment
            attributes[.agentInlineMedia] = media
            attributes[.toolTip] = media.name
            attributes[.link] = linkURL
            content.replaceCharacters(in: range, with: NSAttributedString(string: "\u{FFFC}", attributes: attributes))
            result.append(cell)
        }
        cells = used
        return result.reversed()
    }
}
