import AppKit

/// Fades a scroll view's top and bottom edges where content continues past them,
/// instead of cutting it off. Each fade grows with the hidden overflow up to
/// `length`, so it eases in as the user scrolls away from an end. The mask sits
/// on the clip view, leaving the overlay scroller sharp.
@MainActor
public final class ScrollEdgeFade: NSObject {
    private weak var scrollView: NSScrollView?
    private let length: CGFloat
    private let mask = CAGradientLayer()
    public private(set) var topFade: CGFloat = 0
    public private(set) var bottomFade: CGFloat = 0
    private var maskBounds: CGRect?

    public init(_ scrollView: NSScrollView, length: CGFloat = 24) {
        self.scrollView = scrollView
        self.length = length
        super.init()
        let clip = scrollView.contentView
        clip.wantsLayer = true
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(update), name: NSView.boundsDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(update), name: NSView.frameDidChangeNotification, object: clip)
        if let document = scrollView.documentView {
            document.postsFrameChangedNotifications = true
            center.addObserver(self, selector: #selector(update), name: NSView.frameDidChangeNotification, object: document)
        }
        update()
    }

    @objc func update() {
        guard let scrollView, let clipLayer = scrollView.contentView.layer else { return }
        let clip = scrollView.contentView
        let viewport = clip.bounds
        let document = scrollView.documentView?.frame ?? .zero
        let above = clip.isFlipped ? viewport.minY - document.minY : document.maxY - viewport.maxY
        let below = clip.isFlipped ? document.maxY - viewport.maxY : viewport.minY - document.minY
        let half = viewport.height / 2
        let top = min(length, half, max(0, above.rounded()))
        let bottom = min(length, half, max(0, below.rounded()))
        guard top != topFade || bottom != bottomFade || maskBounds != viewport else { return }
        topFade = top
        bottomFade = bottom
        maskBounds = viewport
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard viewport.height > 0, top > 0 || bottom > 0 else {
            if clipLayer.mask === mask { clipLayer.mask = nil }
            return
        }
        // The mask uses the clip layer's coordinates, which follow its flippedness.
        let first = clip.isFlipped ? top : bottom
        let last = clip.isFlipped ? bottom : top
        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        mask.frame = viewport
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        mask.locations = [0, NSNumber(value: Double(first / viewport.height)),
                          NSNumber(value: Double(1 - last / viewport.height)), 1]
        mask.colors = [first > 0 ? clear : opaque, opaque, opaque, last > 0 ? clear : opaque]
        if clipLayer.mask !== mask { clipLayer.mask = mask }
    }
}
