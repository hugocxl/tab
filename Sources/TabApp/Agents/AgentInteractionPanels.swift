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
    /// Accent outline while a file drag can drop here.
    var highlighted = false { didSet { needsDisplay = true } }

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
        layer.borderColor = (highlighted ? theme.accent : theme.fg.withAlphaComponent(theme.palette.isLight ? 0.10 : 0.12)).cgColor
        // Enough of the theme's composer color to keep text legible over a busy transcript,
        // while the conversation still reads through the glass.
        fill.layer?.backgroundColor = theme.agentComposer.withAlphaComponent(theme.glassEnabled ? 0.45 : 0.82).cgColor
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

/// Prompts sent while the agent works, waiting above the composer until their turn.
@MainActor
final class AgentQueueView: ThemedView {
    var onEdit: ((AgentQueuedPrompt) -> Void)?
    var onRemove: ((AgentQueuedPrompt) -> Void)?
    var onDeliver: ((AgentQueuedPrompt) -> Void)?
    var onMove: ((AgentQueuedPrompt, String) -> Void)?
    var onResume: (() -> Void)?
    private static let inset: CGFloat = 8
    private static let headerHeight: CGFloat = 30
    private static let rowHeight: CGFloat = 32
    private static let visibleRows = 4
    private let card = AgentSurfaceCard(style: .agentPanel)
    private let title = makeLabel("", font: AppFont.small)
    private let resume = PillButton("Resume", style: .plain)
    private let scroll = NSScrollView()
    private let rows = AgentFlippedView()
    private var prompts: [AgentQueuedPrompt] = []
    private var paused = false
    private var enabled = true
    private var signature = ""
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
        for view in [title, resume, scroll] as [NSView] {
            card.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var headerHeight: CGFloat { paused ? Self.headerHeight : 0 }

    func update(_ prompts: [AgentQueuedPrompt], paused: Bool, enabled: Bool) {
        let signature = prompts.map { "\($0.id):\($0.revision):\($0.state)" }.joined(separator: ",") + "|\(paused)|\(enabled)"
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
        resume.isHidden = !paused
        resume.isEnabled = enabled
        rebuildRows()
        applyColors()
        needsLayout = true
    }

    private func rebuildRows() {
        rows.subviews.forEach { $0.removeFromSuperview() }
        for (offset, prompt) in prompts.enumerated() {
            let earlier = prompt.state == .queued ? prompts.prefix(offset).last(where: { $0.state == .queued }) : nil
            rows.addSubview(makeRow(prompt, earlier: earlier))
        }
    }

    private func makeRow(_ prompt: AgentQueuedPrompt, earlier: AgentQueuedPrompt?) -> AgentQueueRow {
        let row = AgentQueueRow()
        let files = prompt.attachments.count
        let attachmentText = files == 0 ? "" : files == 1 ? "1 attachment" : "\(files) attachments"
        row.text.stringValue = prompt.text.isEmpty ? attachmentText : prompt.text.replacingOccurrences(of: "\n", with: " ")
        row.text.toolTip = prompt.error ?? prompt.text
        row.detail.stringValue = prompt.text.isEmpty ? "" : attachmentText
        row.needsReview = prompt.state == .uncertain || prompt.state == .failed
        switch prompt.state {
        case .delivering: row.status.stringValue = "Sending…"
        case .uncertain, .failed: row.status.stringValue = "Needs review"
        default: row.status.stringValue = ""
        }
        row.status.toolTip = prompt.error
        guard prompt.state != .delivering else { return row }
        var actions: [AgentIconButton] = []
        actions.append(action(.pencil, "Edit queued prompt") { [weak self] in self?.onEdit?(prompt) })
        if let earlier {
            actions.append(action(.chevronUp, "Move earlier in queue") { [weak self] in self?.onMove?(prompt, earlier.id) })
        }
        actions.append(action(.arrowUp, row.needsReview ? "Review and retry delivery" : "Send now") { [weak self] in self?.onDeliver?(prompt) })
        actions.append(action(.trash, "Remove queued prompt") { [weak self] in self?.onRemove?(prompt) })
        row.actions = actions
        return row
    }

    private func action(_ icon: AppIcon, _ title: String, press: @escaping () -> Void) -> AgentIconButton {
        let button = AgentIconButton(icon: icon, label: title, iconSize: 13)
        button.onPress = press
        button.isEnabled = enabled
        button.chatTheme = theme
        return button
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        let inset = Self.inset
        let resumeWidth = resume.isHidden ? 0 : ceil(resume.fittingSize.width)
        resume.frame = NSRect(x: bounds.width - inset - 4 - resumeWidth, y: inset + 3, width: resumeWidth, height: 24)
        title.frame = NSRect(x: inset + 8, y: inset + 7, width: max(0, bounds.width - inset * 2 - resumeWidth - 20), height: 16)
        let top = inset + headerHeight
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top - inset))
        let width = max(1, scroll.contentSize.width)
        for (index, row) in rows.subviews.enumerated() {
            row.frame = NSRect(x: inset, y: CGFloat(index) * Self.rowHeight, width: width - inset * 2, height: Self.rowHeight)
        }
        rows.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.subviews.count) * Self.rowHeight)
    }

    private func applyColors() {
        title.textColor = theme.fgMuted
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
    let text = makeLabel("", font: AppFont.body)
    let detail = makeLabel("", font: AppFont.small)
    let status = makeLabel("", font: AppFont.small)
    var needsReview = false
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
        layer?.cornerRadius = 8
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

    private var showsActions: Bool { hovered || needsReview }

    func apply(_ theme: AppTheme) {
        self.theme = theme
        icon.image = AppIcon.history.image(size: 14, color: theme.fgDim)
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
        for view in actions.reversed() {
            right -= button
            view.frame = NSRect(x: right, y: floor((bounds.height - button) / 2), width: button, height: button)
        }
        // Hidden actions give their room back to the prompt's text.
        right = showsActions ? right - 6 : bounds.width - 10
        for label in [status, detail] where !label.stringValue.isEmpty {
            let width = ceil(label.intrinsicContentSize.width)
            right -= width
            label.frame = NSRect(x: right, y: floor((bounds.height - 16) / 2), width: width, height: 16)
            right -= 10
        }
        status.isHidden = status.stringValue.isEmpty
        detail.isHidden = detail.stringValue.isEmpty
        icon.frame = NSRect(x: 8, y: floor((bounds.height - 14) / 2), width: 14, height: 14)
        text.frame = NSRect(x: 30, y: floor((bounds.height - 17) / 2), width: max(0, right - 30), height: 17)
    }
}

/// A form retains local edits while unrelated streaming snapshots arrive.
@MainActor
final class AgentQuestionView: ThemedView, NSTextFieldDelegate {
    var onAnswer: ((String, [String: [String]], Bool) -> Void)?
    var onChange: (() -> Void)?
    private static let inset: CGFloat = 16
    private static let footerHeight: CGFloat = 48
    private let card = AgentSurfaceCard(style: .agentPanel)
    private let scroll = NSScrollView()
    private let content = AgentFlippedView()
    private let submit = PillButton("Submit answers", style: .primary)
    private let cancel = PillButton("Cancel", style: .plain)
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
        for view in [scroll, submit, cancel, error] as [NSView] {
            card.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = true
        }
        submit.onPress = { [weak self] in self?.answer(cancelled: false) }
        cancel.onPress = { [weak self] in self?.answer(cancelled: true) }
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
        blocks.forEach { $0.isEnabled = enabled }
        guard requestID != item?.id || form != item?.questionnaire else { return }
        requestID = item?.id
        form = item?.questionnaire
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

    func restore(_ saved: [String: [String: [String]]]) {
        guard let requestID, let values = saved[requestID] else { return }
        for (id, answers) in values {
            let buttons = choices[id] ?? []
            buttons.forEach { $0.state = answers.contains($0.title) ? .on : .off }
            let labels = Set(buttons.map(\.title))
            fields[id]?.stringValue = answers.filter { !labels.contains($0) }.joined(separator: ", ")
        }
    }

    @objc private func choiceChanged(_ sender: NSButton) {
        guard let block = blocks.first(where: { $0.choices.contains(sender) }) else { return }
        if !block.question.multiple, sender.state == .on {
            block.choices.filter { $0 !== sender }.forEach { $0.state = .off }
            block.field.stringValue = ""
        }
        error.stringValue = ""
        onChange?()
    }

    func controlTextDidChange(_ obj: Notification) {
        error.stringValue = ""
        onChange?()
    }

    private func answer(cancelled: Bool) {
        guard let requestID, let form else { return }
        do { try form.validate(answers: answers, cancelled: cancelled) } catch {
            self.error.stringValue = "Answer each required question first."
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
        error.frame = NSRect(x: inset, y: buttonY + 6, width: max(0, cancel.frame.minX - inset - 8), height: 16)
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
        if apply { field.frame = NSRect(x: 0, y: y, width: width, height: 26) }
        return y + 26
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
