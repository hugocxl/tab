import AppKit
import QuartzCore
import TabCore

/// The window's notices, stacked at the corner Settings picks. The newest
/// is in front; up to two more peek out behind it, narrower and fainter.
/// Pointing at the stack fans it out into a list and holds every notice
/// until the pointer leaves. Notices come in from the window's edge and
/// leave toward it. Covers the window but takes clicks only on notices.
@MainActor
final class NoticeStack: NSView {
    private struct Entry {
        let id: String
        let view: NoticeView
        /// Seconds the notice stays, or `nil` until it is removed.
        let lifetime: TimeInterval?
        var deadline: Date?
        var timer: DispatchWorkItem?
    }

    var position: NotificationPosition = .bottomRight {
        didSet { if position != oldValue { arrange(animated: true) } }
    }

    /// Kept beyond this, the oldest timed notice goes first.
    static let capacity = 5
    /// How many notices peek out of a collapsed stack.
    private static let visible = 3
    private static let gap: CGFloat = 8
    /// How far each notice behind peeks out, and is inset on each side.
    private static let peek: CGFloat = 7
    private static let travel: CGFloat = 16
    private static let duration: TimeInterval = 0.4
    private static let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    /// Oldest first.
    private var entries: [Entry] = []
    private var expanded = false
    private var hoverArea: NSTrackingArea?
    private var counter = 0

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    private var reduceMotion: Bool { AppTheme.shared.accessibility.reduceMotion }

    // MARK: Showing

    /// The ids of the notices shown, newest first.
    var ids: [String] { entries.reversed().map(\.id) }

    func notice(_ id: String) -> Notice? { entries.first { $0.id == id }?.view.notice }

    /// Shows `notice`, or updates the notice already shown as `id` in place.
    /// - Parameters:
    ///   - lifetime: seconds before it hides itself; `nil` keeps it until removed.
    ///   - action: runs when its button is pressed.
    ///   - dismiss: runs when it is closed.
    @discardableResult
    func show(_ notice: Notice, id: String? = nil, lifetime: TimeInterval? = nil,
              action: (() -> Void)? = nil, dismiss: (() -> Void)? = nil) -> String {
        let id = id ?? nextId()
        if let index = entries.firstIndex(where: { $0.id == id }) {
            let view = entries[index].view
            wire(view, id: id, action: action, dismiss: dismiss)
            guard view.notice != notice else { return id }
            let resized = view.notice?.message != notice.message || view.notice?.button != notice.button
            view.notice = notice
            if resized { arrange(animated: true) }
            return id
        }
        let view = NoticeView()
        view.notice = notice
        wire(view, id: id, action: action, dismiss: dismiss)
        addSubview(view)
        entries.append(Entry(id: id, view: view, lifetime: lifetime))
        if entries.count > Self.capacity {
            let oldest = entries.firstIndex { $0.lifetime != nil } ?? 0
            remove(entries[oldest].id)
        }
        if !expanded { schedule(id) }
        NSAccessibility.post(element: view, notification: .announcementRequested,
                             userInfo: [.announcement: notice.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        arrange(animated: true, entering: view)
        return id
    }

    /// Takes the notice `id` away toward the window's edge.
    func remove(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        entry.timer?.cancel()
        let view = entry.view
        view.onAction = nil
        view.onDismiss = nil
        if entries.isEmpty { expanded = false }
        arrange(animated: true)
        guard !reduceMotion, window != nil else {
            view.removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.duration * 0.6
            context.timingFunction = Self.timing
            view.animator().alphaValue = 0
            view.animator().frame = view.frame.offsetBy(dx: 0, dy: position.isTop ? -Self.travel : Self.travel)
        }, completionHandler: {
            MainActor.assumeIsolated { view.removeFromSuperview() }
        })
    }

    private func nextId() -> String {
        counter += 1
        return "notice-\(counter)"
    }

    private func wire(_ view: NoticeView, id: String, action: (() -> Void)?, dismiss: (() -> Void)?) {
        view.onAction = action
        view.onDismiss = { [weak self] in
            dismiss?()
            self?.remove(id)
        }
    }

    // MARK: Timing

    private func schedule(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), let lifetime = entries[index].lifetime else { return }
        let remaining = entries[index].deadline.map { max($0.timeIntervalSinceNow, 1.5) } ?? lifetime
        let timer = DispatchWorkItem { [weak self] in self?.remove(id) }
        entries[index].timer?.cancel()
        entries[index].timer = timer
        entries[index].deadline = Date(timeIntervalSinceNow: remaining)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: timer)
    }

    /// Holds every notice while the pointer is on the stack.
    private func pause() {
        for index in entries.indices {
            entries[index].timer?.cancel()
            entries[index].timer = nil
        }
    }

    private func resume() {
        for entry in entries { schedule(entry.id) }
    }

    // MARK: Hovering

    override func mouseEntered(with event: NSEvent) {
        guard !expanded, !entries.isEmpty else { return }
        expanded = true
        pause()
        arrange(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard expanded else { return }
        expanded = false
        resume()
        arrange(animated: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateHoverArea()
    }

    /// Tracks the area the stack covers, fanned out or not, so moving
    /// between notices keeps it open.
    private func updateHoverArea() {
        let frames = entries.suffix(expanded ? Self.capacity : Self.visible).map { frame(of: $0.view, expanded: expanded) }
        let area = frames.reduce(NSRect.null) { $0.union($1) }
        if let hoverArea, hoverArea.rect == area { return }
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard !area.isNull else { return }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp]
        if expanded { options.insert(.assumeInside) }
        let tracking = NSTrackingArea(rect: area.insetBy(dx: 0, dy: -Self.gap / 2), options: options, owner: self)
        addTrackingArea(tracking)
        hoverArea = tracking
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        arrange(animated: false)
    }

    /// One width for every notice, so the stack lines up.
    private var width: CGFloat {
        let inset = SplitGeometry.gutter * 2
        let widest = entries.suffix(Self.visible).map(\.view.fittingWidth).max() ?? 0
        return min(widest, NoticeView.maximumWidth, max(bounds.width - inset * 2, 0))
    }

    /// Where `view` goes: in front, peeking out behind, or listed.
    private func frame(of view: NoticeView, expanded: Bool) -> NSRect {
        guard let position = entries.lastIndex(where: { $0.view === view }) else { return view.frame }
        let index = entries.count - 1 - position
        let width = self.width
        let height = NoticeView.height
        let inset = SplitGeometry.gutter * 2
        let x: CGFloat
        switch self.position.column {
        case -1: x = inset
        case 0: x = ((bounds.width - width) / 2).rounded()
        default: x = bounds.width - inset - width
        }
        let top = self.position.isTop
        let frontY = top ? inset + Metrics.headerHeight : bounds.height - inset - height
        let direction: CGFloat = top ? 1 : -1
        if expanded {
            return NSRect(x: x, y: frontY + direction * CGFloat(index) * (height + Self.gap), width: width, height: height)
        }
        let depth = CGFloat(min(index, Self.visible - 1))
        return NSRect(x: x + Self.peek * depth, y: frontY + direction * Self.peek * depth,
                      width: width - Self.peek * depth * 2, height: height)
    }

    private func arrange(animated: Bool, entering: NoticeView? = nil) {
        let animated = animated && !reduceMotion && window != nil
        let order = Array(entries.reversed())
        let place = {
            for (index, entry) in order.enumerated() {
                let view = entry.view
                let target = self.frame(of: view, expanded: self.expanded)
                let behind = !self.expanded && index > 0
                let alpha: CGFloat = self.expanded ? 1 : index < Self.visible ? 1 - CGFloat(index) * 0.2 : 0
                view.contentHidden = behind
                if animated {
                    view.animator().frame = target
                    view.animator().alphaValue = alpha
                } else {
                    view.frame = target
                    view.alphaValue = alpha
                }
            }
        }
        if let entering, animated {
            entering.frame = frame(of: entering, expanded: expanded)
                .offsetBy(dx: 0, dy: position.isTop ? -Self.travel : Self.travel)
            entering.alphaValue = 0
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.duration
                context.timingFunction = Self.timing
                context.allowsImplicitAnimation = true
                place()
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                place()
            }
        }
        updateHoverArea()
    }
}
