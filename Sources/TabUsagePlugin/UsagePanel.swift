import AppKit
import TabApp
import TabClient
import TabCore
import TabProtocol

/// The AI Usage panel: each signed-in agent's plan windows as cards with a
/// bar of what is left, a pace mark and the time to the next reset, as in
/// T3 Code's Usage › Limits view. Reads the current project's server.
@MainActor
final class UsagePanelController: NSViewController {
    /// The side connection and, for a remote server, its name.
    typealias Resolve = @MainActor (ProjectId) -> (client: ServerAPI?, serverName: String?)?

    private enum Load {
        case loading(previous: AgentUsageLimitsReply?)
        case loaded(AgentUsageLimitsReply, at: Date)
        case failed(String)
    }

    /// How long a reading shows before showing the panel asks again.
    static let freshness: TimeInterval = 60

    private let resolve: Resolve
    private let theme: AppTheme
    private var project: (id: ProjectId, server: ServerId)?
    private var loads: [ServerId: Load] = [:]

    private let card = NativePanelCard()
    private let footer = RightSidebarFooter()
    private let spinner = Spinner()
    private var refreshButton: ChromeButton?
    private let scroll = ScrollView()
    private let stack = NSStackView()
    private let message = NativeMessageView()

    init(theme: AppTheme, resolve: @escaping Resolve) {
        self.theme = theme
        self.resolve = resolve
        super.init(nibName: nil, bundle: nil)
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
        stack.spacing = 8
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

    /// Shows the limits of `project`'s server, reading them when they are stale.
    func show(project: (id: ProjectId, server: ServerId)?) {
        self.project = project
        loadViewIfNeeded()
        render()
        refresh(force: false)
    }

    /// The server came back: what it reported before may be out of date.
    func reconnected(_ server: ServerId) {
        guard case .failed = loads[server] else {
            if project?.server == server { refresh(force: false) }
            return
        }
        loads[server] = nil
        if project?.server == server { refresh(force: false) }
    }

    /// Reads the limits again; without `force`, only when the last reading is stale.
    func refresh(force: Bool) {
        guard let project else { return }
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
            render()
            return
        }
        loads[server] = .loading(previous: previous)
        render()
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
            if self.project?.server == server { self.render() }
        }
    }

    /// The window cards shown now.
    var cards: [UsageWindowCard] { stack.arrangedSubviews.compactMap { $0 as? UsageWindowCard } }
    /// The warnings shown now.
    var warnings: [String] { stack.arrangedSubviews.compactMap { ($0 as? UsageWarningBanner)?.label.stringValue } }
    /// The centered message, when one shows.
    var messageText: String { message.isHidden ? "" : message.text }

    // MARK: Rendering

    private func render() {
        guard isViewLoaded else { return }
        let load = project.flatMap { loads[$0.server] }
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
            showMessage("Sign in to Claude Code or Codex on this computer to see your plan limits.")
            return
        }
        message.isHidden = true
        scroll.isHidden = false
        populate(reply)
    }

    private func showMessage(_ text: String) {
        message.set(text)
        message.isHidden = text.isEmpty
        scroll.isHidden = true
    }

    private func populate(_ reply: AgentUsageLimitsReply) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let now = Date()
        var failures: [(AgentChatProvider, String)] = []
        for limits in reply.providers {
            if let failure = limits.failure { failures.append((limits.provider, failure)) }
            guard !limits.windows.isEmpty else { continue }
            if stack.arrangedSubviews.count > 0 { stack.setCustomSpacing(16, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1]) }
            add(UsageProviderHeader(provider: limits.provider, theme: theme))
            for window in limits.windows {
                add(UsageWindowCard(window: window, color: Self.color(limits.provider, theme: theme), now: now, theme: theme))
            }
        }
        for (provider, failure) in failures {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(16, after: last) }
            add(UsageWarningBanner(text: "\(provider.name): \(failure)", theme: theme))
        }
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                    constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
    }

    /// Each provider's bar color: Claude's orange, the foreground for Codex.
    static func color(_ provider: AgentChatProvider, theme: AppTheme) -> NSColor {
        provider == .claude ? theme.iconColor(.orange) : theme.fg
    }
}

// MARK: - Views

/// The provider's logo and name above its cards.
@MainActor
final class UsageProviderHeader: ThemedView {
    private let icon = NSImageView()
    private let label: NSTextField
    private let provider: AgentChatProvider

    init(provider: AgentChatProvider, theme: AppTheme) {
        self.provider = provider
        label = makeLabel(provider == .claude ? "Claude" : provider.name, font: AppFont.bodyMedium)
        super.init(frame: .zero)
        self.theme = theme
        translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [icon, label])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        themeDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func themeDidChange() {
        let logo: AppIcon = provider == .claude ? .claude : .codex
        icon.image = logo.image(size: 16, theme: theme)
        icon.contentTintColor = theme.fg
        label.textColor = theme.fg
    }
}

/// One window: its name, the percentage left with a pace mark, and its bar.
@MainActor
final class UsageWindowCard: ThemedView {
    let usage: AgentUsageWindow
    private let title: NSTextField
    private let percent: NSTextField
    private let left = makeLabel("left", font: AppFont.body)
    private let paceIcon = NSImageView()
    private let pace: UsagePace?
    let bar: UsageBarView

    init(window: AgentUsageWindow, color: NSColor, now: Date, theme: AppTheme) {
        self.usage = window
        title = makeLabel(window.label, font: AppFont.bodyMedium)
        percent = makeLabel("\(UsageMath.remainingPercent(window))%",
                            font: NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold))
        pace = UsageMath.pace(window, now: now)
        bar = UsageBarView(window: window, color: color, now: now)
        super.init(frame: .zero)
        self.theme = theme
        bar.theme = theme
        translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        paceIcon.toolTip = pace?.label
        paceIcon.setAccessibilityLabel(pace?.label)
        paceIcon.isHidden = pace == nil

        let figures = NSStackView(views: [percent, left, paceIcon])
        figures.alignment = .firstBaseline
        figures.spacing = 6
        figures.setCustomSpacing(8, after: percent)
        let column = NSStackView(views: [title, figures, bar])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.setCustomSpacing(10, after: figures)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            paceIcon.widthAnchor.constraint(equalToConstant: 14),
            paceIcon.heightAnchor.constraint(equalToConstant: 14),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            bar.widthAnchor.constraint(equalTo: column.widthAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(window.label): \(UsageMath.remainingPercent(window))% left")
        themeDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 8
        layer.borderWidth = Metrics.border
        layer.borderColor = theme.rowBorder.cgColor
        layer.backgroundColor = theme.fg.withAlphaComponent(0.02).cgColor
    }

    override func themeDidChange() {
        title.textColor = theme.fg
        percent.textColor = theme.fg
        left.textColor = theme.fgMuted
        let icon: AppIcon? = switch pace {
        case .ahead: .trendingUp
        case .under: .trendingDown
        case .on: .gaugeMedium
        case nil: nil
        }
        paceIcon.image = icon?.image(size: 14, color: theme.fgMuted)
        needsDisplay = true
    }
}

/// The window's bar: what is left in the provider's color, the part a reset
/// restores hatched, a tick where even spending would be, and the countdown.
@MainActor
final class UsageBarView: ThemedView {
    static let height: CGFloat = 24
    private static let radius: CGFloat = 6
    private static let gap: CGFloat = 3

    let usage: AgentUsageWindow
    private let color: NSColor
    let remaining: Int
    /// Where the pace tick sits, as a percentage of the bar from the left.
    let tick: Int?
    let resetsIn: String?

    init(window: AgentUsageWindow, color: NSColor, now: Date) {
        self.usage = window
        self.color = color
        remaining = UsageMath.remainingPercent(window)
        tick = UsageMath.paceRemainingPercent(window, now: now)
        resetsIn = UsageMath.resetsIn(window, now: now)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        let summary = UsageMath.summary(window, now: now)
        toolTip = summary
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("\(window.label): " + summary.replacingOccurrences(of: "\n", with: ", "))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func themeDidChange() {
        needsDisplay = true
    }

    private var tickX: CGFloat? {
        guard let tick, bounds.width >= 6 else { return nil }
        return min(max(bounds.width * CGFloat(tick) / 100, Self.gap), bounds.width - Self.gap).rounded()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        guard rect.width > 0 else { return }
        let fillWidth = (rect.width * CGFloat(remaining) / 100).rounded()

        NSGraphicsContext.saveGraphicsState()
        if let x = tickX {
            let clip = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            clip.append(NSBezierPath(rect: NSRect(x: x - Self.gap, y: rect.minY - 1, width: Self.gap * 2, height: rect.height + 2)))
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        NSBezierPath(roundedRect: rect, xRadius: Self.radius, yRadius: Self.radius).addClip()
        theme.fg.withAlphaComponent(0.06).setFill()
        rect.fill()
        if fillWidth > 0 {
            color.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: fillWidth, height: rect.height),
                         xRadius: Self.radius, yRadius: Self.radius).fill()
        }
        if remaining < 100, usage.resetsAt != nil {
            let hatched = NSRect(x: fillWidth, y: 0, width: rect.width - fillWidth, height: rect.height)
            NSGraphicsContext.saveGraphicsState()
            hatched.clip()
            let stripes = NSBezierPath()
            var x = (hatched.minX / 7).rounded(.down) * 7 - rect.height
            while x < hatched.maxX {
                stripes.move(to: NSPoint(x: x, y: rect.maxY))
                stripes.line(to: NSPoint(x: x + rect.height, y: rect.minY))
                x += 7
            }
            stripes.lineWidth = 1
            color.withAlphaComponent(0.22).setStroke()
            stripes.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()

        if let x = tickX {
            theme.fg.setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 1, y: 2, width: 2, height: rect.height - 4), xRadius: 1, yRadius: 1).fill()
        }
        drawCountdown(in: rect)
    }

    /// The `↻ 4h 53m` pill at the bar's end, left out when the bar is too narrow.
    private func drawCountdown(in rect: NSRect) {
        guard let resetsIn else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let text = NSAttributedString(string: resetsIn, attributes: [.font: font, .foregroundColor: theme.fg])
        let textSize = text.size()
        let iconSide: CGFloat = 11
        let width = (6 + iconSide + 4 + textSize.width + 6).rounded(.up)
        let height = rect.height - 6
        guard rect.width >= width + 24 else { return }
        let pill = NSRect(x: rect.maxX - width - 3, y: 3, width: width, height: height)
        theme.bg.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        if let icon = AppIcon.refresh.image(size: iconSide, color: theme.fg) {
            icon.draw(in: NSRect(x: pill.minX + 6, y: pill.midY - iconSide / 2, width: iconSide, height: iconSide),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        text.draw(at: NSPoint(x: pill.minX + 6 + iconSide + 4, y: pill.midY - textSize.height / 2))
    }
}

/// A provider that could not report its limits, such as a signed-out CLI.
@MainActor
final class UsageWarningBanner: ThemedView {
    private let icon = NSImageView()
    let label: NSTextField

    init(text: String, theme: AppTheme) {
        label = makeLabel(text, font: AppFont.small)
        super.init(frame: .zero)
        self.theme = theme
        translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.topAnchor.constraint(equalTo: label.topAnchor, constant: 1),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        themeDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 8
        layer.borderWidth = Metrics.border
        layer.borderColor = theme.warning.withAlphaComponent(0.45).cgColor
        layer.backgroundColor = theme.warning.withAlphaComponent(0.12).cgColor
    }

    override func layout() {
        label.preferredMaxLayoutWidth = max(label.frame.width, 0)
        super.layout()
    }

    override func themeDidChange() {
        icon.image = AppIcon.triangleAlert.image(size: 14, color: theme.warning)
        label.textColor = theme.warning
        needsDisplay = true
    }
}
