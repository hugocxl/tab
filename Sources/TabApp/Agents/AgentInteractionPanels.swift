import AppKit
import TabProtocol

/// Scrollable queue, separate from the delivered transcript.
@MainActor
final class AgentQueueView: ThemedView {
    var onEdit: ((AgentQueuedPrompt) -> Void)?
    var onRemove: ((AgentQueuedPrompt) -> Void)?
    var onDeliver: ((AgentQueuedPrompt) -> Void)?
    var onMove: ((AgentQueuedPrompt, String) -> Void)?
    var onResume: (() -> Void)?
    private let scroll = NSScrollView()
    private let content = AgentPanelDocument()
    private var signature = ""
    private(set) var preferredHeight: CGFloat = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        content.spacing = 6
        isHidden = true
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.documentView = content
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ prompts: [AgentQueuedPrompt], paused: Bool, enabled: Bool) {
        let signature = prompts.map { "\($0.id):\($0.revision):\($0.state)" }.joined() + "\(paused):\(enabled)"
        guard self.signature != signature else { return }
        self.signature = signature
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        isHidden = prompts.isEmpty
        preferredHeight = prompts.isEmpty ? 0 : min(190, 42 + CGFloat(prompts.count) * 40)
        let header = AgentPanelRow()
        let label = makeLabel("\(prompts.count) \(paused ? "pending · Paused" : "queued")", font: AppFont.small)
        label.textColor = theme.fgMuted
        header.addArrangedSubview(label)
        if paused {
            let resume = PillButton("Resume", style: .plain) { [weak self] in self?.onResume?() }
            resume.isEnabled = enabled; header.addArrangedSubview(resume)
        }
        content.addArrangedSubview(header)
        for (offset, prompt) in prompts.enumerated() {
            let row = AgentPanelRow()
            let suffix = prompt.attachments.isEmpty ? "" : " · \(prompt.attachments.count) files"
            let text = NSTextField(labelWithString: (prompt.text.isEmpty ? "Attachments" : prompt.text.replacingOccurrences(of: "\n", with: " ")) + suffix)
            text.font = AppFont.small; text.textColor = theme.fg
            text.lineBreakMode = .byTruncatingTail; text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.toolTip = prompt.error ?? prompt.text
            row.addArrangedSubview(text)
            if prompt.state == .delivering {
                row.addArrangedSubview(makeLabel("Sending…", font: AppFont.footnote))
            } else {
                do {
                    let edit = action(.pencil, title: "Edit queued prompt") { [weak self] in self?.onEdit?(prompt) }
                    edit.isEnabled = enabled; row.addArrangedSubview(edit)
                }
                let send = action(.arrowUp, title: prompt.state == .uncertain || prompt.state == .failed ? "Review and retry delivery" : "Send now") { [weak self] in self?.onDeliver?(prompt) }
                let remove = action(.trash, title: "Remove queued prompt") { [weak self] in self?.onRemove?(prompt) }
                send.isEnabled = enabled; remove.isEnabled = enabled
                if prompt.state == .queued, let earlier = prompts.prefix(offset).last(where: { $0.state == .queued }) {
                    let move = action(.chevronUp, title: "Move earlier in queue") { [weak self] in self?.onMove?(prompt, earlier.id) }
                    move.isEnabled = enabled; row.addArrangedSubview(move)
                }
                row.addArrangedSubview(send); row.addArrangedSubview(remove)
            }
            content.addArrangedSubview(row)

        }
        needsLayout = true
    }
    private func action(_ icon: AppIcon, title: String, press: @escaping () -> Void) -> PillButton {
        let button = PillButton("", style: .plain, action: press)
        button.image = icon.image(size: 14, scale: AppIcon.inlineScale)
        button.contentTintColor = theme.fgMuted
        button.imagePosition = .imageOnly; button.toolTip = title; button.setAccessibilityLabel(title)
        return button
    }
    override func layout() {
        super.layout()
        guard bounds.width > 20, bounds.height > 12 else { scroll.frame = .zero; return }
        scroll.frame = bounds.insetBy(dx: 10, dy: 6)
        content.fit(width: max(1, scroll.contentSize.width - 4))
    }
    override func themeDidChange() {
        appearance = theme.nsAppearance
        wantsLayer = true; layer?.cornerRadius = 16; layer?.cornerCurve = .continuous
        layer?.backgroundColor = theme.agentComposer.cgColor
        signature = ""
    }
}

/// A form retains local edits while unrelated streaming snapshots arrive.
@MainActor
final class AgentQuestionView: ThemedView, NSTextFieldDelegate {
    var onAnswer: ((String, [String: [String]], Bool) -> Void)?
    var onChange: (() -> Void)?
    private let scroll = NSScrollView()
    private let content = AgentPanelDocument()
    private let submit = PillButton("Submit answers", style: .primary)
    private let cancel = PillButton("Cancel", style: .plain)
    private let error = NSTextField(wrappingLabelWithString: "")
    private var requestID: String?
    private var form: AgentQuestionnaire?
    private var choices: [String: [NSButton]] = [:]
    private var fields: [String: NSTextField] = [:]
    private(set) var preferredHeight: CGFloat = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        content.spacing = 10
        scroll.documentView = content; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        for view in [scroll, submit, cancel, error] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = true }
        error.font = AppFont.footnote
        submit.onPress = { [weak self] in self?.answer(cancelled: false) }
        cancel.onPress = { [weak self] in self?.answer(cancelled: true) }
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ item: AgentChatItem?, enabled: Bool) {
        submit.isEnabled = enabled; cancel.isEnabled = enabled
        for buttons in choices.values { buttons.forEach { $0.isEnabled = enabled } }
        fields.values.forEach { $0.isEnabled = enabled }
        guard requestID != item?.id || form != item?.questionnaire else { return }
        requestID = item?.id; form = item?.questionnaire
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        fields = [:]; choices = [:]; error.stringValue = ""
        guard let form else { isHidden = true; preferredHeight = 0; return }
        isHidden = false; preferredHeight = 280
        for question in form.questions {
            let title = NSTextField(wrappingLabelWithString: question.title + (question.required ? "" : " (optional)"))
            title.font = AppFont.small; title.textColor = theme.fg
            content.addArrangedSubview(title)

            var buttons: [NSButton] = []
            for option in question.options {
                let button = NSButton(checkboxWithTitle: option.label, target: self, action: #selector(choiceChanged(_:)))
                button.toolTip = option.description; button.setAccessibilityHelp(option.description)
                button.font = AppFont.small; button.contentTintColor = theme.fg; button.isEnabled = enabled
                buttons.append(button); content.addArrangedSubview(button)
                button.cell?.wraps = true; button.cell?.lineBreakMode = .byWordWrapping
                if let description = option.description, !description.isEmpty {
                    let detail = NSTextField(wrappingLabelWithString: description)
                    detail.font = AppFont.footnote; detail.textColor = theme.fgMuted
                    content.addArrangedSubview(detail)

                }
            }
            choices[question.id] = buttons
            let field: NSTextField = question.secret ? NSSecureTextField() : NSTextField()
            field.placeholderString = question.options.isEmpty ? "Your answer" : "Or write your own answer"
            field.setAccessibilityLabel(question.title)
            field.textColor = theme.fg; field.backgroundColor = theme.agentComposer
            field.delegate = self; field.isEnabled = enabled; fields[question.id] = field
            content.addArrangedSubview(field)
        }
        themeDidChange()
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
        guard let q = form?.questions.first(where: { choices[$0.id]?.contains(sender) == true }) else { return }
        if !q.multiple, sender.state == .on {
            choices[q.id]?.filter { $0 !== sender }.forEach { $0.state = .off }
            fields[q.id]?.stringValue = ""
        }
        error.stringValue = ""; onChange?()
    }
    func controlTextDidChange(_ obj: Notification) { error.stringValue = ""; onChange?() }
    private func answer(cancelled: Bool) {
        guard let requestID, let form else { return }
        do { try form.validate(answers: answers, cancelled: cancelled) }
        catch { self.error.stringValue = "Answer each required question before submitting."; return }
        onAnswer?(requestID, cancelled ? [:] : answers, cancelled)
    }
    override func layout() {
        super.layout()
        guard bounds.width > 24, bounds.height > 76 else { scroll.frame = .zero; return }
        scroll.frame = NSRect(x: 12, y: 12, width: max(1, bounds.width - 24), height: max(0, bounds.height - 76))
        content.fit(width: max(1, scroll.contentSize.width - 12))
        error.frame = NSRect(x: 12, y: bounds.height - 62, width: max(0, bounds.width - 24), height: 22)
        submit.frame = NSRect(x: 12, y: bounds.height - 36, width: 140, height: 28)
        cancel.frame = NSRect(x: 160, y: bounds.height - 36, width: 70, height: 28)
    }
    override func themeDidChange() {
        appearance = theme.nsAppearance
        wantsLayer = true; layer?.cornerRadius = 16; layer?.backgroundColor = theme.agentComposer.cgColor
        error.textColor = theme.danger
        submit.setTitleColor(theme.fg); cancel.setTitleColor(theme.fgMuted)
        fields.values.forEach { $0.textColor = theme.fg; $0.backgroundColor = theme.agentComposer }
        for view in content.arrangedSubviews {
            if let label = view as? NSTextField, !label.isEditable { label.textColor = theme.fgMuted }
            if let button = view as? NSButton { button.contentTintColor = theme.fg; button.setTitleColor(theme.fg) }
        }
    }
}

/// Measured document geometry keeps wrapping deterministic inside a scrolling form.
@MainActor
private final class AgentPanelDocument: NSView {
    var spacing: CGFloat = 8
    var arrangedSubviews: [NSView] { subviews }
    override var isFlipped: Bool { true }
    func addArrangedSubview(_ view: NSView) { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = true }
    func removeArrangedSubview(_ view: NSView) { view.removeFromSuperview() }
    func fit(width: CGFloat) {
        var y: CGFloat = 0
        for view in subviews {
            let height: CGFloat
            if let field = view as? NSTextField {
                if field.isEditable { height = 30 }
                else {
                    height = max(18, ceil((field.stringValue as NSString).boundingRect(
                        with: NSSize(width: width, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: [.font: field.font ?? AppFont.small]).height) + 2)
                }
            } else if let button = view as? NSButton {
                height = max(24, ceil((button.title as NSString).boundingRect(
                    with: NSSize(width: max(1, width - 26), height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: button.font ?? AppFont.small]).height) + 6)
            } else { height = 30 }
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height + spacing
        }
        frame = NSRect(x: 0, y: 0, width: width, height: max(1, y - spacing))
    }
}

@MainActor
private final class AgentPanelRow: NSView {
    override var isFlipped: Bool { true }
    func addArrangedSubview(_ view: NSView) { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = true }
    override func layout() {
        super.layout()
        let controls = subviews.dropFirst()
        let widths = controls.map { view -> CGFloat in
            guard let button = view as? NSButton else { return min(80, view.fittingSize.width) }
            return button.title.isEmpty ? 26 : min(80, button.fittingSize.width)
        }
        let textWidth = max(1, bounds.width - widths.reduce(0, +) - CGFloat(controls.count) * 6)
        subviews.first?.frame = NSRect(x: 0, y: 4, width: textWidth, height: max(18, bounds.height - 6))
        var x = textWidth + 6
        for (view, width) in zip(controls, widths) {
            view.frame = NSRect(x: x, y: 1, width: width, height: max(24, bounds.height - 2)); x += width + 6
        }
    }
}
