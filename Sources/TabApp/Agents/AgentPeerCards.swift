import AppKit
import TabProtocol

/// What the app knows of another agent now; nil when it isn't open on the server.
typealias AgentPeerActivity = (SessionId) -> AgentActivity?

/// A card about another agent: a worker this conversation started, a worker's
/// report, or a message another agent sent. The peer's name opens its pane.
@MainActor
final class AgentPeerCardRow: AgentCardRow {
    enum Mode: Equatable {
        /// "Started worker tax-rules", live with the worker's state; the task folds out.
        case worker
        /// "Report from tax-rules", with the report's outcome and reply.
        case report
        /// "Task from coordinator Fix ACME-412", or "Message from …" after the task.
        case message
    }

    let mode: Mode
    /// The live state of the card's agent, re-read on `peerActivityDidChange`.
    var peerActivity: AgentPeerActivity? { didSet { render() } }
    private let icon = NSImageView()
    private let caption = makeLabel("", font: AppFont.system(13))
    let nameButton = PillButton("", style: .plain)
    private let status = AgentStatusPill()
    private let time = makeLabel("", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
    let disclosure = PillButton("", style: .plain)
    private let body = AgentResponseView(frame: .zero)
    private(set) var expanded: Bool
    private var bodyHeight: CGFloat = 0
    private let padding: CGFloat = 14
    private let headerHeight: CGFloat = 44
    private static let timeFormat: DateFormatter = {
        let format = DateFormatter()
        format.dateStyle = .none
        format.timeStyle = .short
        return format
    }()

    init(mode: Mode) {
        self.mode = mode
        expanded = mode == .report
        super.init(frame: .zero)
        for view in [icon, caption, nameButton, status, time, disclosure, body] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        caption.lineBreakMode = .byTruncatingTail
        time.alignment = .right
        nameButton.imagePosition = .imageTrailing
        nameButton.lineBreakMode = .byTruncatingTail
        nameButton.onPress = { [weak self] in self?.openPeer() }
        disclosure.imagePosition = .imageOnly
        disclosure.onPress = { [weak self] in self?.toggle() }
        body.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
        body.onOpenCitation = { [weak self] citation in self?.onOpenCitation?(citation) }
        body.onHeightChanged = { [weak self] in self?.onDisclosure?() }
        body.isHidden = !expanded
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var cardFill: NSColor? { theme.fg.withAlphaComponent(0.025) }
    override var cardBorder: NSColor? { theme.fg.withAlphaComponent(0.1) }
    override var findTextViews: [AgentRichTextView] { body.textViews }

    var peer: AgentPeer? { item?.peer }

    var captionText: String {
        switch mode {
        case .worker: "Started worker"
        case .report: "Report from"
        case .message: item?.workContext?.requestKind == AgentPeerItemType.taskRequest ? "Task from coordinator" : "Message from"
        }
    }

    /// The pill's text and whether it is shown: a worker's live state, or a report's outcome.
    var statusText: String? {
        switch mode {
        case .message: return nil
        case .report:
            switch AgentChatTurn.Outcome(rawValue: item?.workContext?.sourceStatus ?? "") {
            case .completed: return "Done"
            case .failed: return "Failed"
            case .interrupted: return "Stopped"
            case .cancelled: return "Closed"
            default: return nil
            }
        case .worker:
            guard let peer, let lookup = peerActivity else { return nil }
            switch lookup(peer.session)?.state {
            case .working: return "Working"
            case .blocked: return "Needs you"
            case .idle: return "Done"
            case .unknown: return nil
            case nil: return "Closed"
            }
        }
    }

    private var statusColor: NSColor {
        switch statusText {
        case "Working": theme.accent
        case "Needs you": theme.warning
        case "Done": theme.diffAdd
        case "Failed": theme.danger
        default: theme.fgDim
        }
    }

    /// The text that folds out: the worker's task, the report, or the message.
    var bodySource: String {
        guard let item else { return "" }
        switch mode {
        case .worker: return item.detail ?? ""
        case .message: return item.text
        case .report:
            let files = (item.detail ?? "").split(separator: "\n").filter { !$0.isEmpty }
            guard !files.isEmpty else { return item.text }
            return item.text + "\n\n**Changed files**\n\n" + files.prefix(32).map { "- `\($0)`" }.joined(separator: "\n")
                + (files.count > 32 ? "\n- and \(files.count - 32) more" : "")
        }
    }

    override func render() {
        guard let item, let peer else { return }
        icon.image = AgentLogo.image(for: peer.provider == .claude ? .claude : .codex, lightBackground: theme.isLight)
        caption.stringValue = captionText
        caption.textColor = theme.fgDim
        nameButton.title = peer.name
        nameButton.font = AppFont.system(13, weight: .medium)
        nameButton.setTitleColor(theme.fg)
        nameButton.image = AppIcon.externalLink.image(size: 12, scale: AppIcon.inlineScale, color: theme.fgDim)
        nameButton.toolTip = "Open \(peer.name)"
        nameButton.setAccessibilityLabel("Open \(peer.name)")
        status.text = statusText ?? ""
        status.color = statusColor
        status.isHidden = statusText == nil
        time.stringValue = item.createdAt.map { Self.timeFormat.string(from: $0) } ?? ""
        time.textColor = theme.fgDim
        let hasBody = !bodySource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        disclosure.isHidden = !hasBody
        disclosure.image = (expanded ? AppIcon.chevronDown : .chevronRight).image(size: 12, scale: AppIcon.inlineScale, color: theme.fgDim)
        disclosure.setAccessibilityLabel(expanded ? "Collapse" : "Expand")
        body.isHidden = !(expanded && hasBody)
        // Set while folded too, so Find counts the hidden text and opens the card on a match.
        body.setContent(bodySource, theme: theme)
        setAccessibilityLabel([captionText, peer.name, statusText].compactMap { $0 }.joined(separator: " "))
        needsDisplay = true
        invalidateFindText()
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat {
        bodyHeight = body.isHidden ? 0 : body.height(for: max(1, width - 2 * padding))
        return headerHeight + (bodyHeight > 0 ? bodyHeight + padding : 0)
    }

    override func layoutRow(width: CGFloat) {
        icon.frame = NSRect(x: padding, y: 13, width: 18, height: 18)
        var right = width - padding + 6
        if !disclosure.isHidden {
            right -= 28
            disclosure.frame = NSRect(x: right, y: 10, width: 28, height: 24)
        }
        let timeWidth = ceil(time.intrinsicContentSize.width)
        right -= timeWidth + 8
        time.frame = NSRect(x: right, y: 14, width: timeWidth, height: 16)
        if !status.isHidden {
            right -= status.naturalWidth + 8
            status.frame = NSRect(x: right, y: 13, width: status.naturalWidth, height: 18)
        }
        let captionX = padding + 28
        let captionWidth = min(ceil(caption.intrinsicContentSize.width), max(0, right - captionX - 40))
        caption.frame = NSRect(x: captionX, y: 13, width: captionWidth, height: 18)
        let nameX = caption.frame.maxX + 4
        let nameWidth = min(ceil(nameButton.intrinsicContentSize.width) + 4, max(0, right - 8 - nameX))
        nameButton.frame = NSRect(x: nameX, y: 10, width: nameWidth, height: 24)
        body.frame = NSRect(x: padding, y: headerHeight, width: max(1, width - 2 * padding), height: bodyHeight)
        body.layoutSubtreeIfNeeded()
    }

    func openPeer() {
        guard let peer else { return }
        onOpenThread?(AgentThreadLink(session: peer.session, project: peer.project))
    }

    func toggle() {
        expanded.toggle()
        render()
        onDisclosure?()
    }

    override func captureState() -> AgentTimelineRowState { AgentTimelineRowState(expanded: expanded) }

    override func restoreState(_ state: AgentTimelineRowState) {
        guard expanded != state.expanded else { return }
        expanded = state.expanded
        render()
    }

    override func revealFindText(_ view: AgentRichTextView, range: NSRange) -> Bool {
        guard !expanded else { return super.revealFindText(view, range: range) }
        expanded = true
        render()
        return true
    }
}
