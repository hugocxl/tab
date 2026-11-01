import AppKit

/// The right sidebar: a header on the window chrome, like the left sidebar's
/// top row, with one button per tab and the collapse toggle, above a card
/// holding the selected tab's content. Its left edge resizes it.
final class RightSidebarView: ThemedView {
    var content: NSView? {
        didSet {
            guard content !== oldValue else { return }
            oldValue?.removeFromSuperview()
            guard let content else { return }
            placeSubviews()
            content.frame = card.bounds
            content.autoresizingMask = [.width, .height]
            card.addSubview(content)
        }
    }

    /// The tab in front; its button stays filled.
    var selected: RightPanelKind? {
        didSet {
            for (kind, button) in tabs { button.isOn = kind == selected }
        }
    }

    var onSelect: ((RightPanelKind) -> Void)?
    var onToggle: (() -> Void)?
    /// The live width while the edge is dragged, then `nil` on release.
    var onResize: ((CGFloat?) -> Void)?

    private let tabs: [(RightPanelKind, ChromeButton)] = RightPanelKind.allCases.map { kind in
        let button = ChromeButton(kind.icon, label: kind.title)
        button.shortcut = kind.shortcut
        return (kind, button)
    }
    private let toggle = ChromeButton(.panelRight, label: "Hide Sidebar")
    private let card = RightSidebarCard()
    private let handle = PanelResizeHandle()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(card)
        for (kind, button) in tabs {
            button.onPress = { [weak self] _ in self?.onSelect?(kind) }
            addSubview(button)
        }
        toggle.onPress = { [weak self] _ in self?.onToggle?() }
        addSubview(toggle)
        addSubview(handle)
        handle.onBegin = { [weak self] in self?.handle.startWidth = self?.card.frame.width ?? 0 }
        handle.onDrag = { [weak self] delta in
            guard let self else { return }
            guard let delta else {
                self.onResize?(nil)
                return
            }
            let width = self.handle.startWidth - delta
            self.onResize?(min(max(width, RightPanelKind.minimumWidth), RightPanelKind.maximumWidth))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { true }

    /// The card's width, which the sidebar's width is measured by.
    var cardWidth: CGFloat { card.frame.width }

    override func layout() {
        super.layout()
        placeSubviews()
    }

    private func placeSubviews() {
        let gutter = Metrics.gutter
        let side = ChromeButton.side
        let cardWidth = max(bounds.width - gutter, 0)
        let mid = gutter + ((Metrics.headerHeight - side) / 2).rounded()
        CircleButton.layOut(tabs.map(\.1), leadingAt: 0, y: mid)
        toggle.frame = CGRect(x: cardWidth - side, y: mid, width: side, height: side)
        let top = gutter + Metrics.headerHeight
        card.frame = CGRect(x: 0, y: top, width: cardWidth, height: max(bounds.height - top - gutter, 0))
        handle.frame = CGRect(x: 0, y: 0, width: 5, height: bounds.height)
    }
}

/// The card the selected tab's content fills: the panel color, a hairline
/// border and the cards' corner radius.
private final class RightSidebarCard: ThemedView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cardRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Metrics.border
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NativeStyle.panel(theme).cgColor
        layer?.borderColor = theme.cardBorder.cgColor
    }
}
