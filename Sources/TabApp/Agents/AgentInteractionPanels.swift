import AppKit
import TabProtocol

/// A glass card floating over the conversation: the composer and the panels stacked above it.
/// The transcript scrolls behind it, blurred by the glass and dimmed by a theme fill.
@MainActor
final class AgentSurfaceCard: ThemedView {
    let style: GlassView.Style
    private let glass: GlassView
    /// Sits above the glass: a layer's own background would draw beneath it.
    private let fill = NSView()

    init(style: GlassView.Style) {
        self.style = style
        glass = GlassView(style: style)
        super.init(frame: .zero)
        fill.wantsLayer = true
        addSubview(glass)
        addSubview(fill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = style.cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = Metrics.border
        layer.borderColor = theme.fg.withAlphaComponent(theme.palette.isLight ? 0.10 : 0.12).cgColor
        // Enough of the theme's composer color to keep text legible over a busy transcript,
        // while the conversation still reads through the glass; the composer and the
        // panels above it are one glass.
        fill.layer?.backgroundColor = theme.agentComposer.withAlphaComponent(theme.glassEnabled ? 0.3 : 0.82).cgColor
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        fill.frame = bounds
    }

    override func themeDidChange() {
        appearance = theme.nsAppearance
        glass.appearance = theme.nsAppearance
        needsDisplay = true
    }
}

/// The shared measures of the glass panels stacked above the agent composer, so the
/// notice, activity, task progress, agents and queue line up as one column.
enum AgentPanelMetrics {
    /// Between a card's edge and its rows.
    static let inset: CGFloat = 6
    static let rowHeight: CGFloat = 32
    /// A card of one row.
    static let compactHeight: CGFloat = rowHeight + inset * 2
    /// A row's hover fill, concentric with its card's corners.
    static let rowRadius: CGFloat = GlassView.Style.agentPanel.cornerRadius - inset
    static let iconSide: CGFloat = 16
    static let glyphSize: CGFloat = 15
    /// A row's leading icon and text, from the row's edge.
    static let iconX: CGFloat = 8
    static let textX: CGFloat = iconX + iconSide + 8
    /// Between a row's title, its detail and its trailing facts.
    static let textGap: CGFloat = 8
    /// Between stacked cards.
    static let gap: CGFloat = 8
    static let titleFont = AppFont.body
    static let detailFont = AppFont.small
    /// Running times and counts, in digits that keep their width as they tick.
    static let metaFont = NSFont.monospacedDigitSystemFont(ofSize: AppFont.small.pointSize, weight: .regular)
}

/// A glass card of one row above the composer, such as what the agent waits for or
/// its task list's progress: an icon, a title, a dimmer detail. The whole card presses.
@MainActor
final class AgentPanelLine: ThemedView {
    /// How the icon reads: the accent asks for the user, muted only informs.
    enum Tone { case accent, muted }
    var onPress: (() -> Void)?
    private let card = AgentSurfaceCard(style: .agentPanel)
    private let highlight = NSView()
    private let icon = NoticeIcon()
    private let title = makeLabel("", font: AgentPanelMetrics.titleFont)
    private let detail = makeLabel("", font: AgentPanelMetrics.detailFont)
    private var tone = Tone.muted
    private var hovered = false { didSet { if hovered != oldValue { applyColors() } } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init(accessibilityLabel: String) {
        super.init(frame: .zero)
        isHidden = true
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = AgentPanelMetrics.rowRadius
        highlight.layer?.cornerCurve = .continuous
        icon.glyphSize = AgentPanelMetrics.glyphSize
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        addSubview(card)
        for view in [highlight, icon, title, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            card.addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `title` and `detail`; nil hides the card.
    func show(_ title: String?, detail: String? = nil, icon: Notice.Icon, tone: Tone) {
        isHidden = title == nil
        guard let title else { return }
        let detail = detail ?? ""
        guard self.title.stringValue != title || self.detail.stringValue != detail || self.icon.icon != icon || self.tone != tone else { return }
        self.title.stringValue = title
        self.detail.stringValue = detail
        self.icon.icon = icon
        self.tone = tone
        toolTip = detail.isEmpty ? title : title + " · " + detail
        setAccessibilityValue(toolTip)
        applyColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        let metrics = AgentPanelMetrics.self
        let row = bounds.insetBy(dx: metrics.inset, dy: metrics.inset)
        highlight.frame = row
        icon.frame = NSRect(x: row.minX + metrics.iconX, y: floor(row.midY - metrics.iconSide / 2),
                            width: metrics.iconSide, height: metrics.iconSide)
        let x = row.minX + metrics.textX
        let right = row.maxX - metrics.iconX
        let titleHeight = ceil(title.intrinsicContentSize.height)
        // The title keeps its whole width first; the detail takes what's left.
        let titleWidth = min(title.singleLineWidth, max(0, right - x))
        title.frame = NSRect(x: x, y: floor(row.midY - titleHeight / 2), width: titleWidth, height: titleHeight)
        let detailX = x + titleWidth + metrics.textGap
        let detailHeight = ceil(detail.intrinsicContentSize.height)
        detail.isHidden = detail.stringValue.isEmpty || right - detailX < 24
        detail.frame = NSRect(x: detailX, y: floor(row.midY - detailHeight / 2), width: max(0, right - detailX), height: detailHeight)
    }

    private func applyColors() {
        icon.color = tone == .accent ? theme.accent : theme.fgDim
        title.textColor = theme.fg
        detail.textColor = theme.fgDim
        highlight.layer?.backgroundColor = hovered ? theme.fg.withAlphaComponent(0.05).cgColor : nil
    }

    override func themeDidChange() {
        appearance = theme.nsAppearance
        card.theme = theme
        icon.theme = theme
        applyColors()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}

extension AgentChatSnapshot {
    /// Prompts the server will send on its own. One that needs review waits for the user,
    /// so it keeps nothing busy.
    var hasActiveQueue: Bool {
        // A prompt scheduled for later, such as a retry at a usage limit's reset, keeps nothing busy until then.
        queuePaused != true && queuedPrompts?.contains { prompt in
            prompt.state == .delivering || (prompt.state == .queued && (prompt.scheduledAt.map { $0 <= Date() } ?? true))
        } == true
    }

    /// The retry the server holds for a usage limit's reset, if one is scheduled.
    var scheduledRetry: AgentQueuedPrompt? {
        queuedPrompts?.first { $0.state == .queued && $0.scheduledAt != nil }
    }
}

/// Prompts sent while the agent works, waiting above the composer until their turn.
@MainActor
final class AgentQueueView: ThemedView {
    var onEdit: ((AgentQueuedPrompt) -> Void)?
    var onRemove: ((AgentQueuedPrompt) -> Void)?
    var onDeliver: ((AgentQueuedPrompt) -> Void)?
    var onMove: ((AgentQueuedPrompt, String) -> Void)?
    var onResume: (() -> Void)?
    /// Prompts with an edit the server hasn't saved; their editor brings it back.
    var unsavedEdits: Set<String> = []
    private static let inset = AgentPanelMetrics.inset
    private static let headerHeight = AgentPanelMetrics.rowHeight
    private static let rowHeight = AgentPanelMetrics.rowHeight
    private static let visibleRows = 4
    private let card = AgentSurfaceCard(style: .agentPanel)
    /// The paused queue's header: a pause mark in the rows' icon column, then why.
    private let pauseIcon = NSImageView()
    private let title = makeLabel("", font: AgentPanelMetrics.detailFont)
    private let resume = PillButton("Resume", style: .plain)
    private let scroll = NSScrollView()
    private let rows = AgentFlippedView()
    private var prompts: [AgentQueuedPrompt] = []
    private var paused = false
    private var enabled = true
    private var signature = ""
    private var rowViews: [String: AgentQueueRow] = [:]
    private(set) var preferredHeight: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = rows
        resume.onPress = { [weak self] in self?.onResume?() }
        addSubview(card)
        for view in [pauseIcon, title, resume, scroll] as [NSView] {
            card.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var headerHeight: CGFloat { paused ? Self.headerHeight : 0 }

    func update(_ queued: [AgentQueuedPrompt], paused: Bool, enabled: Bool) {
        // A prompt being delivered already shows in the conversation; listing it here
        // too would flash this card over the composer on every send.
        let prompts = queued.filter { $0.state != .delivering }
        // Resume only means something while a prompt waits to be sent.
        let paused = paused && prompts.contains { $0.state == .queued }
        let signature = prompts.map { "\($0.id):\($0.revision):\($0.state):\(unsavedEdits.contains($0.id))" }.joined(separator: ",") + "|\(paused)|\(enabled)"
        guard self.signature != signature else { return }
        self.signature = signature
        self.prompts = prompts
        self.paused = paused
        self.enabled = enabled
        isHidden = prompts.isEmpty
        let visible = CGFloat(min(prompts.count, Self.visibleRows))
        preferredHeight = prompts.isEmpty ? 0 : headerHeight + visible * Self.rowHeight + Self.inset * 2
        title.stringValue = "Paused · Queued prompts wait until you resume"
        title.isHidden = !paused
        pauseIcon.isHidden = !paused
        resume.isHidden = !paused
        resume.isEnabled = enabled
        rebuildRows()
        applyColors()
        needsLayout = true
    }

    private func rebuildRows() {
        let ids = Set(prompts.map(\.id))
        for id in Array(rowViews.keys) where !ids.contains(id) {
            rowViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        for (offset, prompt) in prompts.enumerated() {
            let row = rowViews[prompt.id] ?? AgentQueueRow()
            rowViews[prompt.id] = row
            if row.superview == nil { rows.addSubview(row) }
            if row.actions.isEmpty {
                row.actions = [(.pencil, "Edit queued prompt"), (.chevronUp, "Move earlier in queue"),
                               (.arrowUp, "Send now"), (.trash, "Remove queued prompt")].map { icon, title in
                    let button = AgentIconButton(icon: icon, label: title, iconSize: 13)
                    button.onFocusChange = { [weak row] focused in row?.actionFocused = focused }
                    return button
                }
            }
            let files = prompt.attachments.count
            let attachmentText = files == 0 ? "" : files == 1 ? "1 attachment" : "\(files) attachments"
            row.text.stringValue = prompt.text.isEmpty ? attachmentText : prompt.text.replacingOccurrences(of: "\n", with: " ")
            row.text.toolTip = prompt.error ?? prompt.text
            row.detail.stringValue = prompt.text.isEmpty ? "" : attachmentText
            row.needsReview = prompt.state == .uncertain || prompt.state == .failed
            row.status.stringValue = row.needsReview ? "Needs review"
                : unsavedEdits.contains(prompt.id) ? "Edit not saved"
                : prompt.scheduledAt.map { "Sends " + AgentTurnTime.moment($0) } ?? ""
            row.status.toolTip = prompt.error
            row.status.setAccessibilityHelp(prompt.error)
            let earlier = prompt.state == .queued ? prompts.prefix(offset).last(where: { $0.state == .queued }) : nil
            for button in row.actions { button.isEnabled = enabled }
            row.actions[0].onPress = { [weak self] in self?.onEdit?(prompt) }
            row.actions[1].isHidden = earlier == nil
            row.actions[1].onPress = { [weak self] in if let earlier { self?.onMove?(prompt, earlier.id) } }
            row.actions[2].onPress = { [weak self] in self?.onDeliver?(prompt) }
            let deliveryLabel = row.needsReview ? "Review and retry delivery" : "Send now"
            row.actions[2].toolTip = deliveryLabel
            row.actions[2].setAccessibilityLabel(deliveryLabel)
            row.actions[3].onPress = { [weak self] in self?.onRemove?(prompt) }
            row.apply(theme)
        }
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        let inset = Self.inset
        let metrics = AgentPanelMetrics.self
        let headerMid = inset + Self.headerHeight / 2
        let resumeWidth = resume.isHidden ? 0 : ceil(resume.fittingSize.width)
        resume.frame = NSRect(x: bounds.width - inset - 4 - resumeWidth, y: floor(headerMid - 12), width: resumeWidth, height: 24)
        pauseIcon.frame = NSRect(x: inset + metrics.iconX, y: floor(headerMid - metrics.iconSide / 2), width: metrics.iconSide, height: metrics.iconSide)
        let titleX = inset + metrics.textX
        let titleHeight = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: titleX, y: floor(headerMid - titleHeight / 2),
                             width: max(0, resume.frame.minX - metrics.textGap - titleX), height: titleHeight)
        let top = inset + headerHeight
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top - inset))
        let width = max(1, scroll.contentSize.width)
        for (index, prompt) in prompts.enumerated() {
            guard let row = rowViews[prompt.id] else { continue }
            row.frame = NSRect(x: inset, y: CGFloat(index) * Self.rowHeight, width: width - inset * 2, height: Self.rowHeight)
        }
        rows.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.subviews.count) * Self.rowHeight)
    }

    private func applyColors() {
        title.textColor = theme.fgMuted
        pauseIcon.image = AppIcon.pauseCircle.image(size: AgentPanelMetrics.glyphSize, color: theme.warning)
        resume.setTitleColor(theme.fg)
        for case let row as AgentQueueRow in rows.subviews { row.apply(theme) }
    }

    override func themeDidChange() {
        appearance = theme.nsAppearance
        card.theme = theme
        applyColors()
    }
}

/// One queued prompt, styled like the conversation's text. Its actions appear on hover,
/// and stay visible while it needs review.
@MainActor
private final class AgentQueueRow: NSView {
    let icon = NSImageView()
    let text = makeLabel("", font: AgentPanelMetrics.titleFont)
    let detail = makeLabel("", font: AgentPanelMetrics.detailFont)
    let status = makeLabel("", font: AgentPanelMetrics.detailFont)
    var needsReview = false
    var actionFocused = false { didSet { updateHover() } }
    var actions: [AgentIconButton] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            actions.forEach { addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = true }
            updateHover()
        }
    }
    private var theme: AppTheme = .shared
    private var hovered = false { didSet { if hovered != oldValue { updateHover() } } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = AgentPanelMetrics.rowRadius
        layer?.cornerCurve = .continuous
        text.lineBreakMode = .byTruncatingTail
        for view in [icon, text, detail, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private func updateHover() {
        // Hidden actions stay in the accessibility tree and keyboard loop; only their ink fades.
        actions.forEach { $0.alphaValue = showsActions ? 1 : 0 }
        needsLayout = true
        layer?.backgroundColor = hovered ? theme.fg.withAlphaComponent(0.05).cgColor : nil
    }

    private var showsActions: Bool { hovered || needsReview || actionFocused }

    func apply(_ theme: AppTheme) {
        self.theme = theme
        icon.image = AppIcon.history.image(size: AgentPanelMetrics.glyphSize, color: theme.fgDim)
        text.textColor = theme.fg
        detail.textColor = theme.fgDim
        status.textColor = needsReview ? theme.warning : theme.fgMuted
        actions.forEach { $0.chatTheme = theme }
        updateHover()
    }

    override func layout() {
        super.layout()
        let button: CGFloat = 26
        var right = bounds.width - 3
        for view in actions.reversed() where !view.isHidden {
            right -= button
            view.frame = NSRect(x: right, y: floor((bounds.height - button) / 2), width: button, height: button)
        }
        // Hidden actions give their room back to the prompt's text.
        right = showsActions ? right - 6 : bounds.width - 10
        let metrics = AgentPanelMetrics.self
        for label in [status, detail] where !label.stringValue.isEmpty {
            let width = label.singleLineWidth
            let height = ceil(label.intrinsicContentSize.height)
            right -= width
            label.frame = NSRect(x: right, y: floor((bounds.height - height) / 2), width: width, height: height)
            right -= metrics.textGap
        }
        status.isHidden = status.stringValue.isEmpty
        detail.isHidden = detail.stringValue.isEmpty
        icon.frame = NSRect(x: metrics.iconX, y: floor((bounds.height - metrics.iconSide) / 2), width: metrics.iconSide, height: metrics.iconSide)
        let textHeight = ceil(text.intrinsicContentSize.height)
        text.frame = NSRect(x: metrics.textX, y: floor((bounds.height - textHeight) / 2), width: max(0, right - metrics.textX), height: textHeight)
    }
}

/// A form retains local edits while unrelated streaming snapshots arrive.
@MainActor
final class AgentQuestionView: ThemedView, NSTextFieldDelegate {
    var onAnswer: ((String, [String: [String]], Bool) -> Void)?
    /// Sends one of the request's own decisions other than submit and cancel, such as an
    /// MCP form's Decline: the request's ID and the decision's.
    var onDecision: ((String, String) -> Void)?
    var onChange: (() -> Void)?
    /// Lines the form's text up with the other panels' icon column.
    private static let inset = AgentPanelMetrics.inset + AgentPanelMetrics.iconX
    private static let footerHeight: CGFloat = 48
    private let card = AgentSurfaceCard(style: .agentPanel)
    private let scroll = NSScrollView()
    private let content = AgentFlippedView()
    private let submit = PillButton("Submit answers", style: .primary)
    private let cancel = PillButton("Cancel", style: .plain)
    private let decline = PillButton("Decline", style: .normal)
    private var declineDecision: String?
    /// The request whose saved answers were put back; later snapshots never overwrite edits.
    private var restoredRequest: String?
    private let error = makeLabel("", font: AppFont.footnote)
    private var blocks: [AgentQuestionBlock] = []
    private var requestID: String?
    private var form: AgentQuestionnaire?
    private var choices: [String: [NSButton]] {
        Dictionary(uniqueKeysWithValues: blocks.map { ($0.question.id, $0.choices) })
    }
    private var fields: [String: NSTextField] {
        Dictionary(uniqueKeysWithValues: blocks.map { ($0.question.id, $0.field) })
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        scroll.documentView = content
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        error.lineBreakMode = .byTruncatingTail
        addSubview(card)
        decline.isHidden = true
        for view in [scroll, submit, cancel, decline, error] as [NSView] {
            card.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = true
        }
        submit.onPress = { [weak self] in self?.answer(cancelled: false) }
        cancel.onPress = { [weak self] in self?.answer(cancelled: true) }
        decline.onPress = { [weak self] in
            guard let self, let requestID = self.requestID, let decision = self.declineDecision else { return }
            self.onDecision?(requestID, decision)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The form's full height at `width`; the pane caps it and the form scrolls.
    func preferredHeight(for width: CGFloat) -> CGFloat {
        guard form != nil else { return 0 }
        return Self.inset + contentHeight(width: width - Self.inset * 2) + Self.footerHeight
    }

    func update(_ item: AgentChatItem?, enabled: Bool) {
        submit.isEnabled = enabled
        cancel.isEnabled = enabled
        decline.isEnabled = enabled
        blocks.forEach { $0.isEnabled = enabled }
        guard requestID != item?.id || form != item?.questionnaire else { return }
        requestID = item?.id
        form = item?.questionnaire
        // An MCP form offers its own submit, decline and cancel; a question form the usual two.
        let offered = item?.approval
        declineDecision = offered?.first(.decline)?.id
        decline.title = offered?.first(.decline)?.title ?? "Decline"
        decline.toolTip = offered?.first(.decline)?.consequence
        decline.isHidden = declineDecision == nil
        submit.title = offered?.first(.submit)?.title ?? "Submit answers"
        submit.toolTip = offered?.first(.submit)?.consequence
        cancel.title = offered?.first(.cancel)?.title ?? "Cancel"
        cancel.toolTip = offered?.first(.cancel)?.consequence
        blocks.forEach { $0.removeFromSuperview() }
        blocks = []
        error.stringValue = ""
        guard let form else { isHidden = true; return }
        isHidden = false
        blocks = form.questions.map { question in
            let block = AgentQuestionBlock(question: question, target: self, action: #selector(choiceChanged(_:)))
            block.field.delegate = self
            block.isEnabled = enabled
            content.addSubview(block)
            return block
        }
        applyColors()
        needsLayout = true
    }

    var answers: [String: [String]] {
        guard let form else { return [:] }
        return Dictionary(uniqueKeysWithValues: form.questions.map { q in
            var values = (choices[q.id] ?? []).filter { $0.state == .on }.map(\.title)
            let text = fields[q.id]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { values = q.multiple ? values + [text] : [text] }
            return (q.id, values)
        })
    }

    /// Secrets are deliberately excluded from persisted local form drafts.
    var savedAnswers: [String: [String: [String]]] {
        guard let requestID, let form else { return [:] }
        let secrets = Set(form.questions.filter(\.secret).map(\.id))
        return [requestID: answers.filter { !secrets.contains($0.key) }]
    }

    /// Puts a form's saved answers back once, when it is first shown; edits made since
    /// are never replaced by an older draft.
    func restore(_ saved: [String: [String: [String]]]) {
        guard let requestID, restoredRequest != requestID, let values = saved[requestID] else { return }
        restoredRequest = requestID
        for (id, answers) in values {
            guard let block = blocks.first(where: { $0.question.id == id }) else { continue }
            let labels = Set(block.choices.map(\.title))
            let written = answers.filter { !labels.contains($0) }.joined(separator: ", ")
            // A single choice is either an option or a written answer, never both.
            let chosen = block.question.multiple || written.isEmpty ? answers : []
            block.choices.forEach { $0.state = chosen.contains($0.title) ? .on : .off }
            block.field.stringValue = written
        }
    }

    @objc private func choiceChanged(_ sender: NSButton) {
        guard let block = blocks.first(where: { $0.choices.contains(sender) }) else { return }
        restoredRequest = requestID
        if !block.question.multiple, sender.state == .on {
            block.choices.filter { $0 !== sender }.forEach { $0.state = .off }
            block.field.stringValue = ""
        }
        error.stringValue = ""
        onChange?()
    }

    func controlTextDidChange(_ obj: Notification) {
        // Writing an answer to a single-choice question replaces the chosen option, so
        // what the form shows is what it sends.
        restoredRequest = requestID
        if let field = obj.object as? NSTextField, let block = blocks.first(where: { $0.field === field }),
           !block.question.multiple, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            block.choices.forEach { $0.state = .off }
        }
        error.stringValue = ""
        needsLayout = true
        onChange?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Return adds a line to a written answer; the Submit Answers shortcut sends the form.
        guard commandSelector == #selector(NSResponder.insertNewline(_:)), !(control is NSSecureTextField) else { return false }
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    /// Submits the answers as the Submit button does; false when there's no form to submit.
    @discardableResult
    func submitAnswers() -> Bool {
        guard !isHidden, form != nil, submit.isEnabled else { return false }
        answer(cancelled: false)
        return true
    }

    private func answer(cancelled: Bool) {
        guard let requestID, let form else { return }
        do { try form.validate(answers: answers, cancelled: cancelled) } catch {
            self.error.stringValue = "Answer each required question first."
            self.error.toolTip = self.error.stringValue
            self.error.setAccessibilityValue(self.error.stringValue)
            if let block = blocks.first(where: { $0.question.required && (answers[$0.question.id]?.isEmpty ?? true) }) {
                block.scrollToVisible(block.bounds)
                window?.makeFirstResponder(block.choices.first ?? block.field)
            }
            NSAccessibility.post(element: self.error, notification: .announcementRequested,
                                 userInfo: [.announcement: self.error.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            return
        }
        onAnswer?(requestID, cancelled ? [:] : answers, cancelled)
    }

    private func contentHeight(width: CGFloat) -> CGFloat {
        guard !blocks.isEmpty else { return 0 }
        return blocks.reduce(CGFloat(0)) { $0 + $1.height(for: width) } + CGFloat(blocks.count - 1) * 18
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        let inset = Self.inset
        let width = max(1, bounds.width - inset * 2)
        let buttonY = bounds.height - 12 - 28
        let submitWidth = ceil(submit.fittingSize.width) + 8
        let cancelWidth = ceil(cancel.fittingSize.width)
        submit.frame = NSRect(x: bounds.width - inset - submitWidth, y: buttonY, width: submitWidth, height: 28)
        cancel.frame = NSRect(x: submit.frame.minX - 6 - cancelWidth, y: buttonY, width: cancelWidth, height: 28)
        let declineWidth = decline.isHidden ? 0 : ceil(decline.fittingSize.width) + 8
        decline.frame = NSRect(x: cancel.frame.minX - 6 - declineWidth, y: buttonY, width: declineWidth, height: 28)
        let leading = decline.isHidden ? cancel.frame.minX : decline.frame.minX
        error.frame = NSRect(x: inset, y: buttonY + 6, width: max(0, leading - inset - 8), height: 16)
        scroll.frame = NSRect(x: 0, y: inset, width: bounds.width, height: max(0, buttonY - inset - 8))
        var y: CGFloat = 0
        for block in blocks {
            let height = block.height(for: width)
            block.frame = NSRect(x: inset, y: y, width: width, height: height)
            y += height + 18
        }
        content.frame = NSRect(x: 0, y: 0, width: max(1, scroll.contentSize.width), height: max(1, y - 18))
    }

    private func applyColors() {
        error.textColor = theme.danger
        cancel.setTitleColor(theme.fgMuted)
        decline.setTitleColor(theme.fg)
        blocks.forEach { $0.apply(theme) }
    }

    override func themeDidChange() {
        appearance = theme.nsAppearance
        card.theme = theme
        applyColors()
    }
}

/// One question: its title, native radio buttons or checkboxes with descriptions, and a free answer.
@MainActor
private final class AgentQuestionBlock: NSView {
    let question: AgentQuestionnaire.Question
    let title: NSTextField
    let choices: [NSButton]
    let details: [NSTextField?]
    let field: NSTextField
    private static let choiceIndent: CGFloat = 20

    override var isFlipped: Bool { true }

    var isEnabled = true {
        didSet {
            choices.forEach { $0.isEnabled = isEnabled }
            field.isEnabled = isEnabled
        }
    }

    init(question: AgentQuestionnaire.Question, target: AnyObject, action: Selector) {
        self.question = question
        title = NSTextField(wrappingLabelWithString: question.title)
        title.font = AppFont.bodyMedium
        choices = question.options.map { option in
            let button = question.multiple
                ? NSButton(checkboxWithTitle: option.label, target: target, action: action)
                : NSButton(radioButtonWithTitle: option.label, target: target, action: action)
            button.font = AppFont.body
            button.toolTip = option.description
            button.setAccessibilityHelp(option.description)
            return button
        }
        details = question.options.map { option in
            guard let description = option.description, !description.isEmpty else { return nil }
            let label = NSTextField(wrappingLabelWithString: description)
            label.font = AppFont.small
            return label
        }
        field = question.secret ? NSSecureTextField() : NSTextField()
        field.bezelStyle = .roundedBezel
        if !question.secret {
            // A written answer can run to several lines; Return adds one, Command-Return submits.
            field.usesSingleLineMode = false
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.lineBreakMode = .byWordWrapping
        }
        field.font = AppFont.body
        field.placeholderString = question.options.isEmpty ? "Your answer" : "Or write your own answer"
        field.setAccessibilityLabel(question.title)
        super.init(frame: .zero)
        var views: [NSView] = [title, field] + choices
        views += details.compactMap { $0 }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var titleText: NSAttributedString {
        let text = NSMutableAttributedString(string: question.title, attributes: [.font: AppFont.bodyMedium])
        if !question.required { text.append(NSAttributedString(string: "  Optional", attributes: [.font: AppFont.footnote])) }
        return text
    }

    func height(for width: CGFloat) -> CGFloat { place(width: width, apply: false) }

    override func layout() {
        super.layout()
        _ = place(width: bounds.width, apply: true)
    }

    /// Measures, and optionally positions, every control at `width`.
    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        func measure(_ text: NSAttributedString, _ width: CGFloat) -> CGFloat {
            ceil(text.boundingRect(with: NSSize(width: max(1, width), height: 100_000),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        var y: CGFloat = 0
        let titleHeight = max(17, measure(title.attributedStringValue, width))
        if apply { title.frame = NSRect(x: 0, y: y, width: width, height: titleHeight + 2) }
        y += titleHeight + 10
        let labelWidth = width - Self.choiceIndent
        for (button, detail) in zip(choices, details) {
            let labelHeight = max(18, measure(NSAttributedString(string: button.title, attributes: [.font: AppFont.body]), labelWidth))
            if apply { button.frame = NSRect(x: 0, y: y, width: width, height: labelHeight + 2) }
            y += labelHeight + 2
            if let detail {
                let detailHeight = measure(detail.attributedStringValue, labelWidth)
                if apply { detail.frame = NSRect(x: Self.choiceIndent, y: y, width: labelWidth, height: detailHeight + 2) }
                y += detailHeight + 2
            }
            y += 8
        }
        let fieldHeight = question.secret ? 26 : min(92, max(26, measure(NSAttributedString(string: field.stringValue.isEmpty ? " " : field.stringValue,
                                                                                         attributes: [.font: AppFont.body]), width - 10) + 9))
        if apply { field.frame = NSRect(x: 0, y: y, width: width, height: fieldHeight) }
        return y + fieldHeight
    }

    func apply(_ theme: AppTheme) {
        let text = NSMutableAttributedString(attributedString: titleText)
        text.addAttribute(.foregroundColor, value: theme.fg, range: NSRange(location: 0, length: text.length))
        if !question.required {
            let optional = (text.string as NSString).range(of: "  Optional", options: .backwards)
            text.addAttribute(.foregroundColor, value: theme.fgDim, range: optional)
        }
        title.attributedStringValue = text
        for button in choices {
            button.cell?.wraps = true
            button.cell?.lineBreakMode = .byWordWrapping
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: AppFont.body, .foregroundColor: theme.fg])
        }
        details.compactMap { $0 }.forEach { $0.textColor = theme.fgMuted }
        field.textColor = theme.fg
    }
}

@MainActor
private final class AgentFlippedView: NSView {
    override var isFlipped: Bool { true }
}
