import AppKit
import TabProtocol

@MainActor
final class AgentAttachmentCache {
    typealias Fetch = (String, AgentChatAttachmentDescriptor) async throws -> Data
    var fetch: Fetch?
    private let cache = NSCache<NSString, NSData>()
    private var pending: [String: Task<Data, Error>] = [:]
    init() { cache.totalCostLimit = 32 * 1024 * 1024 }
    func data(item: String, attachment: AgentChatAttachmentDescriptor) async throws -> Data {
        // Provider IDs may themselves contain slashes. Length-prefix both
        // identities so cached bytes cannot cross message ownership boundaries.
        let key = "\(item.utf8.count):\(item)\(attachment.id.utf8.count):\(attachment.id):\(attachment.byteCount)"
        if let cached = cache.object(forKey: key as NSString) { return cached as Data }
        if let task = pending[key] { return try await task.value }
        guard let fetch else { throw ModelError("Attachment previews are unavailable on this server.") }
        let task = Task {
            let data = try await fetch(item, attachment)
            try Task.checkCancellation()
            guard data.count == attachment.byteCount, data.count <= AgentChatAttachment.maxPayloadBytes else {
                throw ModelError("The attachment payload does not match this message.")
            }
            return data
        }
        pending[key] = task
        defer { pending[key] = nil }
        let data = try await task.value
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }
    func cancel() { pending.values.forEach { $0.cancel() }; pending.removeAll(); cache.removeAllObjects() }
}

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
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(item: String, attachments: [AgentChatAttachmentDescriptor], theme: AppTheme) {
        isHidden = attachments.isEmpty
        if self.item != item || descriptors != attachments {
            tiles.forEach { $0.removeFromSuperview() }
            tiles = []; self.item = item; descriptors = attachments
            for (index, attachment) in attachments.enumerated() {
                let tile = AgentMediaTile(name: attachment.name)
                tile.onPress = { [weak self, weak tile] in
                    guard let self, let tile else { return }
                    if tile.image != nil { self.onPreview?(item, attachments, index) }
                    else { self.load(tile, attachment: attachment) }
                }
                addSubview(tile); tiles.append(tile)
                load(tile, attachment: attachment)
            }
        }
        layer?.backgroundColor = theme.border.cgColor
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

    private func load(_ tile: AgentMediaTile, attachment: AgentChatAttachmentDescriptor) {
        guard let fetch else { tile.fail("Preview unavailable"); return }
        let item = item
        tile.imageActions.name = attachment.name
        tile.imageActions.mimeType = attachment.mimeType
        tile.imageActions.fetch = { try await fetch(item, attachment) }
        tile.load {
            let data = try await fetch(item, attachment)
            guard let image = await AgentAttachmentImporter.previewImage(data: data, pixels: 600) else {
                throw ModelError("This image could not be decoded.")
            }
            return image
        } changed: { [weak self] in self?.onHeightChanged?() }
    }

    func measuredSize(maxWidth: CGFloat) -> NSSize {
        guard !tiles.isEmpty else { return .zero }
        if tiles.count == 1 {
            let ratio = tiles[0].image.map { $0.size.width / max(1, $0.size.height) } ?? (4 / 3)
            return NSSize(width: min(maxWidth, max(96, 192 * ratio)), height: 192)
        }
        let width = min(320, maxWidth)
        return NSSize(width: width, height: tiles.count <= 3 ? 192 : CGFloat((tiles.count + 1) / 2) * 96 + CGFloat((tiles.count - 1) / 2))
    }

    override func layout() {
        super.layout()
        AgentMessageShape.apply(to: self, bottomRight: joinsTextBubble ? AgentMessageShape.joinedRadius : AgentMessageShape.radius)
        let count = tiles.count, width = bounds.width
        for (index, tile) in tiles.enumerated() {
            if count == 1 { tile.frame = bounds }
            else if count == 2 { tile.frame = NSRect(x: CGFloat(index) * (width + 1) / 2, y: 0, width: (width - 1) / 2, height: 192) }
            else if count == 3 {
                let first = (width - 1) * 0.6
                tile.frame = index == 0 ? NSRect(x: 0, y: 0, width: first, height: 192)
                    : NSRect(x: first + 1, y: CGFloat(index - 1) * 96.5, width: width - first - 1, height: 95.5)
            } else {
                let full = count % 2 == 1 && index == count - 1
                tile.frame = NSRect(x: CGFloat(index % 2) * (width + 1) / 2, y: CGFloat(index / 2) * 97,
                                    width: full ? width : (width - 1) / 2, height: 96)
            }
        }
    }
}

@MainActor
final class AgentMediaTile: NSControl {
    let imageActions: AgentImageActions
    private(set) var image: NSImage?
    private let label = makeLabel("", font: AppFont.footnote)
    private let name: String
    private var task: Task<Void, Never>?
    private var generation = 0
    private let animatedImage = AgentAnimatedImageView()
    var isToolResult = false { didSet { updateToolPlaceholder() } }
    /// Assistant Markdown media keep their alt text as tooltip while loading or failed.
    var keepsNameToolTip = false { didSet { updateToolPlaceholder() } }
    private var failureMessage: String?
    private var placeholderColor = NSColor.secondaryLabelColor
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
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        wantsLayer = true
        layer?.masksToBounds = true
        animatedImage.imageScaling = .scaleAxesIndependently
        animatedImage.setAccessibilityElement(false)
        addSubview(animatedImage, positioned: .below, relativeTo: label)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Preview " + name)
        toolTip = name
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { task?.cancel() }
    func suspend() {
        generation += 1; task?.cancel(); task = nil; image = nil
        animatedImage.animates = false
        animatedImage.image = nil
        label.isHidden = false; label.stringValue = name
        failureMessage = nil
        updateToolPlaceholder()
        needsDisplay = true
    }
    func apply(_ theme: AppTheme) {
        background = isToolResult ? theme.surface.withAlphaComponent(theme.surface.alphaComponent * 0.6) : theme.card
        placeholderColor = theme.fgMuted; label.textColor = theme.fgMuted; needsDisplay = true
    }
    func fail(_ message: String) {
        failureMessage = message
        label.stringValue = "\(name) — \(message). Click to retry"; label.isHidden = false; toolTip = label.stringValue
        updateToolPlaceholder(); needsDisplay = true
    }
    private func updateToolPlaceholder() {
        guard isToolResult else { return }
        label.isHidden = true
        setAccessibilityRole(image == nil ? .group : .button)
        setAccessibilityLabel(image == nil ? (failureMessage == nil ? "Loading image" : "Image unavailable · " + name) : "Preview " + name)
        toolTip = image == nil && !keepsNameToolTip ? nil : name
        needsDisplay = true
    }
    func load(_ fetch: @escaping () async throws -> NSImage, changed: @escaping () -> Void) {
        generation += 1
        let token = generation
        task?.cancel()
        label.stringValue = "Loading \(name)…"
        label.isHidden = false
        failureMessage = nil
        updateToolPlaceholder()
        task = Task { [weak self] in
            do {
                let image = try await fetch()
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.show(image)
                changed()
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.fail(error.localizedDescription)
            }
        }
    }
    /// Shows an already decoded image now, ending any pending load; GIFs play.
    func show(_ image: NSImage) {
        generation += 1
        task?.cancel(); task = nil
        failureMessage = nil
        self.image = image
        let animated = image.representations.contains {
            (($0 as? NSBitmapImageRep)?.value(forProperty: .frameCount) as? NSNumber)?.intValue ?? 0 > 1
        }
        animatedImage.image = animated ? image : nil
        animatedImage.animates = animated && window != nil
        needsLayout = true
        updateToolPlaceholder()
        label.isHidden = true
        toolTip = name
        needsDisplay = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animatedImage.animates = window != nil && animatedImage.image != nil
    }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 8, y: max(0, bounds.midY - 10), width: max(0, bounds.width - 16), height: 20)
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            animatedImage.frame = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if image == nil || !transparentBackground { background.setFill(); bounds.fill() }
        if let image, animatedImage.image == nil, image.size.width > 0, image.size.height > 0 {
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            NSGraphicsContext.saveGraphicsState()
            bounds.clip()
            image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        if isToolResult, image == nil, failureMessage != nil { drawToolFailure() }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2)); outline.lineWidth = 3; outline.stroke()
        }
    }
    private func drawToolFailure() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 16; paragraph.maximumLineHeight = 16
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: AppFont.system(12), .foregroundColor: placeholderColor, .paragraphStyle: paragraph]
        let value = ("Image unavailable · " + name) as NSString
        let available = max(1, bounds.width - 18 - 20)
        let width = min(available, ceil(value.size(withAttributes: attributes).width))
        let measured = value.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: attributes).height
        let height = max(16, ceil(measured))
        let origin = NSPoint(x: (bounds.width - width - 20) / 2, y: (bounds.height - height) / 2)
        AgentConversationIcon.warning.image(size: 14, color: placeholderColor)?.draw(
            in: NSRect(x: origin.x, y: bounds.midY - 7, width: 14, height: 14), from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        value.draw(in: NSRect(x: origin.x + 20, y: origin.y, width: width, height: height), withAttributes: attributes)
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; animatedImage.needsDisplay = true; return acceptsFirstResponder }
    override func resignFirstResponder() -> Bool { needsDisplay = true; animatedImage.needsDisplay = true; return true }
    override func mouseDown(with event: NSEvent) { guard !isToolResult || image != nil else { return }; window?.makeFirstResponder(self); onPress?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109, event.modifierFlags.contains(.shift) {
            imageActions.menu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
            return
        }
        guard !isToolResult || image != nil else { return }
        if event.keyCode == 36 || event.keyCode == 49 { onPress?() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { guard !isToolResult || image != nil else { return false }; onPress?(); return true }
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
