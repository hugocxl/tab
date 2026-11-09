import AppKit
import TabCore
import TabProtocol

/// One pane in the split layout: a card with a 10pt radius and a 1pt
/// border, a 36pt header (kind or agent glyph, title, and actions shown on
/// the active or hovered card), and the pane's content in an 8pt-inset body.
final class PaneCardView: HoverView {
    let pane: PaneId
    weak var model: AppModel?
    private(set) var controller: PaneContentController?

    private let header = PaneHeaderView()
    private let glass = GlassView(style: .pane)
    private let glyph = NSImageView()
    private let titleLabel = makeLabel("", font: AppFont.header)
    private let suffixLabel = makeLabel("", font: AppFont.header)
    private let progressGlyph = ActivityGlyph()
    private let leading = NSView()
    private var actionButtons: [HeaderButton] = []
    private var extraButtons: [HeaderButton] = []
    private let zoomButton: HeaderButton
    private let body = FlippedView()

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            updateControls()
            needsDisplay = true
        }
    }

    var isZoomed = false {
        didSet {
            guard isZoomed != oldValue else { return }
            zoomButton.show(isZoomed ? .restore : .maximize)
            zoomButton.toolTip = isZoomed ? "Restore Pane" : "Zoom Pane"
        }
    }

    /// Room on the header's left, for the sidebar toggle when the sidebar
    /// is collapsed and this card is top-left.
    var leadingView: NSView? {
        didSet {
            guard leadingView !== oldValue else { return }
            if let oldValue, oldValue.superview === header { oldValue.removeFromSuperview() }
            if let leadingView { header.addSubview(leadingView) }
            needsLayout = true
        }
    }

    /// Room on the header's right, for the right sidebar's toggle when it is
    /// collapsed and this card is top-right.
    var trailingView: NSView? {
        didSet {
            guard trailingView !== oldValue else { return }
            if let oldValue, oldValue.superview === header { oldValue.removeFromSuperview() }
            if let trailingView { header.addSubview(trailingView) }
            needsLayout = true
        }
    }

    init(pane: PaneId, model: AppModel) {
        self.pane = pane
        self.model = model
        zoomButton = HeaderButton(control: .maximize, label: "Zoom Pane")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cardRadius
        layer?.borderWidth = Metrics.border
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous

        glyph.imageScaling = .scaleProportionallyDown
        suffixLabel.lineBreakMode = .byTruncatingHead
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        suffixLabel.translatesAutoresizingMaskIntoConstraints = true
        header.card = self
        body.wantsLayer = true
        body.layer?.masksToBounds = true
        addSubview(glass)
        addSubview(body)
        addSubview(header)
        for view in [glyph, titleLabel, suffixLabel, progressGlyph] as [NSView] { header.addSubview(view) }

        let split = HeaderButton(control: .columns, label: "Split Right") { [weak self] in self?.run { $0.split(.right) } }
        let down = HeaderButton(control: .rows, label: "Split Down") { [weak self] in self?.run { $0.split(.down) } }
        zoomButton.onPress = { [weak self] in
            guard let self else { return }
            self.model?.toggleZoom(self.pane)
        }
        let close = HeaderButton(control: .close, label: "Close Pane") { [weak self] in
            guard let self else { return }
            self.model?.closePane(self.pane)
        }
        split.shortcut = .splitRight
        down.shortcut = .splitDown
        zoomButton.shortcut = .toggleZoomPane
        close.shortcut = .closePane
        actionButtons = [split, down, zoomButton, close]
        for button in actionButtons {
            button.translatesAutoresizingMaskIntoConstraints = true
            header.addSubview(button)
        }
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Focuses this pane, then runs `action` on the model.
    private func run(_ action: (AppModel) -> Void) {
        guard let model else { return }
        model.focusPane(pane)
        action(model)
    }

    /// Shows `controller`'s content in the body.
    func show(_ controller: PaneContentController) {
        if self.controller !== controller {
            self.controller?.view.removeFromSuperview()
            self.controller = controller
            controller.titleDidChange = { [weak self] in self?.refreshHeader() }
            body.addSubview(controller.view)
            needsLayout = true
        } else if controller.view.superview !== body {
            body.addSubview(controller.view)
            needsLayout = true
        }
        refreshHeader()
        needsDisplay = true
    }

    func refreshHeader() {
        guard let model, let controller else { return }
        let kind = model.state.pane(pane).map { PaneKind($0.content) } ?? .terminal
        if let icon = controller.icon {
            glyph.image = icon
            glyph.contentTintColor = nil
        } else {
            glyph.image = kind.symbol.image(size: Metrics.glyph)
            glyph.contentTintColor = theme.fgMuted
        }
        let (title, suffix) = Self.splitTitle(controller.title)
        if titleLabel.stringValue != title { titleLabel.stringValue = title }
        if suffixLabel.stringValue != suffix { suffixLabel.stringValue = suffix }
        let notifications = model.settings.notifications
        if let progress = controller.progress, notifications.showsInTabs(progress.state == .error ? .error : .working) {
            switch progress.state {
            case .error: progressGlyph.style = .dot(theme.danger, diameter: 7)
            case .paused: progressGlyph.style = .dot(theme.warning, diameter: 7)
            default:
                if let percent = progress.percent {
                    progressGlyph.style = .ring(fraction: CGFloat(percent) / 100, theme.accent)
                } else {
                    progressGlyph.style = .spinner(theme.accent)
                }
            }
        } else {
            // Terminal and native agents report the same activity, so both
            // headers show it the same way, as their sidebar card does.
            switch model.agent(in: pane)?.state {
            case .working? where notifications.showsInTabs(.working): progressGlyph.style = .spinner(theme.accent)
            case .blocked? where notifications.showsInTabs(.blocked): progressGlyph.style = .dot(theme.accent, diameter: 7)
            default: progressGlyph.style = .none
            }
        }
        let actions = controller.headerActions
        if actions.map(\.id) != extraButtons.map(\.identifier?.rawValue) || zip(actions, extraButtons).contains(where: { $0.isActive != $1.isActive }) {
            extraButtons.forEach { $0.removeFromSuperview() }
            extraButtons = actions.map { action in
                let button = HeaderButton(action.icon, label: action.label) { action.perform() }
                button.identifier = NSUserInterfaceItemIdentifier(action.id)
                button.isActive = action.isActive
                button.translatesAutoresizingMaskIntoConstraints = true
                header.addSubview(button)
                return button
            }
            updateControls()
        }
        needsLayout = true
    }

    /// A title ending in a path shows the path muted: "zsh ~/code".
    static func splitTitle(_ title: String) -> (String, String) {
        guard let space = title.lastIndex(of: " ") else { return (title, "") }
        let tail = title[title.index(after: space)...]
        guard tail.hasPrefix("~") || tail.hasPrefix("/") else { return (title, "") }
        return (String(title[..<space]), String(tail))
    }

    private func updateControls() {
        let shown = isActive || isHovered
        for button in actionButtons + extraButtons { button.alphaValue = shown ? 1 : 0 }
    }

    override func hoverDidChange() {
        updateControls()
    }

    override var wantsUpdateLayer: Bool { true }
    override var redrawsOnKeyChange: Bool { true }

    override func updateLayer() {
        glass.isHidden = !theme.glassPanes
        glass.appearance = theme.nsAppearance
        glass.apply(theme.paneGlass(isKey: window?.isKeyWindow ?? true, isActive: isActive))
        layer?.backgroundColor = theme.paneBackground.cgColor
        header.wantsLayer = true
        header.layer?.backgroundColor = theme.paneBackground.cgColor
        // Glass panes draw no border, so the glass's own edge catches the light.
        layer?.borderWidth = theme.glassPanes ? 0 : Metrics.border
        layer?.borderColor = theme.cardBorder.cgColor
    }

    override func themeDidChange() {
        titleLabel.textColor = theme.fg
        suffixLabel.textColor = theme.fgMuted
        needsDisplay = true
        refreshHeader()
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let gutter = Metrics.gutter
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Metrics.headerHeight)
        body.frame = CGRect(x: 0, y: Metrics.headerHeight, width: bounds.width, height: max(bounds.height - Metrics.headerHeight, 0))
        controller?.view.frame = body.bounds.insetBy(dx: gutter, dy: gutter)
        let height = Metrics.headerHeight
        var x = gutter
        if let leadingView {
            let size = leadingView.intrinsicContentSize
            leadingView.frame = CGRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + Metrics.controlGap
        }
        glyph.frame = CGRect(x: x, y: (height - Metrics.glyph) / 2, width: Metrics.glyph, height: Metrics.glyph)
        x += Metrics.glyph + Metrics.controlGap
        var right = bounds.width - gutter
        if let trailingView {
            let size = trailingView.intrinsicContentSize
            right -= size.width
            trailingView.frame = CGRect(x: right, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
            right -= Metrics.controlGap
        }
        for button in (extraButtons + actionButtons).reversed() {
            let side = HeaderButton.side
            right -= side
            button.frame = CGRect(x: right, y: (height - side) / 2, width: side, height: side)
            right -= 4
        }
        if progressGlyph.style != .none {
            right -= 14
            progressGlyph.frame = CGRect(x: right, y: (height - 14) / 2, width: 14, height: 14)
            right -= Metrics.controlGap
        } else {
            progressGlyph.frame = .zero
        }
        let available = max(right - x - 4, 0)
        let titleWidth = min(titleLabel.textWidth, available)
        let labelHeight = titleLabel.intrinsicContentSize.height
        let y = ((height - labelHeight) / 2).rounded()
        titleLabel.frame = CGRect(x: x, y: y, width: titleWidth, height: labelHeight)
        let suffixWidth = suffixLabel.stringValue.isEmpty ? 0 : max(min(suffixLabel.textWidth, available - titleWidth - 4), 0)
        suffixLabel.frame = CGRect(x: x + titleWidth + 4, y: y, width: suffixWidth, height: labelHeight)
    }

    // MARK: Header events

    fileprivate func headerClicked(_ event: NSEvent) {
        model?.focusPane(pane)
    }

    fileprivate func headerMenu() -> NSMenu? {
        controller?.contextMenu
    }
}

/// The card header: clicks focus the pane, right clicks show its menu.
final class PaneHeaderView: NSView {
    weak var card: PaneCardView?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        card?.headerClicked(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        card?.headerMenu()
    }
}
