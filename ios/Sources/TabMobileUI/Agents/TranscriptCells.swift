import TabMobileKit
import TabProtocol
import UIKit

/// A text view that sizes to its text and keeps selection and links.
final class TranscriptTextView: UITextView {
    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        adjustsFontForContentSizeCategory = true
        linkTextAttributes = [.foregroundColor: UIColor.tintColor]
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A user message in a tinted bubble on the trailing side.
final class UserMessageCell: UICollectionViewCell {
    private let bubble = UIView()
    private let text = TranscriptTextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let column = ReadableColumn.guide(in: contentView)
        bubble.backgroundColor = UIColor.tintColor.withAlphaComponent(0.16)
        bubble.layer.cornerRadius = 20
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = .preferredFont(forTextStyle: .body)
        contentView.addSubview(bubble)
        bubble.addSubview(text)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            bubble.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor,
                                            constant: 48),
            text.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            text.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: AgentChatItem) {
        let attachments = item.attachments?.map { "📎 \($0.name)" }.joined(separator: "\n")
        text.text = [item.text, attachments].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
        text.font = .preferredFont(forTextStyle: .body)
        text.textColor = .label
    }
}

/// The agent's reply, as Markdown across the full width.
final class AssistantMessageCell: UICollectionViewCell {
    private let text = TranscriptTextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let column = ReadableColumn.guide(in: contentView)
        text.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            text.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            text.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ rendered: NSAttributedString) {
        text.attributedText = rendered
    }
}

/// One tool step: what ran, on what, and how it ended; tap to see its output.
final class ToolCell: UICollectionViewCell {
    private let icon = UIImageView()
    private let title = UILabel()
    private let summary = UILabel()
    private let status = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let output = UILabel()
    private let card = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let column = ReadableColumn.guide(in: contentView)
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        title.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        title.adjustsFontForContentSizeCategory = true
        title.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        summary.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        summary.textColor = .secondaryLabel
        summary.lineBreakMode = .byTruncatingMiddle
        summary.adjustsFontForContentSizeCategory = true
        status.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        output.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
        output.numberOfLines = 40
        output.textColor = .secondaryLabel
        output.adjustsFontForContentSizeCategory = true

        let header = UIStackView(arrangedSubviews: [icon, title, summary, spinner, status])
        header.spacing = 8
        header.alignment = .center
        let stack = UIStackView(arrangedSubviews: [header, output])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
            card.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            icon.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: AgentChatItem, expanded: Bool) {
        let tool = item.tool
        icon.image = UIImage(systemName: Self.symbol(tool?.category))
        title.text = Self.name(tool)
        summary.text = tool?.summary ?? item.text
        switch tool?.status ?? (item.isComplete ? .completed : .running) {
        case .running:
            spinner.startAnimating()
            status.isHidden = true
        case .completed:
            spinner.stopAnimating()
            status.isHidden = false
            status.image = UIImage(systemName: "checkmark.circle.fill")
            status.tintColor = .systemGreen
        case .failed:
            spinner.stopAnimating()
            status.isHidden = false
            status.image = UIImage(systemName: "xmark.circle.fill")
            status.tintColor = .systemRed
        case .denied, .interrupted:
            spinner.stopAnimating()
            status.isHidden = false
            status.image = UIImage(systemName: "minus.circle.fill")
            status.tintColor = .secondaryLabel
        }
        let detail = expanded ? Self.detail(item) : nil
        output.isHidden = detail == nil
        output.attributedText = detail
        accessibilityLabel = "\(title.text ?? ""), \(summary.text ?? "")"
    }

    static func name(_ tool: AgentToolActivity?) -> String {
        switch tool?.category {
        case .command: "Run"
        case .read: "Read"
        case .search: "Search"
        case .edit: "Edit"
        case .web: "Web"
        case .subagent: "Agent"
        default: tool?.name ?? "Tool"
        }
    }

    static func symbol(_ category: AgentToolActivity.Category?) -> String {
        switch category {
        case .command: "terminal"
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .edit: "pencil"
        case .web: "globe"
        case .subagent: "person.2"
        default: "wrench.and.screwdriver"
        }
    }

    /// A diff with colored lines for edits; otherwise the output.
    private static func detail(_ item: AgentChatItem) -> NSAttributedString? {
        let tool = item.tool
        if let diff = tool?.fileChangeDetails?.diff ?? tool?.fileChanges?.compactMap(\.diff).first, !diff.isEmpty {
            let result = NSMutableAttributedString()
            for line in diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(80) {
                let color: UIColor = line.hasPrefix("+") ? .systemGreen : line.hasPrefix("-") ? .systemRed : .secondaryLabel
                result.append(NSAttributedString(string: line + "\n", attributes: [.foregroundColor: color]))
            }
            return result
        }
        let text = (tool?.output ?? item.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : NSAttributedString(string: String(text.prefix(6000)))
    }
}

/// The agent's reasoning, collapsed to a line until tapped.
final class ThinkingCell: UICollectionViewCell {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let column = ReadableColumn.guide(in: contentView)
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: AgentChatItem, expanded: Bool) {
        let thought = (item.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let head = NSMutableAttributedString(string: item.isComplete ? "Thought" : "Thinking…", attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote).withTraits(.traitBold),
        ])
        if !thought.isEmpty {
            head.append(NSAttributedString(string: expanded ? "\n" + thought : "  " + thought.prefix(80)
                .replacingOccurrences(of: "\n", with: " ")))
        }
        label.attributedText = head
        label.numberOfLines = expanded ? 0 : 1
    }
}

/// An agent asking to run something: what it wants, with Deny and Allow.
final class ApprovalCell: UICollectionViewCell {
    private let title = UILabel()
    private let detail = UILabel()
    private let deny = UIButton(configuration: .glass())
    private let allow = UIButton(configuration: .prominentGlass())
    var onAnswer: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let column = ReadableColumn.guide(in: contentView)
        let card = UIView()
        card.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.35).cgColor
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        detail.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        detail.adjustsFontForContentSizeCategory = true
        detail.numberOfLines = 12
        detail.textColor = .secondaryLabel
        deny.configuration?.title = "Deny"
        allow.configuration?.title = "Allow"
        allow.tintColor = .systemOrange
        deny.addAction(UIAction { [weak self] _ in self?.answer(false) }, for: .primaryActionTriggered)
        allow.addAction(UIAction { [weak self] _ in self?.answer(true) }, for: .primaryActionTriggered)
        let buttons = UIStackView(arrangedSubviews: [deny, allow])
        buttons.distribution = .fillEqually
        buttons.spacing = 10
        let icon = UIImageView(image: UIImage(systemName: "hand.raised.fill"))
        icon.tintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [icon, title])
        header.spacing = 8
        header.alignment = .firstBaseline
        let stack = UIStackView(arrangedSubviews: [header, detail, buttons])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            card.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: AgentChatItem, busy: Bool) {
        let kind = item.workContext?.requestKind
        title.text = kind == "file-change" ? "Allow this edit?" : "Allow \(item.text.isEmpty ? "this" : item.text)?"
        detail.text = Self.describe(item.detail)
        detail.isHidden = detail.text?.isEmpty ?? true
        deny.isEnabled = !busy
        allow.isEnabled = !busy
    }

    private func answer(_ allow: Bool) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onAnswer?(allow)
    }

    /// The command or path from the request's JSON input, else the JSON.
    private static func describe(_ input: String?) -> String? {
        guard let input, let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return input }
        for key in ["command", "cmd", "file_path", "path", "url", "query"] {
            if let value = object[key] as? String { return value }
        }
        return input
    }
}

/// A notice or an answered approval, small and centered; errors as a red card.
final class NoticeCell: UICollectionViewCell {
    private let label = UILabel()
    private let card = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let column = ReadableColumn.guide(in: contentView)
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        card.addSubview(label)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            card.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: AgentChatItem, isError: Bool) {
        let text = [item.text, isError ? item.detail : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        label.text = text
        if isError {
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .systemRed
            label.textAlignment = .natural
            card.backgroundColor = UIColor.systemRed.withAlphaComponent(0.1)
        } else {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            card.backgroundColor = .clear
        }
    }
}

/// "Worked for 1m 12s · 14 steps", folding a finished turn's tool steps.
final class WorkCell: UICollectionViewCell {
    private let label = UILabel()
    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let column = ReadableColumn.guide(in: contentView)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
        let icon = UIImageView(image: UIImage(systemName: "checklist"))
        icon.tintColor = .secondaryLabel
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        let stack = UIStackView(arrangedSubviews: [icon, label, chevron, UIView()])
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(steps: Int, duration: TimeInterval?, expanded: Bool) {
        var parts: [String] = []
        if let duration { parts.append("Worked for \(Self.format(duration))") } else { parts.append("Worked") }
        parts.append(steps == 1 ? "1 step" : "\(steps) steps")
        label.text = parts.joined(separator: " · ")
        chevron.image = UIImage(systemName: expanded ? "chevron.up" : "chevron.down")
        accessibilityTraits = .button
        accessibilityHint = expanded ? "Hides the steps" : "Shows the steps"
    }

    static func format(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m"
    }
}

/// The agent is working: an animated glyph and the elapsed time.
final class WorkingCell: UICollectionViewCell {
    private let icon = UIImageView(image: UIImage(systemName: "ellipsis"))
    private let label = UILabel()
    private var since: Date?
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let column = ReadableColumn.guide(in: contentView)
        icon.tintColor = .tintColor
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [icon, label, UIView()])
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(since: Date?) {
        self.since = since
        icon.addSymbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeat(.continuous))
        tick()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let since else {
            label.text = "Working"
            return
        }
        label.text = "Working · \(WorkCell.format(Date().timeIntervalSince(since)))"
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        timer?.invalidate()
        timer = nil
        icon.removeAllSymbolEffects()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            timer?.invalidate()
            timer = nil
        }
    }
}
