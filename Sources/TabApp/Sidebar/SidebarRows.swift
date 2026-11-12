import AppKit
import TabCore
import TabProtocol

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

/// A sidebar card: a Home tab, a project's own checkout or a worktree.
/// Stacked: the project (in the Open Tabs layout), the title, the folder or
/// branch with its pull request, then every pane and what it is doing when
/// there are several.
final class SidebarCardView: HoverView {
    let data: ActivityCardData
    var onClick: (() -> Void)?
    /// Focuses a pane clicked in the card's list.
    var onPaneClick: ((PaneId) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// Shows a check button at the end of the title row while hovered.
    var onClose: (() -> Void)? {
        didSet { updateCloseButton() }
    }

    private let hintBadge: HintBadge?
    private let titleLabel: NSTextField
    /// The title, drawn like a pane row led by the card's lead pane.
    private let titleRow: PaneRowView?
    private let locationIcon = NSImageView()
    private let locationLabel = makeLabel("", font: AppFont.small)
    /// The location row's parts, colored when the theme changes.
    private let location: [(text: String, tone: LocationTone)]
    private enum LocationTone { case name, detail, link }
    private let paneRows: [PaneRowView]
    private var elapsedTimer: Timer?
    /// Only the selected card has glass; the sidebar rebuilds its cards often.
    private let glass: GlassView?
    private let closeButton = ChromeButton(AppIcon.check, label: "Close Tab", side: 18, glyph: 11)
    /// The hairlines above and below, which hide while this card is filled.
    var dividers: [CardDivider] = []
    /// Whether the card is filled: selected, or hovered.
    var isHighlighted: Bool { data.selected || (isHovered && !data.unavailable) }

    /// The project row the Open Tabs layout puts at the bottom.
    struct Header {
        var title: String
        var icon: NSImage?
    }

    /// Every leading icon's box: the panes' kinds, the
    /// location's and the project's icons.
    static let iconSide: CGFloat = 14
    /// Where text after a leading icon starts.
    static let textInset: CGFloat = iconSide + 8

    private enum Line {
        static let padding: CGFloat = Metrics.border + 8
        static let title: CGFloat = 20
        /// Between the title, the panes and the footer.
        static let sectionGap: CGFloat = 5
        /// A pane row, and a footer row: the location and the project.
        static let row: CGFloat = PaneRowView.height
    }

    /// Lets a title label wrap to `maxTitleLines`, ending in an ellipsis.
    static func wrap(_ label: NSTextField) {
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = maxTitleLines
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = true
    }

    /// A title wraps to at most this many lines.
    static let maxTitleLines = 2
    static var titleLineHeight: CGFloat {
        let font = AppFont.body
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// How many lines `title` takes in `width`, up to `maxTitleLines`.
    static func titleLines(_ title: String, width: CGFloat) -> Int {
        guard width > 0 else { return 1 }
        let height = NSAttributedString(string: title, attributes: [.font: AppFont.body])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
        return min(max(Int((height / titleLineHeight).rounded(.up)), 1), maxTitleLines)
    }

    /// The card's height for its sections: the padding, the title's lines,
    /// one row per listed pane, then the footer's location and project rows.
    static func height(header: Bool, location: Bool, panes: Int, titleLines: Int = 1) -> CGFloat {
        var height = Line.padding * 2 + Line.title + CGFloat(titleLines - 1) * titleLineHeight
        if panes > 0 { height += Line.sectionGap + CGFloat(panes) * Line.row }
        let footer = (location ? 1 : 0) + (header ? 1 : 0)
        // Without panes the footer follows the title directly.
        if footer > 0 { height += (panes > 0 ? Line.sectionGap : 0) + CGFloat(footer) * Line.row }
        return height
    }

    private let headerIcon: NSImageView?
    private let usesDefaultHeaderIcon: Bool
    private let headerLabel: NSTextField?
    /// Whether the location row has anything to say: a folder or name the
    /// project row doesn't already show, a branch or a pull request.
    private let showsLocation: Bool

    init(data: ActivityCardData, hint: String?, header: Header? = nil) {
        self.data = data
        usesDefaultHeaderIcon = header != nil && header?.icon == nil
        if let header {
            let icon = NSImageView(image: header.icon ?? AppIcon.folder.image(size: Self.iconSide, theme: .shared) ?? NSImage())
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.wantsLayer = true
            icon.layer?.cornerRadius = 3
            icon.layer?.masksToBounds = true
            headerIcon = icon
            headerLabel = makeLabel(header.title, font: AppFont.small)
        } else {
            headerIcon = nil
            headerLabel = nil
        }
        hintBadge = hint.map { HintBadge($0) }
        titleLabel = makeLabel(data.title, font: AppFont.body)
        // A lone pane is what the title and status already describe.
        paneRows = data.panes.count > 1 ? data.panes.map { PaneRowView(row: $0) } : []
        // With several panes no one pane stands for the card while they idle.
        titleRow = data.lead.map { PaneRowView(row: $0, title: data.title, showsIcon: data.panes.count == 1, idleCircle: data.panes.count > 1) }
        // Skip a name the title or the project row already shows.
        let name = data.name.flatMap { $0 == header?.title || $0 == data.title ? nil : $0 }
        showsLocation = name != nil || data.branch != nil || data.pullRequest != nil
        var locationParts: [(text: String, tone: LocationTone)] = []
        if let name { locationParts.append((name, .name)) }
        if let branch = data.branch { locationParts.append((branch, .name)) }
        if let base = data.base {
            let ahead = data.baseAhead.flatMap { $0 > 0 ? " ↑\($0)" : nil } ?? ""
            locationParts.append(("← \(base)\(ahead)", .detail))
        }
        if data.primary { locationParts.append(("primary", .detail)) }
        if let pullRequest = data.pullRequest { locationParts.append(("#\(pullRequest)", .link)) }
        location = locationParts
        glass = data.selected ? GlassView(style: .card) : nil
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        if let glass { addSubview(glass) }
        locationIcon.imageScaling = .scaleProportionallyUpOrDown
        locationIcon.isHidden = !showsLocation
        locationLabel.isHidden = !showsLocation
        titleLabel.isHidden = titleRow != nil
        Self.wrap(titleLabel)
        let views: [NSView?] = [headerIcon, headerLabel, hintBadge, titleLabel, titleRow, locationIcon, locationLabel]
        for view in views.compactMap({ $0 }) + paneRows {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        closeButton.shortcut = .closeTab
        closeButton.restsFilled = true
        closeButton.isHidden = true
        closeButton.onPress = { [weak self] _ in self?.onClose?() }
        addSubview(closeButton)
        toolTip = Self.baseDescription(data)
        alphaValue = data.unavailable || data.offline ? 0.5 : 1
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let parts = [headerLabel?.stringValue, titleLabel.stringValue, data.name, data.branch, data.primary ? "primary" : nil,
                     data.pullRequest.map { "pull request \($0)" }, data.offline ? "not connected" : nil] + data.panes.map(\.title)
        setAccessibilityLabel(parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// "Branch wt-5c85, started from release · 3 commits ahead, 1 behind".
    private static func baseDescription(_ data: ActivityCardData) -> String? {
        guard let base = data.base else { return nil }
        var text = "Branch \(data.branch ?? data.name ?? ""), started from \(base)"
        if let ahead = data.baseAhead, let behind = data.baseBehind {
            func count(_ n: UInt64) -> String { n == 1 ? "1 commit" : "\(n) commits" }
            text += " · \(count(ahead)) ahead, \(behind) behind"
        }
        return text
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: Self.height(header: headerLabel != nil, location: showsLocation, panes: paneRows.count, titleLines: titleLines))
    }

    /// The title's lines at the card's current width.
    private var titleLines: Int {
        var width = bounds.width - 2 * (Metrics.border + 10)
        if let titleRow, !titleRow.wrapsTitle { return 1 }
        if hintBadge != nil { width -= 18 + 6 }
        if let titleRow { width -= titleRow.textInsets }
        return Self.titleLines(data.title, width: width)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        // The title wraps by width, so the height follows it.
        if widthChanged { invalidateIntrinsicContentSize() }
    }
    override var mouseDownCanMoveWindow: Bool { false }

    override func themeDidChange() {
        glass?.appearance = theme.nsAppearance
        headerLabel?.textColor = theme.fgMuted
        titleLabel.textColor = theme.fg
        if usesDefaultHeaderIcon {
            headerIcon?.image = AppIcon.folder.image(size: Self.iconSide, theme: theme)
        }
        if headerIcon?.image?.isTemplate ?? false { headerIcon?.contentTintColor = theme.fgDim }
        // A plain branch line, else the Home tab's folder.
        if data.branch != nil || data.base != nil || data.primary {
            locationIcon.image = AppIcon.gitBranch.image(size: Self.iconSide, color: theme.fgDim)
        } else {
            locationIcon.image = AppIcon.folder.image(size: Self.iconSide, theme: theme)
        }
        let text = NSMutableAttributedString()
        for (index, part) in location.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: " · ", attributes: [.font: AppFont.small, .foregroundColor: theme.fgDim])) }
            let color: NSColor
            switch part.tone {
            case .name: color = theme.fgMuted
            case .detail: color = theme.fgDim
            case .link: color = theme.accent
            }
            text.append(NSAttributedString(string: part.text, attributes: [.font: AppFont.small, .foregroundColor: color]))
        }
        locationLabel.attributedStringValue = text
        locationLabel.lineBreakMode = .byTruncatingTail
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateElapsed()
    }

    /// Shows each working pane's running time and schedules one timer for
    /// the moment the next text changes, only while the card is on screen.
    private func updateElapsed() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        guard window != nil else { return }
        let now = Date()
        var next: TimeInterval?
        for row in paneRows + [titleRow].compactMap({ $0 }) {
            guard let since = row.row.workingSince else { continue }
            let elapsed = now.timeIntervalSince(since)
            row.elapsed = ActivityCardData.elapsedText(elapsed)
            next = min(next ?? .infinity, ActivityCardData.secondsUntilElapsedChanges(elapsed))
        }
        guard let next else { return }
        let timer = Timer(timeInterval: next + 0.01, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateElapsed() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let hovered = !data.selected && isHovered && !data.unavailable
        layer?.backgroundColor = (data.selected ? theme.surface : hovered ? theme.hover : .clear).cgColor
        layer?.borderColor = (data.selected ? theme.fg(alpha: 0.08) : .clear).cgColor
    }

    override func hoverDidChange() {
        needsDisplay = true
        updateCloseButton()
        dividers.forEach { $0.refresh() }
    }

    private func updateCloseButton() {
        let shown = isHovered && onClose != nil && !data.unavailable
        guard closeButton.isHidden == shown else { return }
        closeButton.isHidden = !shown
        needsLayout = true
    }

    override func layout() {
        super.layout()
        glass?.frame = bounds
        let left = Metrics.border + 10
        let right = bounds.width - left
        var top = Line.padding
        var x = left
        let center = top + Line.title / 2
        let lines = titleLines
        let titleBlock = Line.title + CGFloat(lines - 1) * Self.titleLineHeight
        if let hintBadge {
            hintBadge.frame = CGRect(x: x, y: center - 9, width: 18, height: 18)
            x += 18 + 6
        }
        closeButton.frame = CGRect(x: right - 18, y: center - 9, width: 18, height: 18)
        let titleRight = closeButton.isHidden ? right : right - 18 - 6
        let titleHeight = CGFloat(lines) * Self.titleLineHeight
        titleLabel.frame = CGRect(x: x, y: (center - Self.titleLineHeight / 2).rounded(), width: max(titleRight - x, 0), height: titleHeight)
        titleRow?.hidesStatus = !closeButton.isHidden
        titleRow?.frame = CGRect(x: x, y: top, width: max(right - x, 0), height: titleBlock)
        top += titleBlock
        if !paneRows.isEmpty { top += Line.sectionGap }
        for row in paneRows {
            row.frame = CGRect(x: left, y: top, width: max(right - left, 0), height: Line.row)
            top += Line.row
        }
        if !paneRows.isEmpty, showsLocation || headerLabel != nil { top += Line.sectionGap }
        if showsLocation {
            layoutFooterRow(icon: locationIcon, label: locationLabel, top: top, left: left, right: right)
            top += Line.row
        }
        if let headerIcon, let headerLabel {
            layoutFooterRow(icon: headerIcon, label: headerLabel, top: top, left: left, right: right)
        }
    }

    /// The box of a leading icon centered on a line.
    static func iconBox(x: CGFloat, centerY: CGFloat) -> CGRect {
        CGRect(x: x, y: (centerY - iconSide / 2).rounded(), width: iconSide, height: iconSide)
    }

    /// A footer row, the location or the project: its icon in the first
    /// column, its text in the second.
    private func layoutFooterRow(icon: NSView, label: NSTextField, top: CGFloat, left: CGFloat, right: CGFloat) {
        let center = top + Line.row / 2
        icon.frame = Self.iconBox(x: left, centerY: center)
        let height = label.intrinsicContentSize.height
        let x = left + Self.textInset
        label.frame = CGRect(x: x, y: (center - height / 2).rounded(), width: max(right - x, 0), height: height)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !data.unavailable, bounds.contains(point) else { return }
        if let row = paneRows.first(where: { $0.frame.contains(point) }), let onPaneClick {
            onPaneClick(row.row.id)
        } else {
            onClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// One pane in a card's list: its icon, title and folder, with elapsed time
/// and status at the trailing edge. A card's title uses larger icons.
final class PaneRowView: ThemedView {
    static let height: CGFloat = 20
    /// The title's icon box, as tall as the title's text.
    static let titleIconSide: CGFloat = 18
    let row: ActivityCardData.PaneRow
    /// The running time of the pane's turn, which the card keeps current.
    var elapsed = "" {
        didSet {
            guard elapsed != oldValue else { return }
            elapsedLabel.stringValue = elapsed
            elapsedLabel.isHidden = elapsed.isEmpty
            needsLayout = true
        }
    }

    private let status = PaneStatusView()
    private let icon = NSImageView()
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let elapsedLabel = makeLabel("", font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
    /// Styled as a card's title, for a card's only pane.
    private let isTitle: Bool

    /// `title` replaces the row's text when the row is its card's title.
    /// `showsIcon` is false for a title whose panes already list their icons.
    /// `idleCircle` shows an empty status circle while idle.
    init(row: ActivityCardData.PaneRow, title: String? = nil, showsIcon: Bool = true, idleCircle: Bool = false) {
        self.row = row
        isTitle = title != nil
        let font = title == nil ? AppFont.system(12) : AppFont.body
        titleLabel = makeLabel(title ?? row.title, font: font)
        detailLabel = makeLabel(row.detail ?? "", font: font)
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        status.side = iconSide
        status.showsIdle = idleCircle
        // The list's spinners stay gray beside its colored icons.
        status.grayWorking = !isTitle
        status.status = row.status
        icon.isHidden = !showsIcon
        for view in [status, icon, titleLabel, detailLabel, elapsedLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        detailLabel.isHidden = detailLabel.stringValue.isEmpty
        elapsedLabel.isHidden = true
        if wrapsTitle { SidebarCardView.wrap(titleLabel) }
        if case .image = row.icon {
            // Favicons are square artwork; round them like app icons.
            icon.wantsLayer = true
            icon.layer?.cornerRadius = iconSide * 3 / 14
            icon.layer?.cornerCurve = .continuous
            icon.layer?.masksToBounds = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func themeDidChange() {
        titleLabel.textColor = isTitle ? theme.fg : theme.fgMuted
        detailLabel.textColor = theme.fgDim
        elapsedLabel.textColor = theme.fgDim
        let image: NSImage?
        switch row.icon {
        case .agent(let provider): image = AgentLogo.image(for: provider, lightBackground: theme.isLight)
        // Command brands share their file-type hue; UI tools keep the terminal tint.
        case .command(let command): image = command.image(size: iconSide, hue: command.signatureHue ?? .green, theme: theme)
        case .file(let name): image = FileIcon.image(for: name, theme: theme, size: iconSide)
        case .image(let favicon): image = favicon
        // Each kind's mark carries its own hue: terminal green, agent indigo,
        // browser blue, simulator purple.
        case .kind(let kind): image = kind.glyph.image(size: iconSide, theme: theme)
        }
        icon.image = image
        // Template glyphs take the tint.
        icon.contentTintColor = theme.fgMuted
        status.refresh()
    }

    private var iconSide: CGFloat { isTitle ? Self.titleIconSide : SidebarCardView.iconSide }

    /// The card's close button replaces its status without shifting the row.
    var hidesStatus = false {
        didSet { status.isHidden = hidesStatus }
    }

    private var leadingInset: CGFloat { icon.isHidden ? 0 : SidebarCardView.textInset }
    private var statusInset: CGFloat { isTitle || row.status != .idle || status.showsIdle ? iconSide + 6 : 0 }
    /// Space unavailable to the title, also used to measure wrapped card titles.
    var textInsets: CGFloat {
        leadingInset + statusInset + (elapsedLabel.isHidden ? 0 : elapsedLabel.textWidth + 6)
    }

    override func layout() {
        super.layout()
        // Everything lines up with the first line when a title wraps.
        let center = Self.height / 2
        // Centered on the list's icon column, so a larger title icon reaches
        // into the card's padding and the text still lines up.
        let iconBox = CGRect(x: (SidebarCardView.iconSide - iconSide) / 2, y: (center - iconSide / 2).rounded(), width: iconSide, height: iconSide)
        status.frame = CGRect(x: bounds.width - iconSide, y: iconBox.minY, width: iconSide, height: iconSide)
        icon.frame = iconBox
        var trailing = bounds.width - statusInset
        let height = isTitle ? SidebarCardView.titleLineHeight : titleLabel.intrinsicContentSize.height
        let y = (center - height / 2).rounded()
        if !elapsedLabel.isHidden {
            let width = elapsedLabel.textWidth
            elapsedLabel.frame = CGRect(x: trailing - width, y: y, width: width, height: height)
            trailing -= width + 6
        }
        let x = leadingInset
        if !detailLabel.isHidden {
            // The folder follows the title, which gives up space first while
            // the folder keeps at least its share.
            let room = max(trailing - x, 0)
            let detailWidth = detailLabel.textWidth
            let titleWidth = min(titleLabel.textWidth, max(room - min(detailWidth, room * 0.45) - Self.detailGap, 0))
            titleLabel.frame = CGRect(x: x, y: y, width: titleWidth, height: height)
            let detailX = x + titleWidth + Self.detailGap
            detailLabel.frame = CGRect(x: detailX, y: y, width: max(min(detailWidth, trailing - detailX), 0), height: height)
            return
        }
        let lines = isTitle ? max(Int(((bounds.height - Self.height) / height).rounded()) + 1, 1) : 1
        titleLabel.frame = CGRect(x: x, y: y, width: max(trailing - x, 0), height: height * CGFloat(lines))
    }

    private static let detailGap: CGFloat = 5

    /// Whether the title may wrap: a folder after it keeps it to one line.
    var wrapsTitle: Bool { isTitle && detailLabel.isHidden }
}

/// The hairline between two cards, as wide as a card. Beside a selected or
/// hovered card it stays, clear, so the fill meets no line and nothing moves.
final class CardDivider: ThemedView {
    weak var above: SidebarCardView?
    weak var below: SidebarCardView?
    private var isVisible = true {
        didSet { if isVisible != oldValue { needsDisplay = true } }
    }

    func refresh() {
        isVisible = !(above?.isHighlighted ?? false) && !(below?.isHighlighted ?? false)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1 / (window?.backingScaleFactor ?? 2))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateIntrinsicContentSize()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (isVisible ? theme.separator : .clear).cgColor
    }
}

/// Tab Icons for waiting, done, failed, paused and idle states, and a native
/// spinner while working. The idle circle appears only with `showsIdle`.
final class PaneStatusView: NSView {
    var status: ActivityCardData.PaneRow.Status = .idle {
        didSet { if status != oldValue { refresh() } }
    }
    var showsIdle = false {
        didSet { if showsIdle != oldValue { refresh() } }
    }
    /// Draws the spinner in muted gray rather than the accent.
    var grayWorking = false {
        didSet { if grayWorking != oldValue { refresh() } }
    }
    var side = SidebarCardView.iconSide {
        didSet { if side != oldValue { refresh() } }
    }

    private let symbol = NSImageView()
    private var spinner: ActivityGlyph?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        symbol.imageScaling = .scaleProportionallyUpOrDown
        addSubview(symbol)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        symbol.frame = bounds
        spinner?.frame = bounds.insetBy(dx: 1, dy: 1)
    }

    /// Draws the status in the current theme's colors.
    func refresh() {
        let theme = AppTheme.shared
        let icon: AppIcon?
        let color: NSColor
        let spins: Bool
        switch status {
        case .working, .progress: spins = true
        default: spins = false
        }
        switch status {
        case .working, .progress: (icon, color) = (nil, grayWorking ? theme.fgMuted : theme.accent)
        case .blocked: (icon, color) = (.exclamationCircleFill, theme.accent)
        case .done: (icon, color) = (.circleCheckFill, theme.success)
        case .error: (icon, color) = (.circleXFill, theme.danger)
        case .paused: (icon, color) = (.pauseCircleFill, theme.warning)
        case .idle: (icon, color) = (showsIdle ? .circle : nil, theme.fgDim)
        }
        symbol.image = icon?.image(size: side)
        symbol.contentTintColor = color
        if spins {
            let activity = spinner ?? ActivityGlyph()
            activity.style = .spinner(color)
            if activity.superview == nil { addSubview(activity) }
            spinner = activity
            needsLayout = true
        } else {
            spinner?.removeFromSuperview()
            spinner = nil
        }
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
    private let gear = ChromeButton(AppIcon.settings, label: "Project Settings", side: 24, glyph: 14)
    private let plus: ChromeButton?
    private let missing: Bool
    private let match: String

    static let height: CGFloat = 28

    init(project: Project, title: String, icon: NSImage?, remoteName: String?, canCreateWorktree: Bool, match: String = "") {
        self.project = project.id
        self.match = match
        missing = project.status == .missing
        titleLabel = makeLabel(title, font: AppFont.header)
        plus = canCreateWorktree ? ChromeButton(AppIcon.plus, label: "New Worktree", side: 24, glyph: 14) : nil
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
