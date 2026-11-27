import AppKit

/// The overlay scrollbar over a terminal's right edge: shown while scrolling
/// or scrolled into history, hidden shortly after; the thumb can be dragged.
final class TerminalScrollbar: NSView {
    static let width: CGFloat = 7
    static let edgeGap: CGFloat = 2
    static let minimumThumb: CGFloat = 24

    /// Rows above the visible ones that can be scrolled to, and the rows shown.
    var scrollable: Double = 0 { didSet { if scrollable != oldValue { needsDisplay = true } } }
    var visibleRows: Double = 1 { didSet { if visibleRows != oldValue { needsDisplay = true } } }
    /// Rows the view is scrolled up from live output.
    var offset: Double = 0 { didSet { if offset != oldValue { needsDisplay = true } } }
    var thumbColor = NSColor(white: 1, alpha: 0.3) { didSet { needsDisplay = true } }
    /// Called with the new offset while the thumb is dragged.
    var onScroll: ((Double) -> Void)?

    private var grab: CGFloat?
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Shows the scrollbar, and hides it after a pause unless scrolled up.
    func reveal() {
        guard scrollable > 0 else { return hide() }
        hideWork?.cancel()
        if alphaValue < 1 { animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.grab == nil else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        guard alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 0
        }
    }

    var thumbRect: CGRect? {
        guard scrollable > 0, bounds.height > 0 else { return nil }
        let total = scrollable + visibleRows
        let length = max(Self.minimumThumb, bounds.height * CGFloat(visibleRows / total))
        let travel = bounds.height - length
        let fraction = 1 - min(max(offset / scrollable, 0), 1)
        return CGRect(x: bounds.width - Self.width - Self.edgeGap, y: travel * CGFloat(fraction),
                      width: Self.width, height: length)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let thumb = thumbRect else { return }
        thumbColor.setFill()
        NSBezierPath(roundedRect: thumb, xRadius: Self.width / 2, yRadius: Self.width / 2).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0, let thumb = thumbRect else { return nil }
        let local = convert(point, from: superview)
        return local.x >= bounds.width - Self.width * 2 - Self.edgeGap && thumb.minY - 4 <= local.y
            && local.y <= thumb.maxY + 4 ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let thumb = thumbRect else { return }
        grab = convert(event.locationInWindow, from: nil).y - thumb.minY
        hideWork?.cancel()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab, let thumb = thumbRect else { return }
        let travel = bounds.height - thumb.height
        guard travel > 0 else { return }
        let origin = convert(event.locationInWindow, from: nil).y - grab
        let fraction = Double(min(max(origin / travel, 0), 1))
        onScroll?(scrollable * (1 - fraction))
    }

    override func mouseUp(with event: NSEvent) {
        grab = nil
        reveal()
    }
}
