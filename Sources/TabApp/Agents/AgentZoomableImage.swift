import AppKit

/// Native implementation of the source renderer's ZoomableImage viewport and input rules.
@MainActor
final class AgentZoomableImage: NSScrollView {
    let image = AgentZoomImageView()
    private(set) var zoom: CGFloat = 1
    private var viewerSize = NSSize.zero
    private var fitSize = NSSize.zero
    var onGeometryChanged: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasHorizontalScroller = true; hasVerticalScroller = true
        autohidesScrollers = true; scrollerStyle = .overlay
        horizontalScrollElasticity = .none; verticalScrollElasticity = .none
        image.imageScaling = .scaleAxesIndependently
        image.owner = self
        documentView = image
        setAccessibilityLabel("Zoomable image")
        setAccessibilityHelp("Click to zoom in or return to fit. Scroll to zoom, drag to pan. Use Enter to toggle zoom, plus or minus to zoom, and 0 to fit.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func fitSize(image: NSSize, viewer: NSSize) -> NSSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let width = max(1, viewer.width * 0.92 - (viewer.width >= 640 ? 96 : 0))
        let height = max(1, min(viewer.height * 0.86, viewer.height - 160))
        let fit = min(1, width / image.width, height / image.height)
        return NSSize(width: image.width * fit, height: image.height * fit)
    }
    func configure(viewer: NSSize) -> NSSize {
        if viewerSize != viewer {
            zoom = 1; viewerSize = viewer; contentView.scroll(to: .zero)
            window?.invalidateCursorRects(for: image)
        }
        fitSize = Self.fitSize(image: image.image?.size ?? .zero, viewer: viewer)
        let scaled = NSSize(width: fitSize.width * zoom, height: fitSize.height * zoom)
        image.frame = NSRect(origin: .zero, size: scaled)
        return NSSize(width: min(scaled.width, max(1, viewer.width * 0.92 - (viewer.width >= 640 ? 96 : 0))),
                      height: min(scaled.height, max(1, min(viewer.height * 0.86, viewer.height - 160))))
    }
    func reset() { zoom = 1; contentView.scroll(to: .zero); onGeometryChanged?() }
    func changeZoom(_ value: CGFloat, point: NSPoint? = nil) {
        guard image.image != nil else { return }
        let next = min(8, max(1, value))
        guard next != zoom else { return }
        // Keep the image point under the pointer stationary even when the
        // viewport itself grows from a small image to its maximum size.
        let point = point ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let windowPoint = convert(point, to: nil)
        let anchor = NSPoint(x: (contentView.bounds.minX + point.x) / zoom,
                             y: (contentView.bounds.minY + point.y) / zoom)
        zoom = next
        onGeometryChanged?()
        superview?.layoutSubtreeIfNeeded()
        let updated = convert(windowPoint, from: nil)
        scroll(to: NSPoint(x: anchor.x * next - updated.x, y: anchor.y * next - updated.y))
        window?.invalidateCursorRects(for: image)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: "\(Int((zoom * 100).rounded()))% zoom"])
    }
    func scroll(to point: NSPoint) {
        contentView.scroll(to: NSPoint(x: min(max(0, point.x), max(0, image.frame.width - contentView.bounds.width)),
                                      y: min(max(0, point.y), max(0, image.frame.height - contentView.bounds.height))))
        reflectScrolledClipView(contentView)
    }
    @discardableResult
    func pan(key: UInt16) -> Bool {
        guard zoom > 1 else { return false }
        if [123, 124].contains(key), image.frame.width <= contentView.bounds.width { return false }
        var point = contentView.bounds.origin
        switch key {
        case 123: point.x -= 40
        case 124: point.x += 40
        case 125: point.y += 40
        case 126: point.y -= 40
        default: return false
        }
        scroll(to: point)
        return true
    }
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.charactersIgnoringModifiers {
        case "\r", " ": if !event.isARepeat { changeZoom(zoom > 1 ? 1 : 2) }
        case "+", "=": changeZoom(zoom * 1.5)
        case "-": changeZoom(zoom / 1.5)
        case "0": changeZoom(1)
        default: return false
        }
        return true
    }
    override func keyDown(with event: NSEvent) {
        if !handleKey(event), !pan(key: event.keyCode) { super.keyDown(with: event) }
    }
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 16)
        changeZoom(zoom * exp(delta * (event.modifierFlags.contains(.control) ? 0.01 : 0.002)),
                   point: convert(event.locationInWindow, from: nil))
    }
    override func magnify(with event: NSEvent) { changeZoom(zoom * (1 + event.magnification), point: convert(event.locationInWindow, from: nil)) }
}

@MainActor
final class AgentZoomImageView: AgentActionImageView {
    weak var owner: AgentZoomableImage?
    private var dragStart: NSPoint?
    private var scrollStart = NSPoint.zero
    private var dragged = false
    override var isFlipped: Bool { true }
    override func resetCursorRects() {
        let cursor: NSCursor
        if (owner?.zoom ?? 1) > 1 { cursor = .openHand }
        else if #available(macOS 15, *) { cursor = .zoomIn }
        else { cursor = Self.zoomCursor }
        addCursorRect(bounds, cursor: cursor)
    }
    private static let zoomCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let path = NSBezierPath(ovalIn: NSRect(x: 3, y: 9, width: 12, height: 12))
            path.move(to: NSPoint(x: 13, y: 11)); path.line(to: NSPoint(x: 21, y: 3))
            path.move(to: NSPoint(x: 6, y: 15)); path.line(to: NSPoint(x: 12, y: 15))
            path.move(to: NSPoint(x: 9, y: 12)); path.line(to: NSPoint(x: 9, y: 18))
            NSColor.white.setStroke(); path.lineWidth = 4; path.stroke()
            NSColor.black.setStroke(); path.lineWidth = 2; path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
    }()
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) == false else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(owner)
        dragStart = event.locationInWindow; dragged = false
        scrollStart = owner?.contentView.bounds.origin ?? .zero
    }
    override func mouseDragged(with event: NSEvent) {
        guard let owner, owner.zoom > 1, let start = dragStart else { return }
        let dx = event.locationInWindow.x - start.x, dy = event.locationInWindow.y - start.y
        if hypot(dx, dy) > 4 { dragged = true }
        NSCursor.closedHand.set()
        owner.scroll(to: NSPoint(x: scrollStart.x - dx, y: scrollStart.y + dy))
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; window?.invalidateCursorRects(for: self) }
        guard dragStart != nil, !dragged, event.clickCount <= 1, let owner else { return }
        owner.changeZoom(owner.zoom > 1 ? 1 : 2, point: owner.convert(event.locationInWindow, from: nil))
    }
    override func scrollWheel(with event: NSEvent) { owner?.scrollWheel(with: event) }
}
