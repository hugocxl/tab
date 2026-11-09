import AppKit

/// The right sidebar, laid out like the left one on the window's chrome
/// without a card: the top row with one button per tab on the left and the
/// close button on the right, then the selected tab's content, whose footer
/// row holds the tab's own buttons. Pressing the open tab's button closes
/// it too. The left edge resizes it.
final class RightSidebarView: NSView {
    var content: NSView? {
        didSet {
            guard content !== oldValue else { return }
            oldValue?.removeFromSuperview()
            guard let content else { return }
            content.frame = contentFrame
            content.autoresizingMask = [.width, .height]
            addSubview(content, positioned: .below, relativeTo: handle)
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
    private let toggle = ChromeButton(SystemSymbol.panelRight, label: "Hide Sidebar")
    private let handle = PanelResizeHandle()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (kind, button) in tabs {
            button.onPress = { [weak self] _ in self?.onSelect?(kind) }
            addSubview(button)
        }
        toggle.onPress = { [weak self] _ in self?.onToggle?() }
        addSubview(toggle)
        addSubview(handle)
        handle.onBegin = { [weak self] in self?.handle.startWidth = self?.frame.width ?? 0 }
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

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// Below the top row, to the bottom edge: the content draws its own
    /// footer row there.
    private var contentFrame: CGRect {
        let top = ChromeButton.rowHeight
        return CGRect(x: 0, y: top, width: bounds.width, height: max(bounds.height - top, 0))
    }

    override func layout() {
        super.layout()
        let side = ChromeButton.side
        let y = Metrics.gutter
        CircleButton.layOut(tabs.map(\.1), leadingAt: RightSidebarFooter.innerInset, y: y)
        toggle.frame = CGRect(x: bounds.width - RightSidebarFooter.outerInset - side, y: y, width: side, height: side)
        content?.frame = contentFrame
        handle.frame = CGRect(x: 0, y: 0, width: 5, height: bounds.height)
    }
}

/// A right sidebar tab's footer row, laid out like the left sidebar's: a
/// muted title on the left and the tab's buttons on the right. The inner
/// edge, beside the panes, keeps the button gap and the window edge the
/// gutter, mirroring the left sidebar.
final class RightSidebarFooter: ThemedView {
    /// The space between the sidebar's inner edge and its first button.
    static let innerInset = ChromeButton.gap
    /// The space between the window's edge and the sidebar's last button.
    static let outerInset = Metrics.gutter

    private let titleLabel = makeLabel("", font: AppFont.body)
    private(set) var buttons: [ChromeButton] = []
    /// Shown over the last button while it is hidden, such as Refresh
    /// while a change runs.
    private var spinner: Spinner?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        addSubview(titleLabel)
        heightAnchor.constraint(equalToConstant: ChromeButton.rowHeight).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { true }

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    func addButton(_ icon: AppIcon, label: String, action: @escaping () -> Void) -> ChromeButton {
        let button = ChromeButton(icon, label: label) { _ in action() }
        buttons.append(button)
        addSubview(button)
        needsLayout = true
        return button
    }

    /// Shows `spinner` where the last button is.
    func setSpinner(_ spinner: Spinner) {
        self.spinner = spinner
        spinner.translatesAutoresizingMaskIntoConstraints = true
        addSubview(spinner)
        needsLayout = true
    }

    override func themeDidChange() {
        titleLabel.textColor = theme.fgMuted
    }

    override func layout() {
        super.layout()
        let y = Metrics.gutter
        CircleButton.layOut(buttons, trailingAt: bounds.width - Self.outerInset, y: y)
        if let spinner, let last = buttons.last {
            let size = spinner.fittingSize
            spinner.frame = CGRect(x: (last.frame.midX - size.width / 2).rounded(), y: (last.frame.midY - size.height / 2).rounded(),
                                   width: size.width, height: size.height)
        }
        let leading = Self.innerInset + (ChromeButton.side - ChromeButton.glyph) / 2
        let trailing = (buttons.first?.frame.minX ?? bounds.width - Self.outerInset) - ChromeButton.gap
        let height = titleLabel.intrinsicContentSize.height
        titleLabel.frame = CGRect(x: leading, y: (y + (ChromeButton.side - height) / 2).rounded(),
                                  width: max(trailing - leading, 0), height: height)
    }
}
