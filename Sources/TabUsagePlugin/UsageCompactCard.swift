import AppKit
import TabApp
import TabClient
import TabCore
import TabProtocol

/// Shared cached usage readings per server, observed by both the right-sidebar
/// panel and the left-sidebar floating card.
@MainActor
final class UsageStore {
    enum Load {
        case loading(previous: AgentUsageLimitsReply?)
        case loaded(AgentUsageLimitsReply, at: Date)
        case failed(String)
    }

    /// How long a reading shows before showing a surface asks again.
    static let freshness: TimeInterval = 60

    private struct Listener {
        weak var owner: AnyObject?
        let notify: @MainActor (ServerId) -> Void
    }

    private(set) var loads: [ServerId: Load] = [:]
    private var listeners: [Listener] = []

    func load(for server: ServerId) -> Load? {
        loads[server]
    }

    func observe(owner: AnyObject, _ handler: @escaping @MainActor (ServerId) -> Void) {
        listeners.removeAll { $0.owner == nil || $0.owner === owner }
        listeners.append(Listener(owner: owner, notify: handler))
    }

    func clearFailure(for server: ServerId) {
        if case .failed = loads[server] {
            loads[server] = nil
            notify(server)
        }
    }

    func refresh(project: (id: ProjectId, server: ServerId), force: Bool, resolve: UsagePanelController.Resolve) {
        let server = project.server
        var previous: AgentUsageLimitsReply?
        switch loads[server] {
        case .loading:
            return
        case .loaded(let reply, let at):
            if !force, Date().timeIntervalSince(at) < Self.freshness { return }
            previous = reply
        case .failed, nil:
            break
        }
        guard let client = resolve(project.id)?.client else {
            loads[server] = .failed("Connecting to the server…")
            notify(server)
            return
        }
        loads[server] = .loading(previous: previous)
        notify(server)
        Task { [weak self] in
            let load: Load
            do {
                load = .loaded(try await client.agentUsageLimits(.init(forceRefresh: force)), at: Date())
            } catch let error as ClientError {
                if case .server(let reply) = error, reply.code == .unsupported {
                    load = .failed("This server's Tab is too old to report AI usage. Update it to see your limits.")
                } else {
                    load = previous.map { .loaded($0, at: .distantPast) } ?? .failed(NativeErrors.friendly(error, folder: false))
                }
            } catch {
                load = previous.map { .loaded($0, at: .distantPast) } ?? .failed(NativeErrors.friendly(error, folder: false))
            }
            guard let self else { return }
            self.loads[server] = load
            self.notify(server)
        }
    }

    private func notify(_ server: ServerId) {
        listeners.removeAll { $0.owner == nil }
        for listener in listeners {
            listener.notify(server)
        }
    }
}

/// Compressed floating card anchored at the bottom of the left sidebar:
/// one compact row per signed-in account with its logo, name, headline figure,
/// reset countdown, and thin status bar. A row opens the AI Usage panel.
@MainActor
final class UsageCompactCardController: NSViewController {
    private let theme: AppTheme
    private let store: UsageStore
    private let resolve: UsagePanelController.Resolve
    private let onOpenPanel: (() -> Void)?

    var onPreferredSizeChange: (() -> Void)?

    private var project: (id: ProjectId, server: ServerId)?
    private(set) var config = UsageConfig()
    private var visible = false
    private var clock: Timer?

    private let root = ThemedView()
    private let scroll = ScrollView()
    private let stack = NSStackView()
    private let messageLabel = makeLabel("", font: AppFont.small)

    private static let rowSpacing: CGFloat = 8
    /// The tab cards' padding: a border and 8pt above and below, 10pt to the sides.
    private static let stackInsets = NSEdgeInsets(top: Metrics.border + 8, left: Metrics.border + 10,
                                                  bottom: Metrics.border + 8, right: Metrics.border + 10)

    init(
        theme: AppTheme,
        store: UsageStore? = nil,
        onOpenPanel: (() -> Void)? = nil,
        resolve: @escaping UsagePanelController.Resolve
    ) {
        self.theme = theme
        let store = store ?? UsageStore()
        self.store = store
        self.onOpenPanel = onOpenPanel
        self.resolve = resolve
        super.init(nibName: nil, bundle: nil)
        store.observe(owner: self) { [weak self] server in
            guard let self, self.project?.server == server else { return }
            self.render()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        root.theme = theme
        root.onColorsChange = { [weak self] in self?.render() }
        view = root

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.rowSpacing
        stack.edgeInsets = Self.stackInsets
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.content.bottomAnchor),
        ])
        scroll.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.isHidden = true

        for subview in [scroll, messageLabel] as [NSView] {
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.stackInsets.left),
            messageLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.stackInsets.right),
            messageLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        root.setAccessibilityLabel("AI Usage Summary")
        render()
    }

    /// The compact account rows shown now.
    var rows: [UsageCompactRow] { stack.arrangedSubviews.compactMap { $0 as? UsageCompactRow } }
    /// The message text when no rows are shown.
    var messageText: String { messageLabel.isHidden ? "" : messageLabel.stringValue }

    func apply(_ next: UsageConfig) {
        let previous = config
        config = next
        if next.refreshMinutes != previous.refreshMinutes { tick() }
        render()
    }

    /// Limits belong to the server, so another project on the same one keeps the rows.
    func show(project: (id: ProjectId, server: ServerId)?) {
        let sameServer = isViewLoaded && project != nil && project?.server == self.project?.server
        self.project = project
        if sameServer { return }
        loadViewIfNeeded()
        render()
        refresh(force: false)
    }

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

    func reconnected(_ server: ServerId) {
        store.clearFailure(for: server)
        if project?.server == server { refresh(force: false) }
    }

    func refresh(force: Bool) {
        guard let project else { return }
        store.refresh(project: project, force: force, resolve: resolve)
    }

    func tick() {
        guard visible, let project else { return }
        if config.refreshMinutes > 0, case .loaded(_, let at) = store.load(for: project.server),
           Date().timeIntervalSince(at) >= TimeInterval(config.refreshMinutes * 60) - 5 {
            refresh(force: true)
        } else {
            render()
        }
    }

    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        loadViewIfNeeded()
        let insets = Self.stackInsets.top + Self.stackInsets.bottom
        if !messageLabel.isHidden {
            let textWidth = max(width - Self.stackInsets.left - Self.stackInsets.right, 80)
            let rect = (messageLabel.stringValue as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: AppFont.small]
            )
            return insets + max(ceil(rect.height), 16)
        }
        let count = rows.count
        guard count > 0 else { return insets + 16 }
        let rowsHeight = rows.reduce(CGFloat(0)) { $0 + $1.compactHeight }
        let gaps = CGFloat(max(count - 1, 0)) * Self.rowSpacing
        return insets + rowsHeight + gaps
    }

    // MARK: Rendering

    private func render() {
        guard isViewLoaded else { return }
        messageLabel.textColor = theme.fgMuted

        let load = project.flatMap { store.load(for: $0.server) }
        let reply: AgentUsageLimitsReply?
        switch load {
        case .loading(let previous):
            reply = previous
        case .loaded(let loaded, _):
            reply = loaded
        case .failed(let reason):
            reply = nil
            showMessage(reason)
        case nil:
            reply = nil
            showMessage(project == nil ? "Open a project to see AI usage" : "")
        }

        if case .loading(nil) = load { showMessage("Loading…") }
        guard let reply else {
            onPreferredSizeChange?()
            return
        }
        if reply.providers.isEmpty {
            showMessage("Sign in to Claude Code, Codex, Antigravity, OpenCode or Grok to see your limits.")
            onPreferredSizeChange?()
            return
        }
        messageLabel.isHidden = true
        scroll.isHidden = false
        populate(reply)
        onPreferredSizeChange?()
    }

    private func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = text.isEmpty
        scroll.isHidden = true
    }

    private func populate(_ reply: AgentUsageLimitsReply) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let now = Date()
        let ordered = config.order == .urgency
            ? UsageMath.byUrgency(reply.providers, lowThreshold: config.lowThreshold)
            : reply.providers
        for limits in ordered {
            let row = UsageCompactRow(
                limits: limits,
                figure: config.figure,
                lowThreshold: config.lowThreshold,
                now: now,
                theme: theme
            )
            row.onClick = { [weak self] in self?.onOpenPanel?() }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(
                equalTo: stack.widthAnchor,
                constant: -(Self.stackInsets.left + Self.stackInsets.right)
            ).isActive = true
        }
    }
}

/// One compressed account row in the left-sidebar floating card:
/// provider logo, account name, headline figure & reset countdown, and a 4pt status bar.
@MainActor
final class UsageCompactRow: UsageClickable {
    let limits: AgentUsageLimits
    let headline: AgentUsageWindow?
    let tone: UsageTone?
    let bar: UsageBarView?
    let compactHeight: CGFloat

    init(
        limits: AgentUsageLimits,
        figure: UsageConfig.Figure,
        lowThreshold: Int,
        now: Date,
        theme: AppTheme
    ) {
        self.limits = limits
        let headline = UsageMath.headline(limits)
        self.headline = headline
        let tone = headline.map { UsageMath.tone($0, lowThreshold: lowThreshold) }
        self.tone = tone
        if let headline, let tone {
            bar = UsageBarView(
                fraction: Double(UsageMath.figure(headline, figure)) / 100,
                color: UsageLimitRow.color(tone, theme: theme),
                height: 4,
                theme: theme
            )
            compactHeight = 32
        } else {
            bar = nil
            compactHeight = limits.failure == nil ? 20 : 34
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let logo = NSImageView(image: AgentLogo.mark(limits.provider.activityProvider).image(size: 14, theme: theme) ?? NSImage())
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 14),
            logo.heightAnchor.constraint(equalToConstant: 14),
        ])

        let provider = UsageAccountCard.providerTitle(limits.provider)
        let name = limits.providerName ?? provider
        let nameLabel = makeLabel(name, font: AppFont.system(12, weight: .medium), color: theme.fg)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var topViews: [NSView] = [logo, nameLabel]
        if let headline, let tone {
            let valueColor = tone == .fine ? theme.fg : UsageLimitRow.color(tone, theme: theme)
            let value = NSMutableAttributedString(
                string: "\(UsageMath.figure(headline, figure))%\(figure == .left ? " left" : "")",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                    .foregroundColor: valueColor,
                ]
            )
            if let resetsIn = UsageMath.resetsIn(headline, now: now) {
                value.append(NSAttributedString(
                    string: " · \(resetsIn)",
                    attributes: [.font: AppFont.footnote, .foregroundColor: theme.fgMuted]
                ))
            }
            let metric = NSTextField(labelWithAttributedString: value)
            metric.lineBreakMode = .byClipping
            metric.maximumNumberOfLines = 1
            metric.setContentHuggingPriority(.required, for: .horizontal)
            metric.setContentCompressionResistancePriority(.required, for: .horizontal)
            topViews.append(metric)
        } else if limits.failure != nil {
            let badge = makeLabel("Unavailable", font: AppFont.footnote, color: theme.warning)
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            topViews.append(badge)
        }

        let topRow = NSStackView(views: topViews)
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 6
        topRow.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var body: [NSView] = [topRow]
        if let bar {
            body.append(bar)
        } else if let failure = limits.failure {
            let detail = makeLabel(failure, font: AppFont.footnote, color: theme.warning)
            detail.lineBreakMode = .byTruncatingTail
            detail.maximumNumberOfLines = 1
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            body.append(detail)
        }

        let column = NSStackView(views: body)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            topRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        for subview in body.dropFirst() {
            subview.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }

        var tipParts = [limits.plan.map { "\(name) · \($0)" } ?? name]
        if let account = limits.account { tipParts.append(account) }
        if let headline { tipParts.append(UsageMath.summary(headline, now: now)) }
        if let failure = limits.failure { tipParts.append(failure) }
        toolTip = tipParts.joined(separator: "\n")

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        var spoken = [limits.plan.map { "\(name), \($0)" } ?? name]
        if let headline { spoken.append(UsageLimitRow.spoken(headline, figure: figure, lowThreshold: lowThreshold, now: now)) }
        if let failure = limits.failure { spoken.append(failure) }
        setAccessibilityLabel(spoken.joined(separator: ". "))
        setAccessibilityHelp("Opens the AI Usage panel")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
