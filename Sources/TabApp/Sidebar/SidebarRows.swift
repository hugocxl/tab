import AppKit
import TabCore
import TabProtocol

/// A glyph button for the sidebars' chrome rows: a 30pt circle that fills
/// while hovered, and stays filled while its panel is open (`isOn`).
final class ChromeButton: CircleButton {
    var onPress: ((ChromeButton) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var isOn = false { didSet { if isOn != oldValue { updateAppearance() } } }

    init(_ icon: AppIcon, label: String, side: CGFloat = ChromeButton.side, glyph: CGFloat = ChromeButton.glyph, action: ((ChromeButton) -> Void)? = nil) {
        onPress = action
        super.init(icon: icon, label: label, side: side, glyph: glyph)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The sidebar chrome's button circle.
    static let side: CGFloat = 30
    /// The sidebar chrome's glyph.
    static let glyph: CGFloat = 17
    /// The space between buttons side by side anywhere in the sidebars.
    static let gap: CGFloat = 4
    /// A sidebar chrome row: the button with the gutter between cards above
    /// and below it.
    static let rowHeight: CGFloat = Metrics.gutter * 2 + side

    override var isFilled: Bool { isOn }
    override var mouseDownCanMoveWindow: Bool { false }

    override func pressed() {
        onPress?(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// A shortcut number shown while its modifiers are held: the accent with
/// the background's color for the digit.
final class HintBadge: ThemedView {
    let label: String

    init(_ label: String) {
        self.label = label
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        theme.accent.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: side * 0.25, yRadius: side * 0.25).fill()
        let font = AppFont.system(side * (label.count > 1 ? 0.4 : 0.7), weight: .bold)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: theme.bg])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// A sidebar card: a Home terminal, a project's own checkout or a worktree.
/// The first line is what runs there; the second its name, branch, PRIMARY
/// badge, pull request and activity.
final class SidebarCardView: HoverView {
    let data: ActivityCardData
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private let lead: NSView
    private let headline: NSTextField
    private let shellLabel: NSTextField?
    private let nameLabel = makeLabel("", font: AppFont.footnote)
    private let branchLabel = makeLabel("", font: AppFont.footnote)
    private let primaryBadge = PrimaryBadge()
    private let prLabel = makeLabel("", font: AppFont.footnote)
    private let dot = ActivityGlyph()
    private let elapsedLabel = makeLabel("", font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
    private var elapsedTimer: Timer?
    private let glass = GlassView(style: .card)

    /// 1pt border, 6pt padding, the 18pt headline, a 3pt gap and the 13pt
    /// second line.
    static let height: CGFloat = 48

    init(data: ActivityCardData, hint: String?) {
        self.data = data
        var shell: NSTextField?
        let text: String
        let weight: NSFont.Weight
        let icon: AppIcon
        var logo: AgentProvider?
        switch data.headline {
        case .command(let command):
            (text, weight, icon) = (command, .semibold, .terminal)
        case .editor(let file):
            (text, weight, icon) = (file, .semibold, .file)
        case .diff(let file):
            (text, weight, icon) = (file, .semibold, .gitBranch)
        case .browser(let page):
            (text, weight, icon) = (page, .semibold, .globe)
        case .device(let name):
            (text, weight, icon) = (name, .semibold, .phone)
        case let .agent(provider, task):
            (text, weight, icon) = (task ?? provider.displayName, task == nil ? .regular : .medium, .terminal)
            logo = provider
        case let .shell(name, directory):
            shell = makeLabel(name, font: AppFont.system(13))
            (text, weight, icon) = (directory ?? "", .regular, .terminal)
        case .empty:
            (text, weight, icon) = ("No terminal", .regular, .terminal)
        }
        headline = makeLabel(text, font: AppFont.system(13, weight: weight))
        shellLabel = shell
        if let hint {
            lead = HintBadge(hint)
        } else if let logo, let image = AgentLogo.image(for: logo, lightBackground: AppTheme.shared.palette.isLight) {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            lead = view
        } else {
            lead = HeadlineChip(icon: icon, tone: Self.tone(data.headline))
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        addSubview(glass)
        nameLabel.stringValue = data.name
        branchLabel.stringValue = data.branch ?? ""
        prLabel.stringValue = data.pullRequest.map { "#\($0)" } ?? ""
        for view in [lead, headline, nameLabel, branchLabel, primaryBadge, prLabel, elapsedLabel, dot] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        if let shell { shell.translatesAutoresizingMaskIntoConstraints = true; addSubview(shell) }
        primaryBadge.isHidden = !data.primary
        branchLabel.isHidden = data.branch == nil
        prLabel.isHidden = data.pullRequest == nil
        elapsedLabel.isHidden = data.workingSince == nil
        dot.isHidden = data.status == .idle
        alphaValue = data.unavailable ? 0.5 : 1
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let parts = [shell?.stringValue, text, data.name, data.branch, data.primary ? "primary" : nil,
                     data.pullRequest.map { "pull request \($0)" }]
        setAccessibilityLabel(parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func tone(_ headline: ActivityCardData.Headline) -> HeadlineChip.Tone {
        switch headline {
        case .shell: return .shell
        case .empty: return .dim
        default: return .normal
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func themeDidChange() {
        glass.appearance = theme.nsAppearance
        switch data.headline {
        case .agent(_, nil), .empty: headline.textColor = data.headline == .empty ? theme.fgDim : theme.fgMuted
        case .shell: headline.textColor = theme.fgDim
        default: headline.textColor = theme.fg
        }
        shellLabel?.textColor = theme.fgMuted
        nameLabel.textColor = theme.fgMuted
        branchLabel.textColor = theme.fgDim
        prLabel.textColor = theme.accent
        elapsedLabel.textColor = theme.accent
        switch data.status {
        case .attention: dot.style = .dot(theme.accent, diameter: 8)
        case .error: dot.style = .dot(theme.danger, diameter: 8)
        case .paused: dot.style = .dot(theme.warning, diameter: 8)
        case .working: dot.style = .dots(theme.accent)
        case .idle: dot.style = .none
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateElapsed()
    }

    /// Shows the turn's running time and schedules one timer for the moment
    /// the text next changes, only while the card is on screen.
    private func updateElapsed() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        guard let since = data.workingSince, window != nil else { return }
        let elapsed = Date().timeIntervalSince(since)
        let text = ActivityCardData.elapsedText(elapsed)
        if elapsedLabel.stringValue != text {
            elapsedLabel.stringValue = text
            needsLayout = true
        }
        let timer = Timer(timeInterval: ActivityCardData.secondsUntilElapsedChanges(elapsed) + 0.01, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateElapsed() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        glass.isHidden = !data.selected
        let hovered = !data.selected && isHovered && !data.unavailable
        layer?.backgroundColor = (data.selected ? theme.surface : hovered ? theme.hover : .clear).cgColor
        layer?.borderColor = (data.selected ? theme.fg(alpha: 0.08) : .clear).cgColor
    }

    override func hoverDidChange() { needsDisplay = true }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let inset = Metrics.border + 10
        let top = Metrics.border + 6
        let left = inset
        let right = bounds.width - inset
        let leadFrame = CGRect(x: left, y: top, width: 18, height: 18)
        lead.frame = lead is NSImageView ? leadFrame.insetBy(dx: 2, dy: 2) : leadFrame
        var x = left + 18 + 6
        let headlineHeight = headline.intrinsicContentSize.height
        let line1Y = (top + 9 - headlineHeight / 2).rounded()
        if let shellLabel {
            let width = min(shellLabel.textWidth, right - x)
            shellLabel.frame = CGRect(x: x, y: line1Y, width: width, height: headlineHeight)
            x += width + 6
        }
        headline.frame = CGRect(x: x, y: line1Y, width: max(right - x, 0), height: headlineHeight)
        let line2Center: CGFloat = top + 18 + 3 + 6.5
        let smallHeight = nameLabel.intrinsicContentSize.height
        let y2 = (line2Center - smallHeight / 2).rounded()
        dot.frame = CGRect(x: right - 12, y: line2Center - 6, width: 12, height: 12)
        var trailing = dot.isHidden ? right : right - 12 - 6
        if !elapsedLabel.isHidden {
            // The dots glyph is narrower than its 12pt box, so hug it.
            let width = elapsedLabel.textWidth
            let labelTrailing = dot.isHidden ? trailing : right - 12 - 1
            elapsedLabel.frame = CGRect(x: labelTrailing - width, y: y2, width: width, height: smallHeight)
            trailing = labelTrailing - width - 6
        }
        if !prLabel.isHidden {
            let width = prLabel.textWidth
            prLabel.frame = CGRect(x: trailing - width, y: y2, width: width, height: smallHeight)
            trailing -= width + 6
        }
        var cursor = left
        let nameWidth = min(nameLabel.textWidth, max(trailing - cursor, 0))
        nameLabel.frame = CGRect(x: cursor, y: y2, width: nameWidth, height: smallHeight)
        cursor += nameWidth + 6
        if !branchLabel.isHidden {
            let reserve = data.primary ? primaryBadge.intrinsicContentSize.width + 6 : 0
            let width = max(min(branchLabel.textWidth, trailing - cursor - reserve), 0)
            branchLabel.frame = CGRect(x: cursor, y: y2, width: width, height: smallHeight)
            cursor += width + 6
        }
        if data.primary {
            let size = primaryBadge.intrinsicContentSize
            primaryBadge.frame = CGRect(x: cursor, y: (line2Center - size.height / 2).rounded(), width: size.width, height: size.height)
        }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard !data.unavailable, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// The 18pt rounded chip that leads a card without an agent.
final class HeadlineChip: ThemedView {
    enum Tone { case normal, shell, dim }
    let icon: AppIcon
    let tone: Tone

    init(icon: AppIcon, tone: Tone) {
        self.icon = icon
        self.tone = tone
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        theme.surface.setFill()
        path.fill()
        theme.cardBorder.setStroke()
        path.stroke()
        guard let image = icon.image(size: 11) else { return }
        let color: NSColor
        switch tone {
        case .normal: color = theme.fg
        case .shell: color = theme.diffAdd
        case .dim: color = theme.fgDim
        }
        let frame = NSRect(x: ((bounds.width - image.size.width) / 2).rounded(), y: ((bounds.height - image.size.height) / 2).rounded(),
                           width: image.size.width, height: image.size.height)
        image.tinted(color).draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// The PRIMARY badge of a repository's own checkout.
final class PrimaryBadge: ThemedView {
    private let text = "PRIMARY"

    override var intrinsicContentSize: NSSize {
        let size = NSAttributedString(string: text, attributes: [.font: AppFont.micro, .kern: 0.6]).size()
        return NSSize(width: ceil(size.width) + 12, height: 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let string = NSAttributedString(string: text, attributes: [.font: AppFont.micro, .kern: 0.6, .foregroundColor: theme.fgMuted])
        let size = string.size()
        string.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// A host heading above its terminals and projects.
final class HostHeaderRow: ThemedView {
    private let iconView: NSImageView
    private let titleLabel: NSTextField
    private let match: String

    init(title: String, remote: Bool, match: String = "") {
        self.match = match
        iconView = NSImageView(image: (remote ? AppIcon.globe.image(size: 14) : AppIcon.laptop.image(size: 14)) ?? NSImage())
        titleLabel = makeLabel(title, font: AppFont.footnoteMedium)
        super.init(frame: .zero)
        addSubview(iconView)
        addSubview(titleLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }

    override func themeDidChange() {
        iconView.contentTintColor = theme.fgDim
        titleLabel.showMatch(match, color: theme.fgDim, accent: theme.accent)
    }

    override func layout() {
        super.layout()
        iconView.frame = CGRect(x: 10, y: (bounds.height - 14) / 2, width: 16, height: 14)
        let height = titleLabel.intrinsicContentSize.height
        titleLabel.frame = CGRect(x: 30, y: ((bounds.height - height) / 2).rounded(),
                                 width: max(bounds.width - 40, 0), height: height)
    }
}

/// A project's collapsible header with its icon, name and workspace actions.
final class ProjectHeaderRow: HoverView {
    let project: ProjectId
    var onGear: ((NSView) -> Void)?
    var onNewWorktree: (() -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let gear = ChromeButton(.settings, label: "Project Settings", side: 24, glyph: 14)
    private let plus: ChromeButton?
    private let missing: Bool
    private let match: String

    static let height: CGFloat = 28

    init(project: Project, title: String, icon: NSImage?, remoteName: String?, canCreateWorktree: Bool, match: String = "") {
        self.project = project.id
        self.match = match
        missing = project.status == .missing
        titleLabel = makeLabel(title, font: AppFont.header)
        plus = canCreateWorktree ? ChromeButton(.plus, label: "New Worktree", side: 24, glyph: 14) : nil
        plus?.shortcut = .newWorktree
        super.init(frame: .zero)
        if let remoteName { toolTip = "\(remoteName) · \(project.directory.rawValue)" }
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = Metrics.radiusSmall
        iconView.layer?.masksToBounds = true
        for view in [iconView, titleLabel, gear] as [NSView] { addSubview(view) }
        if let plus { addSubview(plus) }
        gear.onPress = { [weak self] button in self?.onGear?(button) }
        plus?.onPress = { [weak self] _ in self?.onNewWorktree?() }
        gear.isHidden = true
        plus?.isHidden = true
        alphaValue = missing ? 0.5 : 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func themeDidChange() {
        titleLabel.showMatch(match, color: theme.fgMuted, accent: theme.accent)
        needsDisplay = true
    }

    override func hoverDidChange() {
        gear.isHidden = !isHovered
        plus?.isHidden = !isHovered
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        theme.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 6
        let gap: CGFloat = 4
        var x = padding
        let middle = bounds.height / 2
        if iconView.image != nil {
            iconView.frame = CGRect(x: x, y: middle - 12, width: 24, height: 24)
            x += 24 + gap
        } else {
            iconView.frame = .zero
        }
        var right = bounds.width - padding
        if let plus {
            right -= 24
            plus.frame = CGRect(x: right, y: middle - 12, width: 24, height: 24)
            right -= 2
        }
        right -= 24
        gear.frame = CGRect(x: right, y: middle - 12, width: 24, height: 24)
        right -= gap
        let height = titleLabel.intrinsicContentSize.height
        titleLabel.frame = CGRect(x: x, y: (middle - height / 2).rounded(), width: max(right - x, 0), height: height)
    }

    override func mouseDown(with event: NSEvent) {
        onDrag?(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// A worktree the server is still creating.
final class CreatingRow: ThemedView {
    private let spinner = ActivityGlyph()
    private let label: NSTextField

    init(name: String) {
        label = makeLabel(name, font: AppFont.body)
        super.init(frame: .zero)
        addSubview(spinner)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }

    override func themeDidChange() {
        label.textColor = theme.fgMuted
        spinner.style = .spinner(theme.accent)
    }

    override func layout() {
        super.layout()
        spinner.frame = CGRect(x: 12, y: 8, width: 12, height: 12)
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: 32, y: (14 - height / 2).rounded(), width: max(bounds.width - 40, 0), height: height)
    }
}

extension NSTextField {
    /// Shows the label in `color` with each case-insensitive occurrence of
    /// `match` in `accent`, as the sidebar marks what its filter matched.
    func showMatch(_ match: String, color: NSColor, accent: NSColor) {
        let text = stringValue
        let string = NSMutableAttributedString(string: text, attributes: [.foregroundColor: color, .font: font ?? AppFont.body])
        let needle = match.trimmingCharacters(in: .whitespaces)
        var searchRange = text.startIndex..<text.endIndex
        while !needle.isEmpty, let found = text.range(of: needle, options: .caseInsensitive, range: searchRange) {
            string.addAttribute(.foregroundColor, value: accent, range: NSRange(found, in: text))
            searchRange = found.upperBound..<text.endIndex
        }
        attributedStringValue = string
    }
}
