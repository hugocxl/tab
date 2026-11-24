import AppKit
import TabCore

/// The right sidebar, laid out like the left one on the window's chrome
/// without a card: the top row with one button per active plugin tab on the
/// left and the close button on the right, then the selected tab's content
/// (or an empty state when no plugins are installed). Pressing the open tab's
/// button closes it too. The left edge resizes it.
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

    /// Active plugin panels shown as top-row tabs.
    var panels: [RightPanelDescriptor] = [] {
        didSet {
            guard panels != oldValue else { return }
            rebuildTabs()
        }
    }

    /// The tab in front; its button stays filled.
    var selected: String? {
        didSet {
            for (panel, button) in tabs { button.isOn = panel.id == selected }
        }
    }

    var onSelect: ((String) -> Void)?
    var onToggle: (() -> Void)?
    var onOpenPluginSettings: (() -> Void)? {
        didSet { emptyView.onOpenSettings = onOpenPluginSettings }
    }
    /// The live width while the edge is dragged, then `nil` on release.
    var onResize: ((CGFloat?) -> Void)?

    private var tabs: [(RightPanelDescriptor, ChromeButton)] = []
    private let toggle = ChromeButton(ChromeIcon.panelRight, label: "Hide Sidebar")
    private let handle = PanelResizeHandle()
    private let emptyView = RightSidebarEmptyView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toggle.onPress = { [weak self] _ in self?.onToggle?() }
        addSubview(toggle)
        addSubview(emptyView)
        addSubview(handle)
        handle.onBegin = { [weak self] in self?.handle.startWidth = self?.frame.width ?? 0 }
        handle.onDrag = { [weak self] delta in
            guard let self else { return }
            guard let delta else {
                self.onResize?(nil)
                return
            }
            let width = self.handle.startWidth - delta
            self.onResize?(min(max(width, RightPanelMetrics.minimumWidth), RightPanelMetrics.maximumWidth))
        }
        updateEmptyState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    private func rebuildTabs() {
        for (_, button) in tabs { button.removeFromSuperview() }
        tabs = panels.map { panel in
            let button = ChromeButton(panel.icon, label: panel.title)
            button.shortcut = panel.shortcut
            button.isOn = panel.id == selected
            button.onPress = { [weak self] _ in self?.onSelect?(panel.id) }
            addSubview(button, positioned: .below, relativeTo: handle)
            return (panel, button)
        }
        updateEmptyState()
        needsLayout = true
    }

    func updateEmptyState() {
        emptyView.isHidden = !panels.isEmpty || content != nil
    }

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
        emptyView.frame = contentFrame
        handle.frame = CGRect(x: 0, y: 0, width: 5, height: bounds.height)
    }
}

/// Shown in the right sidebar when no plugins are installed.
private final class RightSidebarEmptyView: ThemedView {
    var onOpenSettings: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = makeLabel("No Plugins Installed", font: AppFont.system(13, weight: .semibold))
    private let detailLabel = makeLabel(
        "Install plugins such as Explorer or Diff View in Settings to display them in the right sidebar.",
        font: AppFont.footnote
    )
    private let actionButton = NSButton(title: "Open Plugin Settings…", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.alignment = .center
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular
        actionButton.target = self
        actionButton.action = #selector(openSettings)

        let stack = NSStackView(views: [iconView, titleLabel, detailLabel, actionButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    override func themeDidChange() {
        iconView.image = AppIcon.extensions.image(size: 24)
        iconView.contentTintColor = theme.fgMuted
        titleLabel.textColor = theme.fg
        detailLabel.textColor = theme.fgMuted
    }
}

/// A right sidebar tab's footer row, laid out like the left sidebar's: a
/// muted title, or the left sidebar's filter, on the left and the tab's
/// buttons on the right. The inner
/// edge, beside the panes, keeps the button gap and the window edge the
/// gutter, mirroring the left sidebar.
public final class RightSidebarFooter: ThemedView {
    /// The space between the sidebar's inner edge and its first button.
    public static let innerInset = ChromeButton.gap
    /// The space between the window's edge and the sidebar's last button.
    public static let outerInset = Metrics.gutter

    private let titleLabel = makeLabel("", font: AppFont.body)
    public private(set) var buttons: [ChromeButton] = []
    /// Shown over the last button while it is hidden, such as Refresh
    /// while a change runs.
    private var spinner: Spinner?
    /// Shown in the title's place, as the left sidebar's footer shows it.
    private var filter: SidebarFilterView?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        addSubview(titleLabel)
        heightAnchor.constraint(equalToConstant: ChromeButton.rowHeight).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var mouseDownCanMoveWindow: Bool { true }

    public var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    @discardableResult
    public func addButton(_ icon: AppIcon, label: String, action: @escaping () -> Void) -> ChromeButton {
        let button = ChromeButton(icon, label: label) { _ in action() }
        buttons.append(button)
        addSubview(button)
        needsLayout = true
        return button
    }

    /// Shows `filter` in the title's place.
    public func setFilter(_ filter: SidebarFilterView) {
        self.filter?.removeFromSuperview()
        self.filter = filter
        filter.translatesAutoresizingMaskIntoConstraints = true
        addSubview(filter)
        titleLabel.isHidden = true
        needsLayout = true
    }

    /// Shows `spinner` where the last button is.
    public func setSpinner(_ spinner: Spinner) {
        self.spinner = spinner
        spinner.translatesAutoresizingMaskIntoConstraints = true
        addSubview(spinner)
        needsLayout = true
    }

    public override func themeDidChange() {
        titleLabel.textColor = theme.fgMuted
    }

    public override func layout() {
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
        filter?.frame = CGRect(x: Self.innerInset, y: y, width: max(trailing - Self.innerInset, ChromeButton.side),
                               height: ChromeButton.side)
        let height = titleLabel.intrinsicContentSize.height
        titleLabel.frame = CGRect(x: leading, y: (y + (ChromeButton.side - height) / 2).rounded(),
                                  width: max(trailing - leading, 0), height: height)
    }
}
