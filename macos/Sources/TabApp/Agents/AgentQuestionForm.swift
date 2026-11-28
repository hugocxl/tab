import AppKit
import TabCore
import TabProtocol

/// The agent's questions above the composer: each question's options as cards, a written
/// answer, and the form's own decisions. A form retains local edits while unrelated
/// streaming snapshots arrive.
@MainActor
final class AgentQuestionView: ThemedView, NSTextFieldDelegate {
    var onAnswer: ((String, [String: [String]], Bool) -> Void)?
    /// Sends one of the request's own decisions other than submit and cancel, such as an
    /// MCP form's Decline: the request's ID and the decision's.
    var onDecision: ((String, String) -> Void)?
    var onChange: (() -> Void)?
    /// The Submit Answers shortcut as the user's keymap shows it, for the footer's hint.
    var submitKey: String? { didSet { if submitKey != oldValue { updateFooter() } } }
    /// Option cards line up with the other panels' rows, and text with their icon column.
    private static let inset = AgentPanelMetrics.inset
    private static let questionGap: CGFloat = 28
    private static let footerHeight: CGFloat = 48
    private let card = AgentSurfaceCard(style: .agentPanel)
    private let scroll = NSScrollView()
    private let content = AgentFlippedView()
    private let footerRule = NSView()
    private let submit = PillButton("Submit answers", style: .primary)
    private let cancel = PillButton("Cancel", style: .plain)
    private let decline = PillButton("Decline", style: .normal)
    private var declineDecision: String?
    /// The request whose saved answers were put back; later snapshots never overwrite edits.
    private var restoredRequest: String?
    /// The form's progress and shortcut, or why it can't be sent yet.
    private let status = makeLabel("", font: AppFont.footnote)
    private var failed = false
    private var blocks: [AgentQuestionBlock] = []
    private var dividers: [NSView] = []
    private var requestID: String?
    private var form: AgentQuestionnaire?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        scroll.documentView = content
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        footerRule.wantsLayer = true
        status.lineBreakMode = .byTruncatingTail
        addSubview(card)
        decline.isHidden = true
        for view in [scroll, footerRule, submit, cancel, decline, status] as [NSView] {
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
        return Self.inset * 2 + contentHeight(width: width - Self.inset * 2) + Self.footerHeight
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
        dividers.forEach { $0.removeFromSuperview() }
        blocks = []
        dividers = []
        failed = false
        guard let form else { isHidden = true; return }
        isHidden = false
        let count = form.questions.count
        blocks = form.questions.enumerated().map { index, question in
            let block = AgentQuestionBlock(question: question, position: count > 1 ? (index + 1, count) : nil,
                                           target: self, action: #selector(choiceChanged(_:)))
            block.field.delegate = self
            block.isEnabled = enabled
            content.addSubview(block)
            return block
        }
        dividers = (1..<max(1, count)).map { _ in
            let line = NSView()
            line.wantsLayer = true
            content.addSubview(line)
            return line
        }
        applyColors()
        updateFooter()
        needsLayout = true
    }

    var answers: [String: [String]] {
        Dictionary(uniqueKeysWithValues: blocks.map { ($0.question.id, $0.answer) })
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
            block.refresh()
        }
        updateFooter()
        needsLayout = true
    }

    @objc private func choiceChanged(_ sender: NSButton) {
        guard let block = blocks.first(where: { $0.choices.contains { $0 === sender } }) else { return }
        restoredRequest = requestID
        if !block.question.multiple, sender.state == .on {
            block.choices.filter { $0 !== sender }.forEach { $0.state = .off }
            block.field.stringValue = ""
            needsLayout = true
        }
        block.refresh()
        failed = false
        updateFooter()
        onChange?()
    }

    func controlTextDidChange(_ obj: Notification) {
        // Writing an answer to a single-choice question replaces the chosen option, so
        // what the form shows is what it sends.
        restoredRequest = requestID
        if let field = obj.object as? NSTextField, let block = blocks.first(where: { $0.field === field }) {
            if !block.question.multiple, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                block.choices.forEach { $0.state = .off }
            }
            block.refresh()
        }
        failed = false
        updateFooter()
        needsLayout = true
        onChange?()
    }

    func controlTextDidBeginEditing(_ obj: Notification) { focusChanged(obj, editing: true) }
    func controlTextDidEndEditing(_ obj: Notification) { focusChanged(obj, editing: false) }

    private func focusChanged(_ obj: Notification, editing: Bool) {
        guard let field = obj.object as? NSTextField, let block = blocks.first(where: { $0.field === field }) else { return }
        block.fieldFocused = editing
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
            failed = true
            updateFooter()
            if let block = blocks.first(where: { $0.question.required && $0.answer.isEmpty }) {
                content.scrollToVisible(block.frame)
                window?.makeFirstResponder(block.choices.first ?? block.field)
            }
            NSAccessibility.post(element: status, notification: .announcementRequested,
                                 userInfo: [.announcement: status.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            return
        }
        onAnswer?(requestID, cancelled ? [:] : answers, cancelled)
    }

    /// The footer says how far the form is, how to send it, or what it still needs.
    private func updateFooter() {
        if failed {
            let missing = blocks.filter { $0.question.required && $0.answer.isEmpty }.count
            status.stringValue = missing == 1 && blocks.count > 1 ? "One required question has no answer yet."
                : missing > 1 ? "\(missing) required questions have no answer yet." : "Answer each required question first."
        } else {
            var parts: [String] = []
            if blocks.count > 1 { parts.append("\(blocks.filter { !$0.answer.isEmpty }.count) of \(blocks.count) answered") }
            if let submitKey { parts.append("\(submitKey) to submit") }
            status.stringValue = parts.joined(separator: " · ")
        }
        status.toolTip = status.stringValue
        status.setAccessibilityValue(status.stringValue)
        status.textColor = failed ? theme.danger : theme.fgDim
    }

    private func contentHeight(width: CGFloat) -> CGFloat {
        guard !blocks.isEmpty else { return 0 }
        return blocks.reduce(CGFloat(0)) { $0 + $1.height(for: width) } + CGFloat(blocks.count - 1) * Self.questionGap
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        let inset = Self.inset
        let width = max(1, bounds.width - inset * 2)
        let buttonY = bounds.height - 10 - 28
        let submitWidth = ceil(submit.fittingSize.width) + 8
        let cancelWidth = ceil(cancel.fittingSize.width)
        let trailing = inset + AgentPanelMetrics.iconX - 4
        submit.frame = NSRect(x: bounds.width - trailing - submitWidth, y: buttonY, width: submitWidth, height: 28)
        cancel.frame = NSRect(x: submit.frame.minX - 6 - cancelWidth, y: buttonY, width: cancelWidth, height: 28)
        let declineWidth = decline.isHidden ? 0 : ceil(decline.fittingSize.width) + 8
        decline.frame = NSRect(x: cancel.frame.minX - 6 - declineWidth, y: buttonY, width: declineWidth, height: 28)
        let leading = decline.isHidden ? cancel.frame.minX : decline.frame.minX
        let textX = inset + AgentPanelMetrics.iconX
        status.frame = NSRect(x: textX, y: buttonY + 6, width: max(0, leading - textX - 8), height: 16)
        let footerTop = bounds.height - Self.footerHeight
        scroll.frame = NSRect(x: 0, y: inset, width: bounds.width, height: max(0, footerTop - inset))
        var y: CGFloat = 4
        for (index, block) in blocks.enumerated() {
            let height = block.height(for: width)
            block.frame = NSRect(x: inset, y: y, width: width, height: height)
            y += height
            if index < dividers.count {
                dividers[index].frame = NSRect(x: textX, y: y + floor(Self.questionGap / 2), width: max(0, width - AgentPanelMetrics.iconX * 2), height: 1)
                y += Self.questionGap
            }
        }
        content.frame = NSRect(x: 0, y: 0, width: max(1, scroll.contentSize.width), height: max(1, y + 4))
        // A hairline marks where the questions scroll under the footer, only when they do.
        footerRule.isHidden = content.frame.height <= scroll.frame.height + 1
        footerRule.frame = NSRect(x: 0, y: footerTop, width: bounds.width, height: 1)
    }

    private func applyColors() {
        cancel.setTitleColor(theme.fgMuted)
        decline.setTitleColor(theme.fg)
        footerRule.layer?.backgroundColor = theme.separator.cgColor
        dividers.forEach { $0.layer?.backgroundColor = theme.separator.cgColor }
        blocks.forEach { $0.apply(theme) }
        status.textColor = failed ? theme.danger : theme.fgDim
    }

    override func themeDidChange() {
        appearance = theme.nsAppearance
        card.theme = theme
        applyColors()
    }
}

/// One question: a line of its header and position, its title, an option card per choice
/// and a written answer.
@MainActor
private final class AgentQuestionBlock: NSView {
    let question: AgentQuestionnaire.Question
    let meta: NSTextField
    let title: NSTextField
    let choices: [AgentQuestionOption]
    let answerBox: AgentAnswerBox
    var field: NSTextField { answerBox.field }
    private let position: (Int, Int)?
    private static let titleX = AgentPanelMetrics.iconX
    private static let optionGap: CGFloat = 4

    override var isFlipped: Bool { true }

    var isEnabled = true {
        didSet {
            choices.forEach { $0.isEnabled = isEnabled }
            field.isEnabled = isEnabled
        }
    }

    var fieldFocused: Bool {
        get { answerBox.focused }
        set { answerBox.focused = newValue }
    }

    /// What the question sends: its chosen options, then the written answer; a written
    /// answer to a single choice replaces the option.
    var answer: [String] {
        var values = choices.filter { $0.state == .on }.map(\.title)
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { values = question.multiple ? values + [text] : [text] }
        return values
    }

    init(question: AgentQuestionnaire.Question, position: (Int, Int)?, target: AnyObject, action: Selector) {
        self.question = question
        self.position = position
        meta = makeLabel("", font: AppFont.footnoteMedium)
        title = NSTextField(wrappingLabelWithString: question.title)
        title.font = AppFont.header
        title.isSelectable = true
        choices = question.options.map { AgentQuestionOption(option: $0, multiple: question.multiple, target: target, action: action) }
        answerBox = AgentAnswerBox(secret: question.secret)
        answerBox.field.placeholderString = question.options.isEmpty ? "Your answer" : "Or write your own answer"
        answerBox.field.setAccessibilityLabel(question.title)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(question.header ?? question.title)
        for view in [meta, title, answerBox] + choices as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The small line above the title: the provider's header, the question's place in
    /// the form, and how it is answered.
    private var metaParts: (header: String?, rest: String) {
        var rest: [String] = []
        if let position { rest.append("\(position.0) of \(position.1)") }
        if question.multiple, !question.options.isEmpty { rest.append("Choose any") }
        if !question.required { rest.append("Optional") }
        return (question.header, rest.joined(separator: " · "))
    }

    private var hasMeta: Bool { metaParts.header != nil || !metaParts.rest.isEmpty }

    /// Shows the answer's state after its options or text changed.
    func refresh() {
        answerBox.chosen = !question.multiple && !question.options.isEmpty
            && !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        choices.forEach { $0.needsDisplay = true }
    }

    func height(for width: CGFloat) -> CGFloat { place(width: width, apply: false) }

    override func layout() {
        super.layout()
        _ = place(width: bounds.width, apply: true)
    }

    /// Measures, and optionally positions, every control at `width`.
    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        var y: CGFloat = 0
        let textWidth = max(1, width - Self.titleX * 2)
        meta.isHidden = !hasMeta
        if hasMeta {
            if apply { meta.frame = NSRect(x: Self.titleX, y: y, width: textWidth, height: 15) }
            y += 15 + 4
        }
        let titleHeight = max(17, measureText(title.attributedStringValue, textWidth))
        if apply { title.frame = NSRect(x: Self.titleX - 2, y: y, width: textWidth + 4, height: titleHeight + 2) }
        y += titleHeight + 10
        for choice in choices {
            let height = choice.height(for: width)
            if apply { choice.frame = NSRect(x: 0, y: y, width: width, height: height) }
            y += height + Self.optionGap
        }
        if !choices.isEmpty { y += 2 }
        let boxHeight = answerBox.height(for: width)
        if apply { answerBox.frame = NSRect(x: 0, y: y, width: width, height: boxHeight) }
        return y + boxHeight
    }

    func apply(_ theme: AppTheme) {
        let parts = metaParts
        let line = NSMutableAttributedString()
        if let header = parts.header {
            line.append(NSAttributedString(string: header.uppercased(), attributes: [
                .font: AppFont.footnoteMedium, .foregroundColor: theme.accent, .kern: 0.4,
            ]))
        }
        if !parts.rest.isEmpty {
            line.append(NSAttributedString(string: (parts.header == nil ? "" : "  ·  ") + parts.rest,
                                           attributes: [.font: AppFont.footnote, .foregroundColor: theme.fgDim]))
        }
        meta.attributedStringValue = line
        title.textColor = theme.fg
        choices.forEach { $0.palette = theme }
        answerBox.apply(theme)
    }
}

/// One option of a question as a card: an indicator, its label, a Recommended badge when
/// the provider marks one, and its description; the whole card toggles. It stays a real
/// radio button or checkbox, so state, keyboard and accessibility come from AppKit, and
/// its title stays the provider's label, which is what the answer sends.
@MainActor
private final class AgentQuestionOption: NSButton {
    let option: AgentQuestionnaire.Option
    let multiple: Bool
    private let label: NSTextField
    private let detail: NSTextField?
    /// The label without a trailing "(Recommended)", which shows as a badge instead.
    private let shownLabel: String
    private let recommended: Bool
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    var palette: AppTheme = .shared { didSet { applyColors() } }

    private static let padX: CGFloat = AgentPanelMetrics.iconX
    private static let padY: CGFloat = 8
    private static let textX: CGFloat = AgentPanelMetrics.textX
    private static let indicator: CGFloat = 16
    private static let badgeText = "Recommended"
    private static var badgeSize: NSSize {
        let size = (badgeText as NSString).size(withAttributes: [.font: AppFont.footnoteMedium])
        return NSSize(width: ceil(size.width) + 14, height: 18)
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }
    override var state: NSControl.StateValue { didSet { applyColors() } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.55 } }

    init(option: AgentQuestionnaire.Option, multiple: Bool, target: AnyObject, action: Selector) {
        self.option = option
        self.multiple = multiple
        let (shown, recommended) = Self.split(option.label)
        shownLabel = shown
        self.recommended = recommended
        label = NSTextField(wrappingLabelWithString: shown)
        label.font = AppFont.bodyMedium
        if let description = option.description, !description.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: description)
            detail.font = AppFont.small
            self.detail = detail
        } else {
            detail = nil
        }
        super.init(frame: .zero)
        setButtonType(multiple ? .switch : .radio)
        isBordered = false
        title = option.label
        self.target = target
        self.action = action
        focusRingType = .default
        toolTip = option.description
        setAccessibilityHelp(option.description)
        for view in [label, detail].compactMap({ $0 }) {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A trailing "(Recommended)" in any case becomes the badge.
    private static func split(_ label: String) -> (String, Bool) {
        let suffix = "(recommended)"
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasSuffix(suffix) else { return (label, false) }
        let shown = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        return shown.isEmpty ? (label, false) : (shown, true)
    }

    /// The labels and badge sit in the card; a click anywhere on it is the button's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private var labelWidth: (CGFloat) -> CGFloat {
        { [recommended] width in max(1, width - Self.textX - Self.padX - (recommended ? Self.badgeSize.width + 8 : 0)) }
    }

    func height(for width: CGFloat) -> CGFloat {
        var height = Self.padY + max(Self.indicator, measureText(label.attributedStringValue, labelWidth(width)))
        if let detail { height += 2 + measureText(detail.attributedStringValue, max(1, width - Self.textX - Self.padX)) }
        return ceil(height + Self.padY)
    }

    override func layout() {
        super.layout()
        let labelHeight = measureText(label.attributedStringValue, labelWidth(bounds.width))
        label.frame = NSRect(x: Self.textX - 2, y: Self.padY, width: labelWidth(bounds.width) + 4, height: labelHeight + 1)
        if let detail {
            let width = max(1, bounds.width - Self.textX - Self.padX)
            let height = measureText(detail.attributedStringValue, width)
            detail.frame = NSRect(x: Self.textX - 2, y: Self.padY + max(Self.indicator, labelHeight) + 2, width: width + 4, height: height + 1)
        }
    }

    private func applyColors() {
        label.textColor = palette.fg
        detail?.textColor = state == .on ? palette.fgMuted : palette.fgDim
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = palette
        let selected = state == .on
        let radius = AgentPanelMetrics.rowRadius
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        let fill: NSColor = selected ? theme.accent.withAlphaComponent(isHighlighted ? 0.22 : 0.14)
            : isHighlighted ? theme.selection : hovered && isEnabled ? theme.rowFill : .clear
        fill.setFill()
        card.fill()
        (selected ? theme.accent.withAlphaComponent(0.6) : theme.rowBorder).setStroke()
        card.lineWidth = 1
        card.stroke()

        // The indicator centers on the label's first line.
        let lineHeight = ceil(AppFont.bodyMedium.ascender - AppFont.bodyMedium.descender + AppFont.bodyMedium.leading)
        let side = Self.indicator
        let box = NSRect(x: Self.padX, y: Self.padY + floor((lineHeight - side) / 2) + 1, width: side, height: side)
        if multiple {
            let shape = NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            if selected {
                theme.accent.setFill(); shape.fill()
                AppIcon.check.image(size: 10, theme: theme, tint: theme.accentForeground)?
                    .draw(in: box.insetBy(dx: 3, dy: 3), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                theme.fgDim.setStroke(); shape.lineWidth = 1.5; shape.stroke()
            }
        } else {
            let ring = NSBezierPath(ovalIn: box.insetBy(dx: 1, dy: 1))
            if selected {
                theme.accent.setFill(); ring.fill()
                theme.accentForeground.setFill()
                NSBezierPath(ovalIn: box.insetBy(dx: 5, dy: 5)).fill()
            } else {
                theme.fgDim.setStroke(); ring.lineWidth = 1.5; ring.stroke()
            }
        }

        if recommended {
            let size = Self.badgeSize
            let badge = NSRect(x: bounds.width - Self.padX - size.width, y: Self.padY + floor((lineHeight - size.height) / 2),
                               width: size.width, height: size.height)
            theme.accent.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: badge, xRadius: size.height / 2, yRadius: size.height / 2).fill()
            let text = NSAttributedString(string: Self.badgeText, attributes: [.font: AppFont.footnoteMedium, .foregroundColor: theme.accent])
            let textSize = text.size()
            text.draw(at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2))
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius = AgentPanelMetrics.rowRadius
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// The written answer: a borderless field in a card like the options', outlined in the
/// accent while it is edited or when it is the question's chosen answer.
@MainActor
private final class AgentAnswerBox: NSView {
    let field: NSTextField
    private let secret: Bool
    private var palette: AppTheme = .shared
    var focused = false { didSet { if focused != oldValue { needsDisplay = true } } }
    var chosen = false { didSet { if chosen != oldValue { needsDisplay = true } } }
    private static let padX: CGFloat = AgentPanelMetrics.iconX
    private static let padY: CGFloat = 7

    override var isFlipped: Bool { true }

    init(secret: Bool) {
        self.secret = secret
        field = secret ? NSSecureTextField() : NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AppFont.body
        if !secret {
            // A written answer can run to several lines; Return adds one, Command-Return submits.
            field.usesSingleLineMode = false
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.lineBreakMode = .byWordWrapping
        }
        super.init(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = true
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func fieldHeight(for width: CGFloat) -> CGFloat {
        let line = ceil(AppFont.body.ascender - AppFont.body.descender + AppFont.body.leading) + 1
        guard !secret else { return line }
        let text = NSAttributedString(string: field.stringValue.isEmpty ? " " : field.stringValue, attributes: [.font: AppFont.body])
        return min(80, max(line, measureText(text, max(1, width - Self.padX * 2 - 4)) + 1))
    }

    func height(for width: CGFloat) -> CGFloat { fieldHeight(for: width) + Self.padY * 2 }

    /// Clicks on the card's padding edit the field.
    override func mouseDown(with event: NSEvent) {
        guard field.isEnabled else { return }
        window?.makeFirstResponder(field)
    }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: Self.padX - 2, y: Self.padY, width: max(1, bounds.width - Self.padX * 2 + 4), height: fieldHeight(for: bounds.width))
    }

    func apply(_ theme: AppTheme) {
        palette = theme
        field.textColor = theme.fg
        if let placeholder = field.placeholderString {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: AppFont.body, .foregroundColor: theme.fgDim])
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = AgentPanelMetrics.rowRadius
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        (chosen ? palette.accent.withAlphaComponent(0.14) : palette.rowFill).setFill()
        card.fill()
        (focused || chosen ? palette.accent.withAlphaComponent(0.6) : palette.rowBorder).setStroke()
        card.lineWidth = 1
        card.stroke()
    }
}

/// The height `text` wraps to at `width`.
@MainActor
private func measureText(_ text: NSAttributedString, _ width: CGFloat) -> CGFloat {
    ceil(text.boundingRect(with: NSSize(width: max(1, width), height: 100_000),
                           options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
}

@MainActor
final class AgentFlippedView: NSView {
    override var isFlipped: Bool { true }
}
