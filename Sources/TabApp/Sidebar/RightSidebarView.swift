import AppKit

/// The right sidebar: a card holding the selected tab's content and, right
/// of it on the window chrome, a rail with one button per tab stacked
/// vertically and the close button at the bottom. Pressing the open tab's
/// button closes it too. The card's left edge resizes it.
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

    /// The rail's width: a button with the gutter on either side.
    static let railWidth: CGFloat = Metrics.gutter * 2 + ChromeButton.side

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
        let railX = max(bounds.width - Self.railWidth, 0)
        for (index, (_, button)) in tabs.enumerated() {
            let y = gutter + CGFloat(index) * (side + ChromeButton.gap)
            button.frame = CGRect(x: railX + gutter, y: y, width: side, height: side)
        }
        toggle.frame = CGRect(x: railX + gutter, y: max(bounds.height - gutter - side, gutter), width: side, height: side)
        card.frame = CGRect(x: 0, y: gutter, width: railX, height: max(bounds.height - gutter * 2, 0))
        handle.frame = CGRect(x: 0, y: 0, width: 5, height: bounds.height)
    }
}

/// The card the selected tab's content fills: the panel color, a hairline
/// border and the cards' corner radius.
private final class RightSidebarCard: ThemedView {
    private let glass = GlassView(style: .pane)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(glass)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cardRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Metrics.border
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override var redrawsOnKeyChange: Bool { true }

    override func layout() {
        super.layout()
        glass.frame = bounds
    }

    override func updateLayer() {
        glass.isHidden = !theme.glassEnabled
        glass.appearance = theme.nsAppearance
        glass.apply(theme.paneGlass(isKey: window?.isKeyWindow ?? true, isActive: false))
        layer?.backgroundColor = (theme.glassEnabled ? NSColor.clear : NativeStyle.panel(theme)).cgColor
        layer?.borderWidth = theme.glassEnabled ? 0 : Metrics.border
        layer?.borderColor = theme.cardBorder.cgColor
    }
}
