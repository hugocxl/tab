import AppKit

/// The source renderer's scroll-area masks the viewport, leaving the scrollbar outside the fade.
@MainActor
final class AgentTableScrollView: NSScrollView {
    private(set) var leadingFade: CGFloat = 0
    private(set) var trailingFade: CGFloat = 0
    private var viewportFocused = false
    private var maskBounds: CGRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView.wantsLayer = true
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateOverflowFade),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool {
        (documentView?.frame.width ?? 0) > contentView.bounds.width
    }

    override func becomeFirstResponder() -> Bool {
        viewportFocused = true
        updateOverflowFade()
        return true
    }

    override func resignFirstResponder() -> Bool {
        viewportFocused = false
        updateOverflowFade()
        return true
    }

    override func layout() {
        super.layout()
        updateOverflowFade()
    }

    @objc func updateOverflowFade() {
        applyOverflowFade(focused: viewportFocused)
    }

    private func applyOverflowFade(focused: Bool) {
        let viewport = contentView.bounds
        let document = documentView?.frame ?? .zero
        let leading = focused ? 0 : min(24, max(0, viewport.minX - document.minX))
        let trailing = focused ? 0 : min(24, max(0, document.maxX - viewport.maxX))
        guard leading != leadingFade || trailing != trailingFade || maskBounds != viewport else { return }
        leadingFade = leading
        trailingFade = trailing
        maskBounds = viewport
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard viewport.width > 0, leadingFade > 0 || trailingFade > 0 else {
            contentView.layer?.mask = nil
            return
        }
        let mask = CAGradientLayer()
        mask.frame = viewport
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: max(1e-6, leadingFade / viewport.width), y: 0.5)
        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        mask.colors = [leadingFade > 0 ? clear : opaque, opaque]
        // Separate masks multiply when both fades overlap in a very narrow viewport.
        let trailingMask = CAGradientLayer()
        trailingMask.frame = CGRect(origin: .zero, size: viewport.size)
        trailingMask.startPoint = CGPoint(x: min(1 - 1e-6, 1 - trailingFade / viewport.width), y: 0.5)
        trailingMask.endPoint = CGPoint(x: 1, y: 0.5)
        trailingMask.colors = [opaque, trailingFade > 0 ? clear : opaque]
        mask.mask = trailingMask
        contentView.layer?.mask = mask
    }
}
