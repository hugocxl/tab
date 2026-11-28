import AppKit
import TabApp
import TabClient
import TabCore
import TabProtocol

/// The AI Usage panel: one card per signed-in agent account with its
/// plan and every limit, each with its bar, reset and pace. The footer's filter narrows by name, plan or account and
/// its menu picks a provider, the order and the figure. Reads the current
/// project's server, and again on the configured schedule while it shows.
@MainActor
final class UsagePanelController: NSViewController {
    /// The side connection and, for a remote server, its name.
    typealias Resolve = @MainActor (ProjectId) -> (client: ServerAPI?, serverName: String?)?

    /// How long a reading shows before showing the panel asks again.
    static let freshness: TimeInterval = UsageStore.freshness

    private let resolve: Resolve
    private let theme: AppTheme
    private let store: UsageStore
    private var project: (id: ProjectId, server: ServerId)?
    private(set) var config = UsageConfig()
    /// The provider shown alone; nil shows every account.
    private(set) var filter: AgentChatProvider?
    /// The footer filter's text, matched against names, plans and accounts.
    private(set) var query = ""
    private(set) var order = UsageConfig().order
    private(set) var figure = UsageConfig().figure
    /// The providers of the last reading, in the order the menu lists them.
    private var kinds: [(kind: AgentChatProvider, count: Int)] = []
    private var visible = false
    /// What the cards were last built from; a render that matches it keeps them.
    private var shown: Shown?
    /// Ticks each minute while the panel shows: updates the countdowns and reads again when due.
    private var clock: Timer?

    private let card = NativePanelCard()
    private let footer = RightSidebarFooter()
    let filterField = SidebarFilterView(menuLabel: "Filter Providers")
    private let spinner = Spinner()
    private var refreshButton: ChromeButton?
    private let scroll = ScrollView()
    private let stack = NSStackView()
    private let message = NativeMessageView()

    init(theme: AppTheme, store: UsageStore? = nil, resolve: @escaping Resolve) {
        self.theme = theme
        let store = store ?? UsageStore()
        self.store = store
        self.resolve = resolve
        super.init(nibName: nil, bundle: nil)
        store.observe(owner: self) { [weak self] server in
            guard let self, self.project?.server == server else { return }
            self.render()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        card.theme = theme
        card.drawsCard = false
        view = card
        footer.theme = theme
        footer.title = "AI Usage"
        filterField.theme = theme
        filterField.onChange = { [weak self] text in self?.setQuery(text) }
        filterField.hostMenu = { [weak self] in self?.filterMenu() }
        filterField.contextMenu = { [weak self] in self?.filterMenu() }
        footer.setFilter(filterField)
        refreshButton = footer.addButton(.refresh, label: "Refresh") { [weak self] in self?.refresh(force: true) }
        spinner.isHidden = true
        footer.setSpinner(spinner)

        stack.orientation = .vertical
        stack.alignment = .leading
        // The top and footer rows and the panes' own inset already leave a gutter, so the
        // cards sit a gutter from each of them, from the window's edge and from each other.
        stack.spacing = Metrics.gutter
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: RightSidebarFooter.outerInset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.content.bottomAnchor),
        ])
        message.theme = theme
        message.isHidden = true
        card.onColorsChange = { [weak self] in
            self?.shown = nil
            self?.render()
        }

        for subview in [scroll, message, footer] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            message.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            message.topAnchor.constraint(equalTo: card.topAnchor),
            message.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        card.setAccessibilityLabel("AI Usage")
        render()
    }

    /// Applies the plugin's settings; a new display default replaces the panel's own choice.
    func apply(_ next: UsageConfig) {
        let previous = config
        config = next
        if next.order != previous.order { order = next.order }
        if next.figure != previous.figure { figure = next.figure }
        if next.refreshMinutes != previous.refreshMinutes { tick() }
        render()
    }

    /// The panel came on screen: read again when stale and keep the readings current.
    func didShow() {
        visible = true
        refresh(force: false)
        guard clock == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    func didHide() {
        visible = false
        clock?.invalidate()
        clock = nil
    }

    /// Reads again once the configured interval has passed, and otherwise brings the
    /// relative times up to date.
    func tick() {
        guard visible, let project else { return }
        if config.refreshMinutes > 0, case .loaded(_, let at) = store.load(for: project.server),
           Date().timeIntervalSince(at) >= TimeInterval(config.refreshMinutes * 60) - 5 {
            refresh(force: true)
        } else {
            render()
        }
    }

    /// Shows the limits of `project`'s server, reading them when they are stale.
    /// Limits belong to the server, so another project on the same one keeps the cards.
    func show(project: (id: ProjectId, server: ServerId)?) {
        let sameServer = isViewLoaded && project != nil && project?.server == self.project?.server
        self.project = project
        if sameServer { return }
        loadViewIfNeeded()
        render()
        refresh(force: false)
    }

    /// The server came back: what it reported before may be out of date.
    /// What to do when a computer has no providers: another computer's are added, or
    /// copied from this Mac, in its own list in Settings › Agents.
    nonisolated static func noProvidersDetail(on computer: String?) -> String {
        guard let computer else { return "Add a provider in Settings › Agents to see your plan limits." }
        return "Add providers for \(computer), or copy this Mac's, in Settings › Agents to see its plan limits."
    }

    func reconnected(_ server: ServerId) {
        store.clearFailure(for: server)
        if project?.server == server { refresh(force: false) }
    }

    /// Reads `server`'s limits again, as its providers were added, copied or removed.
    func providersChanged(_ server: ServerId) {
        store.markStale(server)
        if project?.server == server { refresh(force: false) }
    }

    /// Reads the limits again; without `force`, only when the last reading is stale.
    func refresh(force: Bool) {
        guard let project else { return }
        store.refresh(project: project, force: force, resolve: resolve)
    }

    func setFilter(_ provider: AgentChatProvider?) {
        filter = provider
        render()
    }

    func setQuery(_ text: String) {
        query = text
        render()
    }

    func setOrder(_ order: UsageConfig.Order) {
        self.order = order
        render()
    }

    func setFigure(_ figure: UsageConfig.Figure) {
        self.figure = figure
        render()
    }

    /// The filter glyph's menu: the providers to show, then the order and the figure.
    func filterMenu() -> NSMenu {
        let menu = NSMenu()
        if let project, let serverName = resolve(project.id)?.serverName {
            menu.addItem(ActionMenuItem(serverName, enabled: false) {})
            menu.addItem(.separator())
        }
        let total = kinds.reduce(0) { $0 + $1.count }
        menu.addItem(Self.item("All Providers  \(total)", checked: filter == nil) { [weak self] in self?.setFilter(nil) })
        for (kind, count) in kinds {
            let item = Self.item("\(UsageAccountCard.providerTitle(kind))  \(count)", checked: filter == kind) { [weak self] in
                self?.setFilter(kind)
            }
            item.image = AgentLogo.image(for: kind.activityProvider, size: 14, theme: theme)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(Self.item("Most Urgent First", checked: order == .urgency) { [weak self] in self?.setOrder(.urgency) })
        menu.addItem(Self.item("By Provider", checked: order == .provider) { [weak self] in self?.setOrder(.provider) })
        menu.addItem(.separator())
        menu.addItem(Self.item("Show Used", checked: figure == .used) { [weak self] in self?.setFigure(.used) })
        menu.addItem(Self.item("Show Left", checked: figure == .left) { [weak self] in self?.setFigure(.left) })
        return menu
    }

    private static func item(_ title: String, checked: Bool, handler: @escaping () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title, handler: handler)
        item.state = checked ? .on : .off
        return item
    }

    /// The account cards shown now.
    var cards: [UsageAccountCard] { stack.arrangedSubviews.compactMap { $0 as? UsageAccountCard } }
    /// The centered message, when one shows.
    var messageText: String { message.isHidden ? "" : message.text }

    // MARK: Rendering

    private func render() {
        guard isViewLoaded else { return }
        let load = project.flatMap { store.load(for: $0.server) }
        let busy: Bool
        let reply: AgentUsageLimitsReply?
        switch load {
        case .loading(let previous):
            busy = true
            reply = previous
        case .loaded(let loaded, _):
            busy = false
            reply = loaded
        case .failed(let reason):
            busy = false
            reply = nil
            showMessage(reason)
        case nil:
            busy = false
            reply = nil
            if project == nil {
                showPlaceholder("No project open", detail: "Open a project to see AI usage.", icon: .chartLine)
            } else {
                showMessage("")
            }
        }
        spinner.isHidden = !busy
        refreshButton?.isHidden = busy

        if case .loading(nil) = load { showMessage("Loading…") }
        guard let reply else { return }
        if reply.providers.isEmpty {
            showPlaceholder("No providers", detail: UsagePanelController.noProvidersDetail(on: project.flatMap { resolve($0.id)?.serverName }),
                            icon: .gaugeMedium)
            return
        }
        populate(reply)
    }

    private func showMessage(_ text: String) {
        shown = nil
        message.set(text)
        message.isHidden = text.isEmpty
        scroll.isHidden = true
    }

    private func showPlaceholder(_ title: String, detail: String, icon: AppIcon) {
        shown = nil
        message.setPlaceholder(title, detail: detail, icon: icon)
        message.isHidden = false
        scroll.isHidden = true
    }

    /// The inputs the cards are built from, the countdowns to the minute.
    private struct Shown: Equatable {
        let reply: AgentUsageLimitsReply
        let filter: AgentChatProvider?
        let query: String
        let order: UsageConfig.Order
        let figure: UsageConfig.Figure
        let lowThreshold: Int
        let minute: Int
    }

    private func populate(_ reply: AgentUsageLimitsReply) {
        let now = Date()
        let next = Shown(reply: reply, filter: filter, query: query, order: order, figure: figure,
                         lowThreshold: config.lowThreshold, minute: Int(now.timeIntervalSince1970 / 60))
        guard next != shown else { return }
        shown = next
        message.isHidden = true
        scroll.isHidden = false
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        kinds = []
        for limits in reply.providers {
            if let index = kinds.firstIndex(where: { $0.kind == limits.provider }) {
                kinds[index].count += 1
            } else {
                kinds.append((limits.provider, 1))
            }
        }
        if let filter, !kinds.contains(where: { $0.kind == filter }) { self.filter = nil }
        let matching = reply.providers.filter { (filter == nil || $0.provider == filter) && Self.matches($0, query) }
        let ordered = order == .urgency ? UsageMath.byUrgency(matching, lowThreshold: config.lowThreshold) : matching
        for limits in ordered {
            add(UsageAccountCard(limits: limits, figure: figure, lowThreshold: config.lowThreshold, now: now, theme: theme))
        }
        if ordered.isEmpty {
            showPlaceholder("No accounts match the filter.", detail: "Try another provider or search.", icon: .search)
            // Kept, so the message is not built again until the inputs change.
            shown = next
        }
    }

    /// Whether the filter's text appears in the account's name, provider, plan or address.
    static func matches(_ limits: AgentUsageLimits, _ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [limits.providerName, UsageAccountCard.providerTitle(limits.provider), limits.plan, limits.account]
            .contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                    constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
    }
}

// MARK: - Views

/// A view that runs `onClick` when clicked, with a pointing hand.
@MainActor
class UsageClickable: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// One account on a plain card: its logo, name and plan
/// with the account on the right, then every limit the account reports.
@MainActor
final class UsageAccountCard: NSView {
    /// The card's padding, as the tab cards pad theirs.
    static let insets = NSEdgeInsets(top: Metrics.border + 10, left: Metrics.border + 10,
                                     bottom: Metrics.border + 10, right: Metrics.border + 10)

    let limits: AgentUsageLimits
    /// The limit rows, in the order the provider reports them.
    private(set) var rows: [UsageLimitRow] = []

    /// The provider's short name: "Claude", "Codex", "Antigravity".
    static func providerTitle(_ provider: AgentChatProvider) -> String {
        provider == .claude ? "Claude" : provider.activityProvider.displayName
    }

    init(limits: AgentUsageLimits, figure: UsageConfig.Figure, lowThreshold: Int, now: Date, theme: AppTheme) {
        self.limits = limits
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Metrics.cardRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = theme.rowFill.cgColor

        let name = limits.providerName ?? Self.providerTitle(limits.provider)
        let logo = NSImageView(image: AgentLogo.image(for: limits.provider.activityProvider, size: 16, theme: theme) ?? NSImage())
        logo.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithAttributedString: Self.title(name, plan: limits.plan, theme: theme))
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        title.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var top: [NSView] = [logo, title, spacer]
        if let account = limits.account {
            // An address has no spaces, so it truncates in the middle rather than losing its domain.
            let label = makeLabel(account, font: AppFont.footnote, color: theme.fgMuted)
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            top.append(label)
        }
        let header = NSStackView(views: top)
        header.alignment = .centerY
        header.spacing = Metrics.gutter

        var body: [NSView] = [header]
        if let failure = limits.failure {
            let warning = makeLabel(failure, font: AppFont.footnote, color: theme.warning)
            warning.lineBreakMode = .byWordWrapping
            warning.maximumNumberOfLines = 0
            warning.isSelectable = true
            warning.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            body.append(warning)
        }
        for window in limits.windows {
            let row = UsageLimitRow(window: window, figure: figure, lowThreshold: lowThreshold, now: now, theme: theme)
            rows.append(row)
            body.append(row)
        }
        let column = NSStackView(views: body)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.gutter + 4
        column.setCustomSpacing(Metrics.gutter, after: header)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 16),
            logo.heightAnchor.constraint(equalToConstant: 16),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.insets.left),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.insets.right),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Self.insets.top),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.insets.bottom),
        ])
        for view in body {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }

        toolTip = [limits.account.map { "\(name) · \($0)" } ?? name, "Read \(UsageMath.ago(limits.checkedAt, now: now))"]
            .joined(separator: "\n")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        var spoken = [limits.plan.map { "\(name), \($0)" } ?? name]
        if let account = limits.account { spoken.append(account) }
        if let failure = limits.failure { spoken.append(failure) }
        setAccessibilityLabel(spoken.joined(separator: ". "))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `Side project Pro`: the name in semibold, the plan regular and muted.
    private static func title(_ name: String, plan: String?, theme: AppTheme) -> NSAttributedString {
        let text = NSMutableAttributedString(string: name, attributes: [.font: AppFont.header, .foregroundColor: theme.fg])
        if let plan {
            text.append(NSAttributedString(string: " \(plan)", attributes: [.font: AppFont.body, .foregroundColor: theme.fgMuted]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        return text
    }
}

/// One limit: its name with the figure on the right, its bar with a tick where
/// even spending would be, then `Resets in 4d 22h · ahead of pace`.
@MainActor
final class UsageLimitRow: NSView {
    let usage: AgentUsageWindow
    let tone: UsageTone
    let bar: UsageBarView

    init(window: AgentUsageWindow, figure: UsageConfig.Figure, lowThreshold: Int, now: Date, theme: AppTheme) {
        self.usage = window
        tone = UsageMath.tone(window, lowThreshold: lowThreshold)
        let color = Self.color(tone, theme: theme)
        // Even spending leaves as much of the bar as there is time left in the window.
        let marker = UsageMath.paceRemainingPercent(window, now: now).map { Double(figure == .left ? $0 : 100 - $0) / 100 }
        bar = UsageBarView(fraction: Double(UsageMath.figure(window, figure)) / 100, color: color, marker: marker, theme: theme)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = makeLabel(window.label, font: AppFont.small, color: theme.fg)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let value = makeLabel(Self.figureText(window, figure), font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                              color: tone == .fine ? theme.fg : color)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        value.setContentHuggingPriority(.required, for: .horizontal)
        let line = NSStackView(views: [label, spacer, value])
        line.spacing = Metrics.gutter

        var views: [NSView] = [line, bar]
        if let caption = Self.caption(window, now: now, theme: theme) {
            let detail = NSTextField(labelWithAttributedString: caption)
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if let resetsAt = window.resetsAt { detail.toolTip = "Resets \(UsageMath.exact(resetsAt))" }
            views.append(detail)
        }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in views { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        bar.toolTip = UsageMath.summary(window, now: now)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.spoken(window, figure: figure, lowThreshold: lowThreshold, now: now))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `Resets in 4d 22h · ahead of pace`, the pace in the warning color when ahead.
    private static func caption(_ window: AgentUsageWindow, now: Date, theme: AppTheme) -> NSAttributedString? {
        let text = NSMutableAttributedString()
        let muted: [NSAttributedString.Key: Any] = [.font: AppFont.footnote, .foregroundColor: theme.fgMuted]
        if let resetsIn = UsageMath.resetsIn(window, now: now) {
            text.append(NSAttributedString(string: resetsIn == "now" ? "Resets now" : "Resets in \(resetsIn)", attributes: muted))
        }
        if let pace = UsageMath.pace(window, now: now) {
            if text.length > 0 { text.append(NSAttributedString(string: " · ", attributes: muted)) }
            text.append(NSAttributedString(string: pace.short, attributes: [
                .font: AppFont.footnote, .foregroundColor: pace == .ahead ? theme.warning : theme.fgMuted]))
        }
        return text.length > 0 ? text : nil
    }

    /// `86%`, or `14% left` when the figure is what is left.
    static func figureText(_ window: AgentUsageWindow, _ figure: UsageConfig.Figure) -> String {
        "\(UsageMath.figure(window, figure))%\(figure == .left ? " left" : "")"
    }

    static func spoken(_ window: AgentUsageWindow, figure: UsageConfig.Figure, lowThreshold: Int, now: Date) -> String {
        var parts = ["\(window.label): \(UsageMath.figure(window, figure))% \(figure == .left ? "left" : "used")"]
        if let label = UsageMath.tone(window, lowThreshold: lowThreshold).label { parts.append(label) }
        if let resetsAt = window.resetsAt, resetsAt > now {
            parts.append("resets in \(UsageMath.spelledDuration(resetsAt.timeIntervalSince(now)))")
        }
        if let pace = UsageMath.pace(window, now: now) { parts.append(pace.short) }
        return parts.joined(separator: ", ")
    }

    /// Green with room, yellow running low, red almost out or used up.
    static func color(_ tone: UsageTone, theme: AppTheme) -> NSColor {
        switch tone {
        case .fine: return theme.success
        case .low: return theme.warning
        case .almostOut, .over: return theme.danger
        }
    }
}

/// A thin rounded bar filled to `fraction` in the limit's status color, with an
/// optional tick at `marker`.
@MainActor
final class UsageBarView: NSView {
    nonisolated static let height: CGFloat = 6
    let fraction: Double
    /// Where even spending would fill the bar to, 0–1.
    let marker: Double?
    private let color: NSColor
    private let track: NSColor
    private let tick: NSColor

    init(fraction: Double, color: NSColor, height: CGFloat = UsageBarView.height, marker: Double? = nil, theme: AppTheme) {
        self.fraction = min(max(fraction, 0), 1)
        self.marker = marker.map { min(max($0, 0), 1) }
        self.color = color
        track = theme.fg(alpha: 0.10)
        tick = theme.fg(alpha: 0.45)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        guard rect.width > 0 else { return }
        let radius = rect.height / 2
        track.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let width = (rect.width * fraction).rounded()
        if width > 0 {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(width, rect.height), height: rect.height),
                         xRadius: radius, yRadius: radius).fill()
        }
        if let marker, marker > 0, marker < 1 {
            tick.setFill()
            NSRect(x: (rect.width * marker).rounded() - 1, y: 0, width: 2, height: rect.height).fill()
        }
    }
}
