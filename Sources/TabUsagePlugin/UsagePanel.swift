import AppKit
import TabApp
import TabClient
import TabCore
import TabProtocol

/// The AI Usage panel: one card per signed-in agent account with its plan, the
/// limit closest to running out and when it resets, the other limits a click
/// away. Filters by provider and orders by urgency, as Headroom does. Reads the
/// current project's server, and again on the configured schedule while it shows.
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
    /// The provider the chips show alone; nil shows every account.
    private(set) var filter: AgentChatProvider?
    private(set) var order = UsageConfig().order
    private(set) var figure = UsageConfig().figure
    /// Cards showing every limit, by account.
    private var expanded = Set<String>()
    private var visible = false
    /// Ticks each minute while the panel shows: updates "7 min ago" and reads again when due.
    private var clock: Timer?

    let toolbar = UsageToolbar()

    private let card = NativePanelCard()
    private let footer = RightSidebarFooter()
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
        refreshButton = footer.addButton(.refresh, label: "Refresh") { [weak self] in self?.refresh(force: true) }
        spinner.isHidden = true
        footer.setSpinner(spinner)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 4, left: RightSidebarFooter.innerInset, bottom: 12,
                                        right: RightSidebarFooter.outerInset)
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
        toolbar.isHidden = true
        toolbar.onFilter = { [weak self] kind in self?.filter = kind; self?.render() }
        toolbar.onOrder = { [weak self] order in self?.order = order; self?.render() }
        toolbar.onFigure = { [weak self] figure in self?.figure = figure; self?.render() }
        card.onColorsChange = { [weak self] in self?.render() }

        for subview in [toolbar, scroll, message, footer] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            toolbar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: RightSidebarFooter.innerInset),
            toolbar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -RightSidebarFooter.outerInset),
            toolbar.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
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
    func show(project: (id: ProjectId, server: ServerId)?) {
        self.project = project
        loadViewIfNeeded()
        render()
        refresh(force: false)
    }

    /// The server came back: what it reported before may be out of date.
    func reconnected(_ server: ServerId) {
        store.clearFailure(for: server)
        if project?.server == server { refresh(force: false) }
    }

    /// Reads the limits again; without `force`, only when the last reading is stale.
    func refresh(force: Bool) {
        guard let project else { return }
        store.refresh(project: project, force: force, resolve: resolve)
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
            showMessage(project == nil ? "Open a project to see AI usage" : "")
        }
        spinner.isHidden = !busy
        refreshButton?.isHidden = busy
        let serverName = project.flatMap { resolve($0.id)?.serverName }
        footer.title = serverName.map { "AI Usage · \($0)" } ?? "AI Usage"

        if case .loading(nil) = load { showMessage("Loading…") }
        guard let reply else { return }
        if reply.providers.isEmpty {
            showMessage("Add a provider in Settings › Agents to see your plan limits.")
            return
        }
        message.isHidden = true
        scroll.isHidden = false
        toolbar.isHidden = false
        populate(reply)
    }

    private func showMessage(_ text: String) {
        message.set(text)
        message.isHidden = text.isEmpty
        scroll.isHidden = true
        toolbar.isHidden = true
    }

    private func populate(_ reply: AgentUsageLimitsReply) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let now = Date()
        var kinds: [AgentChatProvider] = []
        for limits in reply.providers where !kinds.contains(limits.provider) { kinds.append(limits.provider) }
        if let filter, !kinds.contains(filter) { self.filter = nil }
        toolbar.update(kinds: kinds.map { kind in (kind, reply.providers.filter { $0.provider == kind }.count) },
                       total: reply.providers.count, filter: filter, order: order, figure: figure, theme: theme)
        let shown = reply.providers.filter { filter == nil || $0.provider == filter }
        let ordered = order == .urgency ? UsageMath.byUrgency(shown, lowThreshold: config.lowThreshold) : shown
        for limits in ordered {
            let key = Self.key(limits)
            let card = UsageAccountCard(limits: limits, figure: figure, lowThreshold: config.lowThreshold,
                                        expanded: expanded.contains(key), now: now, theme: theme)
            card.onToggle = { [weak self] in
                guard let self else { return }
                if self.expanded.remove(key) == nil { self.expanded.insert(key) }
                self.render()
            }
            add(card)
        }
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                    constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
    }

    /// Which account a card shows, kept across readings so an open card stays open.
    private static func key(_ limits: AgentUsageLimits) -> String {
        limits.providerId ?? limits.provider.rawValue
    }

    /// Each provider's mark color, or the foreground for gray marks such as Codex's.
    static func color(_ provider: AgentChatProvider, theme: AppTheme) -> NSColor {
        guard let hue = AgentLogo.mark(provider.activityProvider).signatureHue, hue != .gray else { return theme.fg }
        return theme.iconColor(hue)
    }
}

// MARK: - Views

/// The filter chips and the order and figure switches above the cards.
@MainActor
final class UsageToolbar: NSView {
    var onFilter: ((AgentChatProvider?) -> Void)?
    var onOrder: ((UsageConfig.Order) -> Void)?
    var onFigure: ((UsageConfig.Figure) -> Void)?

    private let chips = NSStackView()
    private let chipScroll = NSScrollView()
    private let switches = NSStackView()
    /// The chips shown now, for tests.
    private(set) var chipTitles: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        chips.orientation = .horizontal
        chips.spacing = 6
        chips.translatesAutoresizingMaskIntoConstraints = false
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(chips)
        chipScroll.documentView = documentView
        chipScroll.drawsBackground = false
        chipScroll.hasHorizontalScroller = false
        chipScroll.hasVerticalScroller = false
        chipScroll.horizontalScrollElasticity = .allowed
        chipScroll.verticalScrollElasticity = .none
        chipScroll.translatesAutoresizingMaskIntoConstraints = false
        switches.orientation = .horizontal
        switches.spacing = 8
        switches.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chipScroll)
        addSubview(switches)
        NSLayoutConstraint.activate([
            chips.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            chips.topAnchor.constraint(equalTo: documentView.topAnchor),
            chips.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.trailingAnchor.constraint(equalTo: chips.trailingAnchor),
            documentView.heightAnchor.constraint(equalTo: chipScroll.contentView.heightAnchor),
            chipScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            chipScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            chipScroll.topAnchor.constraint(equalTo: topAnchor),
            chipScroll.heightAnchor.constraint(equalToConstant: UsageChip.height),
            switches.leadingAnchor.constraint(equalTo: leadingAnchor),
            switches.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            switches.topAnchor.constraint(equalTo: chipScroll.bottomAnchor, constant: 8),
            switches.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(kinds: [(AgentChatProvider, Int)], total: Int, filter: AgentChatProvider?,
                order: UsageConfig.Order, figure: UsageConfig.Figure, theme: AppTheme) {
        for view in chips.arrangedSubviews + switches.arrangedSubviews { view.removeFromSuperview() }
        var all = UsageChip(title: "All", count: total, logo: nil, selected: filter == nil, theme: theme)
        all.onClick = { [weak self] in self?.onFilter?(nil) }
        chips.addArrangedSubview(all)
        chipTitles = ["All"]
        for (kind, count) in kinds {
            all = UsageChip(title: UsageAccountCard.providerTitle(kind), count: count,
                            logo: AgentLogo.mark(kind.activityProvider), selected: filter == kind, theme: theme)
            all.onClick = { [weak self] in self?.onFilter?(filter == kind ? nil : kind) }
            chips.addArrangedSubview(all)
            chipTitles.append(UsageAccountCard.providerTitle(kind))
        }
        let orders = UsageSegments(titles: ["By urgency", "By provider"], selected: order == .urgency ? 0 : 1, theme: theme)
        orders.onSelect = { [weak self] index in self?.onOrder?(index == 0 ? .urgency : .provider) }
        orders.setAccessibilityLabel("Order")
        let figures = UsageSegments(titles: ["Left", "Used"], selected: figure == .left ? 0 : 1, theme: theme)
        figures.onSelect = { [weak self] index in self?.onFigure?(index == 0 ? .left : .used) }
        figures.setAccessibilityLabel("Show")
        switches.addArrangedSubview(orders)
        switches.addArrangedSubview(figures)
    }
}

/// A scroll view's document that lays out from the top left.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

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

/// A rounded chip: `All 13`, or a provider's mark, name and account count.
@MainActor
final class UsageChip: UsageClickable {
    static let height: CGFloat = 30

    init(title: String, count: Int, logo: AppIcon?, selected: Bool, theme: AppTheme) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.borderWidth = 1
        layer?.borderColor = theme.fg(alpha: selected ? 0.16 : 0.09).cgColor
        layer?.backgroundColor = (selected ? theme.fg(alpha: 0.10) : .clear).cgColor
        var views: [NSView] = []
        if let logo {
            let icon = NSImageView(image: logo.image(size: 14, theme: theme) ?? NSImage())
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
            views.append(icon)
        }
        views.append(makeLabel(title, font: selected ? AppFont.bodyMedium : AppFont.body, color: theme.fg))
        views.append(makeLabel("\(count)", font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular), color: theme.fgMuted))
        let row = NSStackView(views: views)
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(title), \(count)")
        setAccessibilityValue(selected ? "selected" : nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A pill of choices with the chosen one raised, such as `By urgency | By provider`.
@MainActor
final class UsageSegments: NSView {
    var onSelect: ((Int) -> Void)?
    private(set) var selected: Int

    init(titles: [String], selected: Int, theme: AppTheme) {
        self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = UsageChip.height / 2
        layer?.backgroundColor = theme.fg(alpha: 0.06).cgColor
        let row = NSStackView()
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        for (index, title) in titles.enumerated() {
            let segment = UsageClickable()
            segment.translatesAutoresizingMaskIntoConstraints = false
            segment.wantsLayer = true
            segment.layer?.cornerRadius = (UsageChip.height - 6) / 2
            segment.layer?.backgroundColor = (index == selected ? theme.fg(alpha: 0.12) : .clear).cgColor
            let label = makeLabel(title, font: index == selected ? AppFont.bodyMedium : AppFont.body,
                                  color: index == selected ? theme.fg : theme.fgMuted)
            segment.addSubview(label)
            NSLayoutConstraint.activate([
                segment.heightAnchor.constraint(equalToConstant: UsageChip.height - 6),
                label.leadingAnchor.constraint(equalTo: segment.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: segment.trailingAnchor, constant: -10),
                label.centerYAnchor.constraint(equalTo: segment.centerYAnchor),
            ])
            segment.onClick = { [weak self] in self?.onSelect?(index) }
            segment.setAccessibilityElement(true)
            segment.setAccessibilityRole(.radioButton)
            segment.setAccessibilityLabel(title)
            segment.setAccessibilityValue(index == selected ? 1 : 0)
            row.addArrangedSubview(segment)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: UsageChip.height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// One account: who it is and on which plan, when it was read, and its tightest
/// limit with how close it is and when it resets. Expanded, every limit.
@MainActor
final class UsageAccountCard: UsageClickable {
    let limits: AgentUsageLimits
    let expanded: Bool
    /// The limit rows shown now, the headline first.
    private(set) var rows: [UsageLimitRow] = []
    var onToggle: (() -> Void)?

    /// The provider's short name: "Claude", "Codex", "Antigravity".
    static func providerTitle(_ provider: AgentChatProvider) -> String {
        provider == .claude ? "Claude" : provider.activityProvider.displayName
    }

    init(limits: AgentUsageLimits, figure: UsageConfig.Figure, lowThreshold: Int, expanded: Bool, now: Date,
         theme: AppTheme) {
        self.limits = limits
        self.expanded = expanded
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = theme.fg(alpha: 0.09).cgColor
        layer?.backgroundColor = theme.fg(alpha: 0.025).cgColor
        onClick = { [weak self] in self?.onToggle?() }

        let provider = Self.providerTitle(limits.provider)
        let name = limits.providerName ?? provider
        let title = NSTextField(labelWithAttributedString: Self.title(name, plan: limits.plan, theme: theme))
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // An address has no spaces, so let it wrap after its `@` rather than mid-word.
        let account = limits.account?.replacingOccurrences(of: "@", with: "@\u{200B}")
        let subtitleText = [limits.providerName == nil ? nil : provider, account].compactMap { $0 }.joined(separator: " · ")
        let subtitle = makeLabel(subtitleText, font: AppFont.small, color: theme.fgMuted)
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        subtitle.cell?.truncatesLastVisibleLine = true
        subtitle.toolTip = limits.account
        subtitle.isHidden = subtitleText.isEmpty
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let names = NSStackView(views: [title, subtitle])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 2

        let logo = NSImageView(image: AgentLogo.mark(limits.provider.activityProvider).image(size: 20, theme: theme) ?? NSImage())
        logo.translatesAutoresizingMaskIntoConstraints = false

        let fresh = limits.failure == nil && now.timeIntervalSince(limits.checkedAt) < 30 * 60
        let dot = UsageDot(color: limits.failure != nil ? theme.danger : fresh ? theme.success : theme.fgMuted)
        let ago = NSTextField(labelWithAttributedString: Self.dotted(UsageMath.ago(limits.checkedAt, now: now),
                                                                     font: AppFont.small, color: theme.fgMuted))
        ago.toolTip = "Read \(UsageMath.exact(limits.checkedAt))"
        ago.lineBreakMode = .byClipping
        ago.maximumNumberOfLines = 1
        ago.setContentCompressionResistancePriority(.required, for: .horizontal)
        let chevron = ChromeButton(expanded ? .chevronUp : .chevronDown, label: expanded ? "Hide details" : "Show details",
                                   side: 22, glyph: 14) { [weak self] _ in self?.onToggle?() }
        let status = NSStackView(views: [dot, ago, chevron])
        status.spacing = 6
        status.setCustomSpacing(4, after: ago)
        status.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = NSStackView(views: [logo, names, status])
        header.alignment = .centerY
        names.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.spacing = 12
        header.setCustomSpacing(8, after: names)

        var body: [NSView] = [header]
        let headline = UsageMath.headline(limits)
        if let headline {
            let row = UsageLimitRow(window: headline, figure: figure, lowThreshold: lowThreshold, now: now,
                                    detailed: false, theme: theme)
            rows.append(row)
            body.append(row)
        }
        if let failure = limits.failure {
            let warning = makeLabel(failure, font: AppFont.small, color: theme.warning)
            warning.lineBreakMode = .byWordWrapping
            warning.maximumNumberOfLines = 0
            warning.isSelectable = true
            warning.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            body.append(warning)
        }
        if expanded {
            for window in limits.windows where window.id != headline?.id {
                let row = UsageLimitRow(window: window, figure: figure, lowThreshold: lowThreshold, now: now,
                                        detailed: true, theme: theme)
                rows.append(row)
                body.append(row)
            }
            if let first = rows.first, let sentence = UsageMath.paceSentence(first.usage, now: now) {
                first.addPace(sentence, theme: theme)
            }
            let read = makeLabel("Read \(UsageMath.exact(limits.checkedAt)) from the \(limits.provider.name) CLI",
                                 font: AppFont.footnote, color: theme.fgMuted)
            body.append(read)
        }
        let column = NSStackView(views: body)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 20),
            logo.heightAnchor.constraint(equalToConstant: 20),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        for view in body.dropFirst() {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -4).isActive = true
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        var spoken = [limits.plan.map { "\(name), \($0)" } ?? name]
        if let headline { spoken.append(UsageLimitRow.spoken(headline, figure: figure, lowThreshold: lowThreshold, now: now)) }
        if let failure = limits.failure { spoken.append(failure) }
        setAccessibilityLabel(spoken.joined(separator: ". "))
        setAccessibilityHelp(expanded ? "Hides the other limits" : "Shows every limit")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `Side project · Pro`, the plan in the muted color.
    private static func title(_ name: String, plan: String?, theme: AppTheme) -> NSAttributedString {
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: theme.fg])
        if let plan {
            text.append(NSAttributedString(string: " · \(plan)", attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: theme.fgMuted]))
        }
        return text
    }

    /// Text with a dotted underline, which hovers to the exact value.
    static func dotted(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .underlineColor: color.withAlphaComponent(0.6),
            .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue])
    }
}

/// The freshness dot beside "7 min ago".
@MainActor
final class UsageDot: NSView {
    init(color: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 3.5
        layer?.backgroundColor = color.cgColor
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 7), heightAnchor.constraint(equalToConstant: 7)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// One limit: `86% Weekly` with its status, the bar, and `Resets in 3 days 12 h`.
@MainActor
final class UsageLimitRow: NSView {
    let usage: AgentUsageWindow
    let tone: UsageTone
    let bar: UsageBarView
    private let column = NSStackView()

    init(window: AgentUsageWindow, figure: UsageConfig.Figure, lowThreshold: Int, now: Date, detailed: Bool,
         theme: AppTheme) {
        self.usage = window
        tone = UsageMath.tone(window, lowThreshold: lowThreshold)
        let color = Self.color(tone, theme: theme)
        bar = UsageBarView(fraction: Double(UsageMath.figure(window, figure)) / 100, color: color, theme: theme)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let figureText = NSMutableAttributedString(string: "\(UsageMath.figure(window, figure))%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: detailed ? 13 : 14, weight: .semibold), .foregroundColor: theme.fg])
        figureText.append(NSAttributedString(string: "  \(window.label)\(figure == .left ? " left" : "")", attributes: [
            .font: detailed ? AppFont.small : AppFont.body, .foregroundColor: theme.fgMuted]))
        let figureLabel = NSTextField(labelWithAttributedString: figureText)
        figureLabel.lineBreakMode = .byTruncatingTail
        figureLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var top: [NSView] = [figureLabel]
        if let label = tone.label {
            let status = makeLabel(label, font: detailed ? AppFont.footnoteMedium : AppFont.bodyMedium, color: color)
            status.setContentCompressionResistancePriority(.required, for: .horizontal)
            top.append(status)
        }
        let topRow = NSStackView(views: top)
        topRow.distribution = .fill
        topRow.spacing = 8
        if top.count > 1 { topRow.setHuggingPriority(.defaultLow, for: .horizontal) }

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(topRow)
        column.addArrangedSubview(bar)
        if let resetsAt = window.resetsAt {
            let line = NSMutableAttributedString(string: "Resets in ", attributes: [
                .font: AppFont.small, .foregroundColor: theme.fgMuted])
            let interval = resetsAt.timeIntervalSince(now)
            if interval > 0 {
                line.append(UsageAccountCard.dotted(UsageMath.spelledDuration(interval), font: AppFont.small, color: theme.fgMuted))
            } else {
                line.setAttributedString(NSAttributedString(string: "Resetting now", attributes: [
                    .font: AppFont.small, .foregroundColor: theme.fgMuted]))
            }
            let reset = NSTextField(labelWithAttributedString: line)
            reset.toolTip = "Resets \(UsageMath.exact(resetsAt))"
            column.addArrangedSubview(reset)
        }
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            topRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            bar.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.spoken(window, figure: figure, lowThreshold: lowThreshold, now: now))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Adds what the pace means under the reset line.
    func addPace(_ sentence: String, theme: AppTheme) {
        column.addArrangedSubview(makeLabel(sentence, font: AppFont.small, color: theme.fgMuted))
    }

    static func spoken(_ window: AgentUsageWindow, figure: UsageConfig.Figure, lowThreshold: Int, now: Date) -> String {
        var parts = ["\(window.label): \(UsageMath.figure(window, figure))% \(figure == .left ? "left" : "used")"]
        if let label = UsageMath.tone(window, lowThreshold: lowThreshold).label { parts.append(label) }
        if let resetsAt = window.resetsAt, resetsAt > now {
            parts.append("resets in \(UsageMath.spelledDuration(resetsAt.timeIntervalSince(now)))")
        }
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

/// A thin rounded bar filled to `fraction` in the limit's status color.
@MainActor
final class UsageBarView: NSView {
    nonisolated static let height: CGFloat = 6
    let fraction: Double
    private let color: NSColor
    private let track: NSColor

    init(fraction: Double, color: NSColor, height: CGFloat = UsageBarView.height, theme: AppTheme) {
        self.fraction = min(max(fraction, 0), 1)
        self.color = color
        track = theme.fg(alpha: 0.10)
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
        guard width > 0 else { return }
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(width, rect.height), height: rect.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}
