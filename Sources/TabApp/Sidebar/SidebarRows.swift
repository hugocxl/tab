import AppKit
import TabCore
import TabProtocol

/// A glyph button for chrome rows: muted, brighter under the pointer, and
/// on a soft pill while its panel is open.
final class ChromeButton: HoverView {
    var icon: AppIcon { didSet { needsDisplay = true } }
    var action: ((ChromeButton) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    let side: CGFloat
    let glyphSize: CGFloat

    init(_ icon: AppIcon, label: String, side: CGFloat = 26, glyph: CGFloat = Metrics.glyph, action: ((ChromeButton) -> Void)? = nil) {
        self.icon = icon
        self.side = side
        glyphSize = glyph
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if isOn || isHovered {
            (isOn ? theme.selection : theme.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
        }
        guard let image = icon.image(size: glyphSize) else { return }
        let color = isOn || isHovered ? theme.fg : theme.fgMuted
        let rect = NSRect(x: ((bounds.width - image.size.width) / 2).rounded(), y: ((bounds.height - image.size.height) / 2).rounded(),
                          width: image.size.width, height: image.size.height)
        image.tinted(color).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?(self) }
    }

    override func accessibilityPerformPress() -> Bool {
        action?(self)
        return true
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

    static let height: CGFloat = 46

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
        nameLabel.stringValue = data.name
        branchLabel.stringValue = data.branch ?? ""
        prLabel.stringValue = data.pullRequest.map { "#\($0)" } ?? ""
        for view in [lead, headline, nameLabel, branchLabel, primaryBadge, prLabel, dot] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        if let shell { shell.translatesAutoresizingMaskIntoConstraints = true; addSubview(shell) }
        primaryBadge.isHidden = !data.primary
        branchLabel.isHidden = data.branch == nil
        prLabel.isHidden = data.pullRequest == nil
        alphaValue = data.unavailable ? 0.5 : 1
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(text) \(data.name)")
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
        switch data.headline {
        case .agent(_, nil), .empty: headline.textColor = data.headline == .empty ? theme.fgDim : theme.fgMuted
        case .shell: headline.textColor = theme.fgDim
        default: headline.textColor = theme.fg
        }
        shellLabel?.textColor = theme.fgMuted
        nameLabel.textColor = theme.fgMuted
        branchLabel.textColor = theme.fgDim
        prLabel.textColor = theme.accent
        switch data.status {
        case .attention: dot.style = .dot(theme.accent, diameter: 8)
        case .error: dot.style = .dot(theme.danger, diameter: 8)
        case .paused: dot.style = .dot(theme.warning, diameter: 8)
        case .working: dot.style = .spinner(theme.accent)
        case .idle: dot.style = .dot(theme.fgDim, diameter: 8)
        }
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let background: NSColor = data.selected ? theme.surface : (isHovered && !data.unavailable ? theme.hover : .clear)
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = (data.selected ? theme.cardBorder : .clear).cgColor
    }

    override func hoverDidChange() { needsDisplay = true }

    override func layout() {
        super.layout()
        let left: CGFloat = 10
        let right = bounds.width - 10
        lead.frame = CGRect(x: left, y: 6, width: 18, height: 18)
        var x = left + 18 + 6
        let headlineHeight = headline.intrinsicContentSize.height
        let line1Y = (6 + 9 - headlineHeight / 2).rounded()
        if let shellLabel {
            let width = min(shellLabel.textWidth, right - x)
            shellLabel.frame = CGRect(x: x, y: line1Y, width: width, height: headlineHeight)
            x += width + 6
        }
        headline.frame = CGRect(x: x, y: line1Y, width: max(right - x, 0), height: headlineHeight)
        let line2Center: CGFloat = 6 + 18 + 3 + 7
        let smallHeight = nameLabel.intrinsicContentSize.height
        let y2 = (line2Center - smallHeight / 2).rounded()
        dot.frame = CGRect(x: right - 12, y: line2Center - 6, width: 12, height: 12)
        var trailing = right - 12 - 6
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

/// A project's header: icon, name, and its settings and New Worktree buttons.
final class ProjectHeaderRow: HoverView {
    let project: ProjectId
    var onGear: ((NSView) -> Void)?
    var onNewWorktree: (() -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private let iconView = NSImageView()
    private let hint: HintBadge?
    private let titleLabel: NSTextField
    private let remote: NSImageView?
    private let gear = ChromeButton(.settings, label: "Project Settings", side: 20, glyph: 14)
    private let plus: ChromeButton?
    private let missing: Bool

    static let height: CGFloat = 28

    init(project: Project, title: String, icon: NSImage?, hint: String?, remoteName: String?, canCreateWorktree: Bool) {
        self.project = project.id
        missing = project.status == .missing
        titleLabel = makeLabel(title, font: AppFont.system(12, weight: .semibold))
        self.hint = hint.map(HintBadge.init)
        if let remoteName, !project.isRemoteHome {
            let view = NSImageView(image: AppIcon.network.image(size: 10) ?? NSImage())
            view.toolTip = "Remote project on \(remoteName)"
            remote = view
        } else {
            remote = nil
        }
        plus = canCreateWorktree ? ChromeButton(.plus, label: "New Worktree", side: 20, glyph: 14) : nil
        super.init(frame: .zero)
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = Metrics.radiusSmall
        iconView.layer?.masksToBounds = true
        for view in [iconView, titleLabel, gear] as [NSView] { addSubview(view) }
        if let hint = self.hint { addSubview(hint) }
        if let remote { addSubview(remote) }
        if let plus { addSubview(plus) }
        gear.action = { [weak self] button in self?.onGear?(button) }
        plus?.action = { [weak self] _ in self?.onNewWorktree?() }
        alphaValue = missing ? 0.5 : 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func themeDidChange() {
        titleLabel.textColor = theme.fgMuted
        remote?.contentTintColor = theme.fgMuted
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 10
        let middle = bounds.height / 2
        if let hint {
            hint.frame = CGRect(x: x, y: middle - 8, width: 16, height: 16)
            x += 16 + 6
        } else if iconView.image != nil {
            iconView.frame = CGRect(x: x, y: middle - 8, width: 16, height: 16)
            x += 16 + 6
        } else {
            iconView.frame = .zero
        }
        var right = bounds.width - 6
        if let plus {
            right -= 20
            plus.frame = CGRect(x: right, y: middle - 10, width: 20, height: 20)
        }
        right -= 20
        gear.frame = CGRect(x: right, y: middle - 10, width: 20, height: 20)
        right -= 4
        if let remote {
            right -= 14
            remote.frame = CGRect(x: right, y: middle - 7, width: 14, height: 14)
            right -= 4
        }
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

/// The Add Project row at the end of the list.
final class AddProjectRow: HoverView {
    var onClick: ((NSView) -> Void)?
    private let label = makeLabel("Add Project", font: AppFont.system(12, weight: .medium))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Add Project")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func themeDidChange() {
        label.textColor = theme.fgMuted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusLarge, yRadius: Metrics.radiusLarge).fill()
        }
        if let image = AppIcon.plus.image(size: 15) {
            let rect = NSRect(x: 10, y: ((bounds.height - image.size.height) / 2).rounded(), width: image.size.width, height: image.size.height)
            image.tinted(theme.fgMuted).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: 34, y: ((bounds.height - height) / 2).rounded(), width: max(bounds.width - 40, 0), height: height)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(self) }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(self)
        return true
    }
}

/// A project as a 28pt tile in the collapsed sidebar: its icon or initial.
final class ProjectTile: HoverView {
    let project: ProjectId
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private let icon: NSImage?
    private let initial: String
    private let active: Bool
    private let hint: String?

    init(project: Project, title: String, icon: NSImage?, active: Bool, hint: String?) {
        self.project = project.id
        self.icon = icon
        initial = Project.initial(title).uppercased()
        self.active = active
        self.hint = hint
        super.init(frame: .zero)
        toolTip = title
        alphaValue = project.status == .missing ? 0.5 : 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 34) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let tile = bounds.insetBy(dx: 3, dy: 3)
        if let hint {
            theme.accent.setFill()
            NSBezierPath(roundedRect: tile, xRadius: 7, yRadius: 7).fill()
            let text = NSAttributedString(string: hint, attributes: [.font: AppFont.system(18, weight: .bold), .foregroundColor: theme.bg])
            let size = text.size()
            text.draw(at: NSPoint(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2))
        } else if let icon {
            icon.draw(in: tile, from: .zero, operation: .sourceOver, fraction: isHovered ? 0.85 : 1, respectFlipped: true, hints: nil)
        } else {
            theme.surface.setFill()
            NSBezierPath(roundedRect: tile, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
            let text = NSAttributedString(string: initial, attributes: [.font: AppFont.system(13, weight: .bold), .foregroundColor: theme.fg])
            let size = text.size()
            text.draw(at: NSPoint(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2))
        }
        if active {
            theme.accent.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 9, yRadius: 9)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
