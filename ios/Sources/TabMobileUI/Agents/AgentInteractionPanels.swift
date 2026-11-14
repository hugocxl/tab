import TabMobileKit
import TabProtocol
import UIKit

/// A glass card the width of the composer, floating over the conversation.
class AgentPanelCard: UIView {
    let glass = UIVisualEffectView(effect: UIGlassEffect())
    var content: UIView { glass.contentView }

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.cornerConfiguration = .uniformCorners(radius: .fixed(22))
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// What went wrong with the last command, until the next reply.
final class AgentNoticeView: AgentPanelCard {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .systemRed
        label.numberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `message`; nil hides the card. Returns whether anything changed.
    @discardableResult
    func show(_ message: String?) -> Bool {
        guard label.text != message || isHidden != (message == nil) else { return false }
        label.text = message
        isHidden = message == nil
        return true
    }
}

/// The prompts waiting for the agent, styled like the conversation's text,
/// each with a menu to edit, move, send now or remove it. While the queue is
/// paused, a header says so with Resume.
final class AgentQueueView: AgentPanelCard {
    var onEdit: ((AgentQueuedPrompt) -> Void)?
    var onRemove: ((AgentQueuedPrompt) -> Void)?
    var onDeliver: ((AgentQueuedPrompt) -> Void)?
    var onMoveEarlier: ((AgentQueuedPrompt) -> Void)?
    var onResume: (() -> Void)?
    private static let visibleRows = 4
    private let header = UIStackView()
    private let resume = UIButton(configuration: .glass())
    private let scroll = UIScrollView()
    private let rows = UIStackView()
    private var scrollHeight: NSLayoutConstraint!
    private var signature = ""
    private var rowViews: [String: QueuedPromptRow] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        let title = UILabel()
        title.text = "Paused · Queued prompts wait until you resume"
        title.font = .preferredFont(forTextStyle: .footnote)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .secondaryLabel
        title.numberOfLines = 2
        resume.configuration?.title = "Resume"
        resume.configuration?.buttonSize = .small
        resume.setContentHuggingPriority(.required, for: .horizontal)
        resume.addAction(UIAction { [weak self] _ in self?.onResume?() }, for: .primaryActionTriggered)
        header.addArrangedSubview(title)
        header.addArrangedSubview(resume)
        header.alignment = .center
        header.spacing = 8
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0)

        rows.axis = .vertical
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(rows)
        scroll.showsVerticalScrollIndicator = true

        let stack = UIStackView(arrangedSubviews: [header, scroll])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            scrollHeight,
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `prompts`; returns whether anything changed. Each prompt keeps
    /// its row, so focus and an open menu survive updates.
    @discardableResult
    func update(_ prompts: [AgentQueuedPrompt], paused: Bool, enabled: Bool,
                earlier: (AgentQueuedPrompt) -> AgentQueuedPrompt?) -> Bool {
        let signature = prompts.map { "\($0.id):\($0.revision):\($0.state)" }.joined(separator: ",") + "|\(paused)|\(enabled)"
        guard self.signature != signature else { return false }
        self.signature = signature
        isHidden = prompts.isEmpty
        header.isHidden = !paused
        resume.isEnabled = enabled
        let ids = Set(prompts.map(\.id))
        for (id, row) in rowViews where !ids.contains(id) {
            row.removeFromSuperview()
            rowViews[id] = nil
        }
        for (index, prompt) in prompts.enumerated() {
            let row = rowViews[prompt.id] ?? makeRow()
            rowViews[prompt.id] = row
            row.show(prompt, canMoveEarlier: earlier(prompt) != nil, enabled: enabled)
            if rows.arrangedSubviews.firstIndex(of: row) != index { rows.insertArrangedSubview(row, at: index) }
        }
        rows.layoutIfNeeded()
        let rowHeight = rows.arrangedSubviews.first?.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height ?? 44
        scrollHeight.constant = rowHeight * CGFloat(min(prompts.count, Self.visibleRows))
        return true
    }

    private func makeRow() -> QueuedPromptRow {
        let row = QueuedPromptRow()
        row.onDeliver = { [weak self] prompt in self?.onDeliver?(prompt) }
        row.onEdit = { [weak self] prompt in self?.onEdit?(prompt) }
        row.onMoveEarlier = { [weak self] prompt in self?.onMoveEarlier?(prompt) }
        row.onRemove = { [weak self] prompt in self?.onRemove?(prompt) }
        return row
    }
}

/// One queued prompt: its text, its state, and a menu of what can be done with it.
private final class QueuedPromptRow: UIStackView {
    var onDeliver: ((AgentQueuedPrompt) -> Void)?
    var onEdit: ((AgentQueuedPrompt) -> Void)?
    var onMoveEarlier: ((AgentQueuedPrompt) -> Void)?
    var onRemove: ((AgentQueuedPrompt) -> Void)?
    private let icon = UIImageView(image: UIImage(systemName: "clock.arrow.circlepath"))
    private let text = UILabel()
    private let detail = UILabel()
    private let more = UIButton(configuration: .plain())

    init() {
        super.init(frame: .zero)
        icon.tintColor = .tertiaryLabel
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.adjustsFontForContentSizeCategory = true
        detail.setContentHuggingPriority(.required, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        more.configuration?.image = UIImage(systemName: "ellipsis.circle")
        more.showsMenuAsPrimaryAction = true
        more.accessibilityLabel = "Queued prompt actions"
        more.setContentHuggingPriority(.required, for: .horizontal)
        for view in [icon, text, detail, more] { addArrangedSubview(view) }
        alignment = .center
        spacing = 8
        isLayoutMarginsRelativeArrangement = true
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 0)
        heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        isAccessibilityElement = false
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func show(_ prompt: AgentQueuedPrompt, canMoveEarlier: Bool, enabled: Bool) {
        let needsReview = prompt.state == .uncertain || prompt.state == .failed
        let files = prompt.attachments.count
        let filesText = files == 0 ? "" : files == 1 ? "1 attachment" : "\(files) attachments"
        text.text = prompt.text.isEmpty ? filesText : prompt.text.replacingOccurrences(of: "\n", with: " ")
        switch prompt.state {
        case .delivering:
            detail.text = "Sending…"
            detail.textColor = .secondaryLabel
        case .uncertain, .failed:
            detail.text = "Needs review"
            detail.textColor = .systemOrange
        case .queued:
            detail.text = prompt.text.isEmpty ? nil : filesText.isEmpty ? nil : filesText
            detail.textColor = .tertiaryLabel
        }
        detail.isHidden = detail.text == nil
        more.configuration?.baseForegroundColor = needsReview ? .systemOrange : .secondaryLabel
        more.isEnabled = enabled && prompt.state != .delivering
        more.isHidden = prompt.state == .delivering
        var actions: [UIMenuElement] = [
            UIAction(title: needsReview ? "Review and Send Again" : "Send Now", image: UIImage(systemName: "arrow.up")) {
                [weak self] _ in self?.onDeliver?(prompt)
            },
            UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.onEdit?(prompt) },
        ]
        if canMoveEarlier {
            actions.append(UIAction(title: "Move Earlier", image: UIImage(systemName: "chevron.up")) { [weak self] _ in
                self?.onMoveEarlier?(prompt)
            })
        }
        actions.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Remove", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.onRemove?(prompt)
            },
        ]))
        more.menu = UIMenu(title: prompt.error ?? "", children: actions)
        text.accessibilityLabel = "Queued: \(text.text ?? "")"
        text.accessibilityValue = detail.text
    }
}

/// Agents the conversation's agent started that are still running, so work
/// in the background stays visible after the turn ends. Tapping one shows the
/// step that started it.
final class AgentSubagentsView: AgentPanelCard {
    var onReveal: ((String) -> Void)?
    private static let visibleRows = 3
    private let scroll = UIScrollView()
    private let rows = UIStackView()
    private var rowViews: [String: SubagentRow] = [:]
    private var shown: [AgentSubagent] = []
    private var scrollHeight: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        rows.axis = .vertical
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(rows)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            scrollHeight,
        ])
        accessibilityLabel = "Running agents"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the running ones of `subagents`, reusing each one's row so its
    /// spinner keeps turning. Returns whether anything changed.
    @discardableResult
    func update(_ subagents: [AgentSubagent]) -> Bool {
        guard subagents != shown else { return false }
        let structureChanged = subagents.map(\.id) != shown.map(\.id)
        shown = subagents
        isHidden = subagents.isEmpty
        let ids = Set(subagents.map(\.id))
        for (id, row) in rowViews where !ids.contains(id) {
            row.removeFromSuperview()
            rowViews[id] = nil
        }
        for (index, subagent) in subagents.enumerated() {
            let row = rowViews[subagent.id] ?? makeRow()
            rowViews[subagent.id] = row
            row.show(subagent)
            if rows.arrangedSubviews.firstIndex(of: row) != index { rows.insertArrangedSubview(row, at: index) }
        }
        scrollHeight.constant = CGFloat(min(subagents.count, Self.visibleRows)) * SubagentRow.height
        return structureChanged
    }

    private func makeRow() -> SubagentRow {
        let row = SubagentRow()
        row.addAction(UIAction { [weak self, weak row] _ in
            guard let id = row?.toolUseID else { return }
            self?.onReveal?(id)
        }, for: .primaryActionTriggered)
        return row
    }
}

/// One running agent: a spinner, what it was asked to do, then what it's
/// doing now and how much it has done. A control, so a keyboard can focus and
/// activate it.
private final class SubagentRow: UIControl {
    static let height: CGFloat = 48
    private(set) var toolUseID: String?
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let title = UILabel()
    private let activity = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        spinner.startAnimating()
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        title.font = .preferredFont(forTextStyle: .subheadline)
        title.lineBreakMode = .byTruncatingTail
        activity.font = .preferredFont(forTextStyle: .caption1)
        activity.textColor = .secondaryLabel
        activity.lineBreakMode = .byTruncatingTail
        let labels = UIStackView(arrangedSubviews: [title, activity])
        labels.axis = .vertical
        let row = UIStackView(arrangedSubviews: [spinner, labels])
        row.spacing = 10
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        focusEffect = UIFocusHaloEffect()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var canBecomeFocused: Bool { toolUseID != nil }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .tertiarySystemFill : .clear }
    }

    func show(_ subagent: AgentSubagent) {
        toolUseID = subagent.toolUseID
        isEnabled = subagent.toolUseID != nil
        title.text = subagent.description
        var parts: [String] = []
        if subagent.background { parts.append("Background") }
        if let uses = subagent.toolUses, uses > 0 { parts.append(uses == 1 ? "1 tool" : "\(uses) tools") }
        if let tokens = subagent.tokens, tokens > 0 { parts.append(Self.tokens(tokens)) }
        let doing = subagent.activity ?? (subagent.background ? "Working in the background" : "Starting")
        activity.text = ([doing] + parts.filter { $0 != "Background" || subagent.activity != nil }).joined(separator: " · ")
        accessibilityLabel = "\(subagent.description), \(doing)"
        accessibilityValue = parts.joined(separator: ", ")
        accessibilityHint = toolUseID == nil ? nil : "Shows the step that started it"
    }

    private static func tokens(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1fM tokens", Double(count) / 1_000_000)
            : count >= 1_000 ? "\(count / 1_000)k tokens" : "\(count) tokens"
    }
}

/// The current task list's progress, such as "2 of 5 done · Run the tests";
/// tapping it shows the list in the conversation.
final class AgentTaskProgressView: AgentPanelCard {
    var onReveal: (() -> Void)?
    private let button = UIButton(configuration: .plain())

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        button.configuration?.image = UIImage(systemName: "checklist")
        button.configuration?.imagePadding = 8
        button.configuration?.baseForegroundColor = .secondaryLabel
        button.configuration?.titleLineBreakMode = .byTruncatingTail
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        button.contentHorizontalAlignment = .leading
        button.accessibilityHint = "Shows the task list"
        button.addAction(UIAction { [weak self] _ in self?.onReveal?() }, for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: content.topAnchor),
            button.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `title`; nil hides it. Returns whether anything changed.
    @discardableResult
    func show(_ title: String?) -> Bool {
        guard button.configuration?.title != title || isHidden != (title == nil) else { return false }
        var text = AttributedString(title ?? "")
        text.font = .preferredFont(forTextStyle: .footnote)
        button.configuration?.attributedTitle = text
        button.configuration?.title = title
        button.accessibilityLabel = title
        let hidden = title == nil
        let appeared = isHidden != hidden
        isHidden = hidden
        return appeared
    }
}

/// The question an agent is waiting on, as a form: each question with its
/// choices and a field for an answer of your own, then Cancel and Submit.
/// Edits survive the snapshots that stream in while it's open.
final class AgentQuestionView: AgentPanelCard, UITextFieldDelegate {
    var onAnswer: ((AgentChatItem, [String: [String]], Bool) -> Void)?
    var onChange: ((AgentChatItem, [String: [String]]) -> Void)?
    private let scroll = UIScrollView()
    private let blocksStack = UIStackView()
    private let error = UILabel()
    private let submit = UIButton(configuration: .prominentGlass())
    private let cancel = UIButton(configuration: .glass())
    private var blocks: [QuestionBlock] = []
    private var item: AgentChatItem?
    private var fitting: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        blocksStack.axis = .vertical
        blocksStack.spacing = 20
        blocksStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(blocksStack)
        scroll.keyboardDismissMode = .interactive
        error.font = .preferredFont(forTextStyle: .footnote)
        error.adjustsFontForContentSizeCategory = true
        error.textColor = .systemRed
        error.numberOfLines = 2
        error.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        submit.configuration?.title = "Submit"
        cancel.configuration?.title = "Cancel"
        for button in [submit, cancel] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.titleLabel?.numberOfLines = 1
        }
        submit.addAction(UIAction { [weak self] _ in self?.answer(cancelled: false) }, for: .primaryActionTriggered)
        cancel.addAction(UIAction { [weak self] _ in self?.answer(cancelled: true) }, for: .primaryActionTriggered)
        let footer = UIStackView(arrangedSubviews: [error, cancel, submit])
        footer.alignment = .center
        footer.spacing = 8

        let stack = UIStackView(arrangedSubviews: [scroll, footer])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        // As tall as the questions, until the pane caps it and it scrolls. Below the
        // readable column's own priority, so a tall form never narrows the column.
        fitting = scroll.heightAnchor.constraint(equalTo: blocksStack.heightAnchor)
        fitting.priority = .defaultHigh - 50
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            blocksStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            blocksStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            blocksStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            blocksStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            blocksStack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -4),
            fitting,
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the form for `item`, keeping what's typed while it's the same
    /// question; `saved` restores answers kept from before. Returns whether
    /// the form changed.
    @discardableResult
    func update(_ item: AgentChatItem?, enabled: Bool, saved: [String: [String]]?) -> Bool {
        submit.isEnabled = enabled
        cancel.isEnabled = enabled
        blocks.forEach { $0.isEnabled = enabled }
        guard self.item?.id != item?.id || self.item?.questionnaire != item?.questionnaire else {
            self.item = item
            return false
        }
        self.item = item
        blocks.forEach { $0.removeFromSuperview() }
        blocks = []
        error.text = nil
        guard let form = item?.questionnaire else {
            isHidden = true
            return true
        }
        isHidden = false
        blocks = form.questions.map { question in
            let block = QuestionBlock(question: question)
            block.onChange = { [weak self] in self?.changed() }
            block.onChoose = { [weak self, weak block] in self?.advance(past: block) }
            block.field.delegate = self
            block.isEnabled = enabled
            if let answers = saved?[question.id] { block.restore(answers) }
            blocksStack.addArrangedSubview(block)
            return block
        }
        return true
    }

    private var answers: [String: [String]] {
        Dictionary(uniqueKeysWithValues: blocks.map { ($0.question.id, $0.answers) })
    }

    /// A single choice answers its question, so the next one scrolls into view.
    private func advance(past block: QuestionBlock?) {
        guard let block, let index = blocks.firstIndex(where: { $0 === block }), index + 1 < blocks.count else { return }
        let next = blocks[index + 1]
        layoutIfNeeded()
        scroll.scrollRectToVisible(next.convert(next.bounds, to: scroll), animated: true)
    }

    private func changed() {
        error.text = nil
        guard let item else { return }
        onChange?(item, answers)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    /// Scrolls to the first required question without an answer, focuses it,
    /// and says what's missing.
    private func revealFirstUnanswered() {
        guard let block = blocks.first(where: { $0.question.required && $0.answers.isEmpty }) else { return }
        layoutIfNeeded()
        scroll.scrollRectToVisible(block.convert(block.bounds, to: scroll), animated: true)
        if block.question.options.isEmpty { block.field.becomeFirstResponder() }
        UIAccessibility.post(notification: .layoutChanged, argument: block)
        UIAccessibility.post(notification: .announcement, argument: "Answer “\(block.question.title)” first.")
    }

    private func answer(cancelled: Bool) {
        guard let item, let form = item.questionnaire else { return }
        let answers = answers
        do {
            try form.validate(answers: answers, cancelled: cancelled)
        } catch {
            self.error.text = "Answer each required question first."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            revealFirstUnanswered()
            return
        }
        endEditing(true)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onAnswer?(item, answers, cancelled)
    }
}

/// One question: its title, its choices with their descriptions, and a
/// field for an answer of one's own, hidden as it's typed when private.
private final class QuestionBlock: UIStackView {
    let question: AgentQuestionnaire.Question
    let field = UITextField()
    var onChange: (() -> Void)?
    /// A single-answer question was answered by a choice.
    var onChoose: (() -> Void)?
    private var choices: [UIButton] = []
    private var chosen: Set<String> = []

    var isEnabled = true {
        didSet {
            choices.forEach { $0.isEnabled = isEnabled }
            field.isEnabled = isEnabled
        }
    }

    init(question: AgentQuestionnaire.Question) {
        self.question = question
        super.init(frame: .zero)
        axis = .vertical
        spacing = 6
        let title = UILabel()
        let text = NSMutableAttributedString(string: question.title, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .headline), .foregroundColor: UIColor.label,
        ])
        if !question.required {
            text.append(NSAttributedString(string: "  Optional", attributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote), .foregroundColor: UIColor.secondaryLabel,
            ]))
        }
        title.attributedText = text
        title.numberOfLines = 0
        addArrangedSubview(title)
        setCustomSpacing(10, after: title)

        for option in question.options {
            var configuration = UIButton.Configuration.plain()
            configuration.title = option.label
            configuration.subtitle = option.description?.isEmpty == false ? option.description : nil
            configuration.titleAlignment = .leading
            configuration.imagePadding = 10
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
            configuration.baseForegroundColor = .label
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .preferredFont(forTextStyle: .body)
                return attributes
            }
            configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .preferredFont(forTextStyle: .footnote)
                attributes.foregroundColor = .secondaryLabel
                return attributes
            }
            let button = UIButton(configuration: configuration)
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak self] _ in self?.toggle(option.label) }, for: .primaryActionTriggered)
            choices.append(button)
            addArrangedSubview(button)
        }

        field.placeholder = question.options.isEmpty ? "Your answer" : "Or write your own answer"
        field.isSecureTextEntry = question.secret
        field.borderStyle = .roundedRect
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = .done
        field.accessibilityLabel = question.title
        field.addAction(UIAction { [weak self] _ in self?.typed() }, for: .editingChanged)
        if !question.options.isEmpty { setCustomSpacing(10, after: choices[choices.count - 1]) }
        addArrangedSubview(field)
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        refreshChoices()
    }

    required init(coder: NSCoder) { fatalError("not used") }

    /// The chosen labels, then the typed answer; a typed answer replaces the
    /// choice of a single-answer question.
    var answers: [String] {
        let typed = field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let picked = question.options.map(\.label).filter { chosen.contains($0) }
        if typed.isEmpty { return picked }
        return question.multiple ? picked + [typed] : [typed]
    }

    func restore(_ answers: [String]) {
        let labels = Set(question.options.map(\.label))
        chosen = Set(answers.filter { labels.contains($0) })
        field.text = answers.filter { !labels.contains($0) }.joined(separator: ", ")
        refreshChoices()
    }

    private func toggle(_ label: String) {
        UISelectionFeedbackGenerator().selectionChanged()
        if question.multiple {
            if chosen.contains(label) { chosen.remove(label) } else { chosen.insert(label) }
        } else {
            chosen = chosen.contains(label) ? [] : [label]
            field.text = ""
        }
        refreshChoices()
        onChange?()
        if !question.multiple, !chosen.isEmpty { onChoose?() }
    }

    private func typed() {
        if !question.multiple, field.text?.isEmpty == false, !chosen.isEmpty {
            chosen = []
            refreshChoices()
        }
        onChange?()
    }

    private func refreshChoices() {
        for (button, option) in zip(choices, question.options) {
            let on = chosen.contains(option.label)
            let symbol = question.multiple
                ? (on ? "checkmark.square.fill" : "square")
                : (on ? "largecircle.fill.circle" : "circle")
            button.configuration?.image = UIImage(systemName: symbol)
            button.configuration?.imageColorTransformer = UIConfigurationColorTransformer { _ in
                on ? .tintColor : .tertiaryLabel
            }
            button.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }
}
