import AppKit
import TabClient
import TabProtocol

@MainActor
final class AgentAttachmentCache {
    typealias Fetch = (String, AgentChatAttachmentDescriptor) async throws -> Data
    var fetch: Fetch?
    private let cache = NSCache<NSString, NSData>()
    /// What this app sent, by descriptor: the app's own attachment IDs are UUIDs, so the
    /// message that carries them shows them without a round trip to the server.
    private let sent = NSCache<NSString, NSData>()
    private var pending: [String: Task<Data, Error>] = [:]
    /// Waits between attempts; a server can publish a message a moment before its files are readable.
    var retryDelays: [Duration] = [.milliseconds(400), .milliseconds(1200)]
    init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        sent.totalCostLimit = 32 * 1024 * 1024
    }

    func seed(_ attachments: [AgentChatAttachment]) {
        for attachment in attachments {
            sent.setObject(attachment.data as NSData, forKey: Self.sentKey(attachment.descriptor) as NSString, cost: attachment.data.count)
        }
    }

    func data(item: String, attachment: AgentChatAttachmentDescriptor) async throws -> Data {
        // Provider IDs may themselves contain slashes. Length-prefix both
        // identities so cached bytes cannot cross message ownership boundaries.
        let key = "\(item.utf8.count):\(item)\(attachment.id.utf8.count):\(attachment.id):\(attachment.byteCount)"
        if let cached = cache.object(forKey: key as NSString) { return cached as Data }
        if let seeded = sent.object(forKey: Self.sentKey(attachment) as NSString), seeded.length == attachment.byteCount {
            return seeded as Data
        }
        if let task = pending[key] { return try await task.value }
        guard let fetch else { throw ModelError("Attachment previews are unavailable on this server.") }
        let delays = retryDelays
        let task = Task {
            var attempt = 0
            while true {
                do {
                    let data = try await fetch(item, attachment)
                    try Task.checkCancellation()
                    guard data.count == attachment.byteCount, data.count <= AgentChatAttachment.maxPayloadBytes else {
                        throw ModelError("The attachment payload does not match this message.")
                    }
                    return data
                } catch {
                    guard attempt < delays.count, Self.isTransient(error) else { throw error }
                    try await Task.sleep(for: delays[attempt])
                    attempt += 1
                }
            }
        }
        pending[key] = task
        defer { pending[key] = nil }
        let data = try await task.value
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }
    func cancel() { pending.values.forEach { $0.cancel() }; pending.removeAll(); cache.removeAllObjects(); sent.removeAllObjects() }

    private static func sentKey(_ attachment: AgentChatAttachmentDescriptor) -> String {
        "\(attachment.id.utf8.count):\(attachment.id)\(attachment.name.utf8.count):\(attachment.name):\(attachment.mimeType):\(attachment.byteCount)"
    }

    /// Whether another attempt may succeed: not a cancellation, nor a server that can't
    /// serve previews, nor bytes that don't match.
    private static func isTransient(_ error: Error) -> Bool {
        switch error {
        case is CancellationError, is ModelError: return false
        case ClientError.unsupported, ClientError.versionUnsupported, ClientError.invalid, ClientError.unexpectedReply: return false
        case ClientError.server(let reply): return reply.code != .unsupported
        default: return true
        }
    }
}

/// A user message's images: one keeps its own shape, several form a mosaic. Each opens
/// the message's images in the viewer.
@MainActor
final class AgentMessageMediaView: NSView {
    var fetch: AgentAttachmentCache.Fetch?
    var joinsTextBubble = false { didSet { if oldValue != joinsTextBubble { needsLayout = true } } }
    var onHeightChanged: (() -> Void)?
    var onPreview: ((String, [AgentChatAttachmentDescriptor], Int) -> Void)?
    private var item = ""
    private var descriptors: [AgentChatAttachmentDescriptor] = []
    private var tiles: [AgentMediaTile] = []
    private var hasHadWindow = false
    override var isFlipped: Bool { true }
    var images: [NSImage?] { tiles.map(\.image) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(item: String, attachments: [AgentChatAttachmentDescriptor], theme: AppTheme) {
        isHidden = attachments.isEmpty
        if self.item != item || descriptors != attachments {
            tiles.forEach { $0.removeFromSuperview() }
            tiles = []; self.item = item; descriptors = attachments
            for (index, attachment) in attachments.enumerated() {
                let tile = AgentMediaTile(name: attachment.name)
                tile.isAttachment = true
                tile.onPress = { [weak self, weak tile] in
                    guard let self, let tile else { return }
                    if tile.image != nil { self.onPreview?(item, attachments, index) }
                    else if tile.hasFailed { self.load(tile, attachment: attachment) }
                }
                addSubview(tile); tiles.append(tile)
                load(tile, attachment: attachment)
            }
        }
        AgentMediaStyle.applyFrame(to: self, theme: theme)
        for tile in tiles { tile.apply(theme) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, hasHadWindow { tiles.forEach { $0.suspend() } }
        else if window != nil {
            if hasHadWindow {
                for (index, tile) in tiles.enumerated() where tile.image == nil { load(tile, attachment: descriptors[index]) }
            }
            hasHadWindow = true
        }
    }

    /// Loads again the previews that failed, as when the server is back.
    func retryFailed() {
        for (tile, attachment) in zip(tiles, descriptors) where tile.hasFailed { load(tile, attachment: attachment) }
    }

    private func load(_ tile: AgentMediaTile, attachment: AgentChatAttachmentDescriptor) {
        guard let fetch else { tile.fail("Previews are unavailable here"); return }
        let item = item
        tile.imageActions.name = attachment.name
        tile.imageActions.mimeType = attachment.mimeType
        tile.imageActions.fetch = { try await fetch(item, attachment) }
        tile.load {
            let data = try await fetch(item, attachment)
            guard let image = await AgentAttachmentImporter.previewImage(data: data, pixels: 1200) else {
                throw ModelError("This image could not be decoded.")
            }
            return image
        } changed: { [weak self] in self?.onHeightChanged?() }
    }

    private static let maximumWidth: CGFloat = 360
    private static let singleMaximumHeight: CGFloat = 280
    /// One image before its size is known.
    private static let placeholderSize = NSSize(width: 240, height: 160)

    /// One image keeps its own shape, never upscaled; several form a mosaic. Previews
    /// that couldn't load become short cards.
    func measuredSize(maxWidth: CGFloat) -> NSSize {
        guard !tiles.isEmpty else { return .zero }
        let width = min(Self.maximumWidth, max(0, maxWidth))
        if tiles.allSatisfy(\.isCompact) { return AgentMediaStyle.compactSize(count: tiles.count, width: width) }
        if tiles.count == 1 {
            guard let image = tiles[0].image else { return NSSize(width: min(width, Self.placeholderSize.width), height: Self.placeholderSize.height) }
            let size = AgentMediaStyle.fittedSize(image.size, maxWidth: width, maxHeight: Self.singleMaximumHeight)
            return NSSize(width: max(64, size.width), height: max(48, size.height))
        }
        return NSSize(width: width, height: AgentMediaCollage.compact.height(count: tiles.count))
    }

    override func layout() {
        super.layout()
        let frames = tiles.allSatisfy(\.isCompact) ? AgentMediaStyle.compactFrames(count: tiles.count, width: bounds.width)
            : tiles.count == 1 ? [bounds] : AgentMediaCollage.compact.frames(count: tiles.count, width: bounds.width)
        for (tile, frame) in zip(tiles, frames) { tile.frame = frame }
    }
}

/// One image slot of any attachment surface. Until its image arrives it draws the
/// shared placeholder: an image glyph while loading, then the name and why it's missing.
@MainActor
final class AgentMediaTile: NSControl {
    let imageActions: AgentImageActions
    private(set) var image: NSImage?
    private let name: String
    private var task: Task<Void, Never>?
    private var generation = 0
    private let animatedImage = AgentAnimatedImageView()
    /// A tool's or the assistant's image: a failed one isn't pressable.
    var isToolResult = false { didSet { updateAccessibility() } }
    /// A message's own attachment: pressing a failed one loads it again.
    var isAttachment = false { didSet { updateAccessibility() } }
    /// It failed or waits for a click, and keeps the short card while it retries.
    private(set) var isCompact = false
    var hasFailed: Bool { image == nil && failureMessage != nil }
    /// Assistant Markdown media keep their alt text as tooltip while loading or failed.
    var keepsNameToolTip = false { didSet { updateAccessibility() } }
    private var failureMessage: String?
    private var blockedMessage: String?
    /// What a click does while the remote-image setting holds the image back.
    var blockedAction: (() -> Void)?
    private var placeholderColor = NSColor.secondaryLabelColor
    private var placeholderDetailColor = NSColor.tertiaryLabelColor
    /// Shows the whole image inside the tile instead of filling it.
    var fitsWholeImage = false
    var transparentBackground = false
    private var background = NSColor.windowBackgroundColor
    var onPress: (() -> Void)?
    override var isFlipped: Bool { true }
    // The source renderer's MediaActions wrapper remains focusable while loading or failed;
    // Shift-F10 must still reach Save/Copy when preview activation is unavailable.
    override var acceptsFirstResponder: Bool { true }

    init(name: String) {
        self.name = name
        imageActions = AgentImageActions(name: name)
        super.init(frame: .zero)
        imageActions.view = self
        wantsLayer = true
        layer?.masksToBounds = true
        animatedImage.imageScaling = .scaleAxesIndependently
        animatedImage.setAccessibilityElement(false)
        addSubview(animatedImage)
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { task?.cancel() }
    func suspend() {
        generation += 1; task?.cancel(); task = nil; image = nil
        isCompact = false
        animatedImage.animates = false
        animatedImage.image = nil
        failureMessage = nil
        updateAccessibility()
    }
    func apply(_ theme: AppTheme) {
        background = AgentMediaStyle.fill(theme)
        placeholderColor = theme.fgMuted
        placeholderDetailColor = theme.fgDim
        needsDisplay = true
    }
    /// Shows `message` in place of an image the remote-image setting held back; a click runs `action`.
    func block(_ message: String, action: @escaping () -> Void) {
        blockedAction = action
        blockedMessage = message
        failureMessage = nil
        image = nil
        isCompact = true
        updateAccessibility()
    }

    /// The held-back image is loading after all.
    func unblock() {
        guard blockedAction != nil else { return }
        blockedAction = nil
        blockedMessage = nil
        updateAccessibility()
    }

    func fail(_ message: String) {
        blockedAction = nil
        blockedMessage = nil
        failureMessage = message
        isCompact = true
        updateAccessibility()
    }

    private func updateAccessibility() {
        defer { needsDisplay = true }
        if image != nil {
            setAccessibilityRole(.button)
            setAccessibilityLabel("Preview " + name)
            toolTip = name
        } else if let blockedMessage, blockedAction != nil {
            setAccessibilityRole(.button)
            setAccessibilityLabel(blockedMessage)
            toolTip = blockedMessage
        } else if let failureMessage {
            setAccessibilityRole(isAttachment ? .button : .group)
            setAccessibilityLabel("Image unavailable · " + name + (isAttachment ? " · Click to retry" : ""))
            toolTip = isAttachment ? name + " — " + failureMessage : keepsNameToolTip ? name : nil
        } else {
            setAccessibilityRole(isAttachment ? .button : .group)
            setAccessibilityLabel(isAttachment ? "Loading " + name : "Loading image")
            toolTip = isAttachment || keepsNameToolTip ? name : nil
        }
    }

    func load(_ fetch: @escaping () async throws -> NSImage, changed: @escaping () -> Void) {
        generation += 1
        let token = generation
        task?.cancel()
        failureMessage = nil
        updateAccessibility()
        task = Task { [weak self] in
            do {
                let image = try await fetch()
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.show(image)
                changed()
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.fail(error.localizedDescription)
                changed()
            }
        }
    }
    /// Shows an already decoded image now, ending any pending load; GIFs play.
    func show(_ image: NSImage) {
        blockedAction = nil
        blockedMessage = nil
        generation += 1
        task?.cancel(); task = nil
        failureMessage = nil
        isCompact = false
        self.image = image
        let animated = image.representations.contains {
            (($0 as? NSBitmapImageRep)?.value(forProperty: .frameCount) as? NSNumber)?.intValue ?? 0 > 1
        }
        animatedImage.image = animated ? image : nil
        animatedImage.animates = animated && window != nil
        needsLayout = true
        updateAccessibility()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animatedImage.animates = window != nil && animatedImage.image != nil
    }
    override func layout() {
        super.layout()
        if let image, image.size.width > 0, image.size.height > 0 {
            animatedImage.frame = imageRect(image)
        }
    }
    private func imageRect(_ image: NSImage) -> NSRect {
        let scale = fitsWholeImage ? min(bounds.width / image.size.width, bounds.height / image.size.height)
            : max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        if image == nil || !transparentBackground { background.setFill(); bounds.fill() }
        if let image, animatedImage.image == nil, image.size.width > 0, image.size.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            bounds.clip()
            image.draw(in: imageRect(image), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        if image == nil { drawPlaceholder() }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2)); outline.lineWidth = 3; outline.stroke()
        }
    }

    /// Loading draws only an image glyph. A missing image adds its name and status: beside
    /// the glyph in a short card, under it in a larger slot.
    private func drawPlaceholder() {
        let icon: AppIcon, title: String?, status: [String]
        if let blockedMessage, blockedAction != nil {
            let parts = blockedMessage.components(separatedBy: " · ")
            icon = .image; title = parts.first; status = [parts.dropFirst().joined(separator: " · ")]
        } else if failureMessage != nil {
            icon = .triangleAlert; title = name
            status = isAttachment ? ["Image unavailable · Click to retry", "Click to retry"] : ["Image unavailable"]
        } else if isCompact {
            icon = .image; title = name; status = ["Loading…"]
        } else {
            icon = .image; title = nil; status = []
        }
        let iconSize: CGFloat = 16
        let tint = title == nil ? placeholderDetailColor : placeholderColor
        let glyph = icon.image(size: iconSize, scale: AppIcon.inlineScale, color: tint)
        guard let title else {
            glyph?.draw(in: NSRect(x: bounds.midX - iconSize / 2, y: bounds.midY - iconSize / 2, width: iconSize, height: iconSize),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        let stacked = bounds.height >= 88
        let titleStyle = NSMutableParagraphStyle(), statusStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingMiddle
        statusStyle.lineBreakMode = .byTruncatingTail
        if stacked { titleStyle.alignment = .center; statusStyle.alignment = .center }
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: AppFont.system(12, weight: .medium), .foregroundColor: placeholderColor, .paragraphStyle: titleStyle]
        let statusAttributes: [NSAttributedString.Key: Any] = [.font: AppFont.system(11), .foregroundColor: placeholderDetailColor, .paragraphStyle: statusStyle]
        let textX: CGFloat = stacked ? 12 : 12 + iconSize + 10
        let textWidth = max(1, bounds.width - textX - 12)
        // The longest status that fits, so a narrow tile still says what a click does.
        let line = status.first { ($0 as NSString).size(withAttributes: statusAttributes).width <= textWidth } ?? status.last ?? ""
        if stacked {
            let top = bounds.midY - (iconSize + 8 + 32) / 2
            glyph?.draw(in: NSRect(x: bounds.midX - iconSize / 2, y: top, width: iconSize, height: iconSize),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            (title as NSString).draw(in: NSRect(x: textX, y: top + iconSize + 8, width: textWidth, height: 16), withAttributes: titleAttributes)
            (line as NSString).draw(in: NSRect(x: textX, y: top + iconSize + 25, width: textWidth, height: 15), withAttributes: statusAttributes)
        } else {
            let top = bounds.midY - 16
            glyph?.draw(in: NSRect(x: 12, y: bounds.midY - iconSize / 2, width: iconSize, height: iconSize),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            (title as NSString).draw(in: NSRect(x: textX, y: top, width: textWidth, height: 16), withAttributes: titleAttributes)
            (line as NSString).draw(in: NSRect(x: textX, y: top + 17, width: textWidth, height: 15), withAttributes: statusAttributes)
        }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; animatedImage.needsDisplay = true; return acceptsFirstResponder }
    override func resignFirstResponder() -> Bool { needsDisplay = true; animatedImage.needsDisplay = true; return true }
    override func mouseDown(with event: NSEvent) {
        if let blockedAction { blockedAction(); return }
        guard !isToolResult || image != nil else { return }; window?.makeFirstResponder(self); onPress?()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109, event.modifierFlags.contains(.shift) {
            imageActions.menu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
            return
        }
        if let blockedAction, event.keyCode == 36 || event.keyCode == 49 { blockedAction(); return }
        guard !isToolResult || image != nil else { return }
        if event.keyCode == 36 || event.keyCode == 49 { onPress?() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        if let blockedAction { blockedAction(); return true }
        guard !isToolResult || image != nil else { return false }; onPress?(); return true
    }
    override func menu(for event: NSEvent) -> NSMenu? { imageActions.menu() }
}

@MainActor
private final class AgentAnimatedImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let parent = superview, window?.firstResponder === parent else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let outline = NSBezierPath(rect: convert(parent.bounds.insetBy(dx: 2, dy: 2), from: parent))
        outline.lineWidth = 3
        outline.stroke()
    }
}

@MainActor
enum AgentMessageShape {
    /// A user message's corner radius, the same as a sidebar card's.
    nonisolated static let radius = Metrics.radiusLarge
    /// The tighter corner where a message's images meet its text bubble.
    nonisolated static let joinedRadius: CGFloat = 3

    static func apply(to view: NSView, topRight: CGFloat = radius, bottomRight: CGFloat = radius) {
        view.wantsLayer = true
        let name = "\(topRight)/\(bottomRight)"
        let mask = (view.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        guard mask.frame != view.bounds || mask.name != name else { return }
        mask.frame = view.bounds; mask.name = name
        let width = view.bounds.width, height = view.bounds.height
        let radius = min(Self.radius, min(width, height) / 2)
        let tr = min(topRight, radius), br = min(bottomRight, radius)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: width - tr, y: 0))
        path.addArc(tangent1End: CGPoint(x: width, y: 0), tangent2End: CGPoint(x: width, y: tr), radius: tr)
        path.addLine(to: CGPoint(x: width, y: height - br))
        path.addArc(tangent1End: CGPoint(x: width, y: height), tangent2End: CGPoint(x: width - br, y: height), radius: br)
        path.addLine(to: CGPoint(x: radius, y: height))
        path.addArc(tangent1End: CGPoint(x: 0, y: height), tangent2End: CGPoint(x: 0, y: height - radius), radius: radius)
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addArc(tangent1End: .zero, tangent2End: CGPoint(x: radius, y: 0), radius: radius)
        path.closeSubpath()
        mask.path = path
        view.layer?.cornerRadius = 0
        view.layer?.mask = mask
    }
}
