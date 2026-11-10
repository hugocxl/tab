import TabMobileKit
import TabProtocol
import UIKit

/// The message field: Return sends from a hardware keyboard, Shift-Return
/// starts a new line, and Shift-Tab turns plan mode on or off, as on the
/// desktop; the on-screen keyboard's Return stays a line break with the Send
/// button beside it.
final class ComposerTextView: UITextView {
    var onReturn: (() -> Void)?
    var onTogglePlan: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(title: "Send", action: #selector(returnPressed), input: "\r")
        send.wantsPriorityOverSystemBehavior = true
        let newline = UIKeyCommand(title: "New Line", action: #selector(newLine), input: "\r", modifierFlags: .shift)
        newline.wantsPriorityOverSystemBehavior = true
        let plan = UIKeyCommand(title: "Plan Mode", action: #selector(togglePlan), input: "\t", modifierFlags: .shift)
        plan.wantsPriorityOverSystemBehavior = true
        return [send, newline, plan]
    }

    @objc private func returnPressed() { onReturn?() }
    @objc private func newLine() { insertText("\n") }
    @objc private func togglePlan() { onTogglePlan?() }
}

/// Where an attachment comes from.
enum AttachmentSource {
    case photos, camera, files
}

/// The composer in a glass card: attached files, the message, then one row
/// with Attach, the plan mode chip, one picker for the model and its effort,
/// and one button that is Send for a draft, Stop while the agent works with
/// nothing to send, and Dictate otherwise.
final class AgentComposerView: UIView, UITextViewDelegate {
    private static let minimumTextHeight: CGFloat = 40
    private static let controlSize: CGFloat = 40

    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let attachmentStrip = UIScrollView()
    private let attachmentStack = UIStackView()
    private let text = ComposerTextView()
    private let placeholder = UILabel()
    private let attach = UIButton(configuration: .gray())
    private let plan = UIButton(configuration: .tinted())
    private let model = UIButton(configuration: .plain())
    private let primary = UIButton(configuration: .prominentGlass())
    private let dictation = AgentDictation()
    private var heightConstraint: NSLayoutConstraint!
    private weak var controller: AgentChatController?
    private var shownProvider: AgentChatProvider?
    private var shownDraft = -1
    private var shownAttachments: [String] = []
    var onAttach: ((AttachmentSource) -> Void)?
    /// Something went wrong that the pane should say, such as dictation failing.
    var onProblem: ((String) -> Void)?

    private enum Action { case send, stop, dictate }

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.cornerConfiguration = .uniformCorners(radius: .fixed(26))
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        attachmentStack.axis = .horizontal
        attachmentStack.spacing = 8
        attachmentStack.translatesAutoresizingMaskIntoConstraints = false
        attachmentStrip.showsHorizontalScrollIndicator = false
        attachmentStrip.clipsToBounds = false
        attachmentStrip.isHidden = true
        attachmentStrip.addSubview(attachmentStack)

        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.backgroundColor = .clear
        text.delegate = self
        text.textContainerInset = UIEdgeInsets(top: 10, left: 4, bottom: 6, right: 4)
        text.accessibilityLabel = "Message"
        text.onReturn = { [weak self] in self?.sendNow() }
        text.onTogglePlan = { [weak self] in self?.controller?.togglePlanMode() }
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        text.addSubview(placeholder)

        attach.configuration?.image = UIImage(systemName: "plus",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
        attach.configuration?.baseForegroundColor = .label
        attach.configuration?.cornerStyle = .capsule
        attach.showsMenuAsPrimaryAction = true
        attach.menu = attachMenu()
        attach.accessibilityLabel = "Attach"

        // The chip says plan mode is on; tapping it turns it off.
        plan.configuration?.title = "Plan"
        plan.configuration?.image = UIImage(systemName: "xmark",
                                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        plan.configuration?.imagePlacement = .trailing
        plan.configuration?.imagePadding = 6
        plan.configuration?.cornerStyle = .capsule
        plan.configuration?.buttonSize = .small
        plan.accessibilityLabel = "Plan mode"
        plan.accessibilityHint = "Turns plan mode off"
        plan.isHidden = true
        plan.addAction(UIAction { [weak self] _ in self?.controller?.togglePlanMode() }, for: .primaryActionTriggered)

        model.configuration?.baseForegroundColor = .label
        model.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        model.configuration?.imagePadding = 6
        model.configuration?.titleLineBreakMode = .byTruncatingTail
        model.showsMenuAsPrimaryAction = true
        model.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        primary.configuration?.cornerStyle = .capsule
        primary.tintColor = .label
        primary.addAction(UIAction { [weak self] _ in self?.performPrimary() }, for: .primaryActionTriggered)
        dictation.onChange = { [weak self] in self?.refreshPrimary() }
        dictation.onText = { [weak self] heard in self?.insertDictation(heard) }
        dictation.onError = { [weak self] message in self?.onProblem?(message) }

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = UIStackView(arrangedSubviews: [attach, plan, spacer, model, primary])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 6

        let content = UIStackView(arrangedSubviews: [attachmentStrip, text, bar])
        content.axis = .vertical
        content.spacing = 2
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(content)

        heightConstraint = text.heightAnchor.constraint(equalToConstant: Self.minimumTextHeight)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -6),
            content.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
            attachmentStrip.heightAnchor.constraint(equalToConstant: 64),
            attachmentStack.topAnchor.constraint(equalTo: attachmentStrip.contentLayoutGuide.topAnchor, constant: 4),
            attachmentStack.bottomAnchor.constraint(equalTo: attachmentStrip.contentLayoutGuide.bottomAnchor),
            attachmentStack.leadingAnchor.constraint(equalTo: attachmentStrip.contentLayoutGuide.leadingAnchor, constant: 4),
            attachmentStack.trailingAnchor.constraint(equalTo: attachmentStrip.contentLayoutGuide.trailingAnchor, constant: -4),
            attachmentStack.heightAnchor.constraint(equalTo: attachmentStrip.frameLayoutGuide.heightAnchor, constant: -4),
            heightConstraint,
            placeholder.leadingAnchor.constraint(equalTo: text.leadingAnchor, constant: 9),
            placeholder.topAnchor.constraint(equalTo: text.topAnchor, constant: 10),
            attach.widthAnchor.constraint(equalToConstant: Self.controlSize),
            attach.heightAnchor.constraint(equalToConstant: Self.controlSize),
            model.heightAnchor.constraint(equalToConstant: Self.controlSize),
            primary.widthAnchor.constraint(equalToConstant: Self.controlSize),
            primary.heightAnchor.constraint(equalToConstant: Self.controlSize),
        ])
        refreshPrimary()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ controller: AgentChatController) {
        self.controller = controller
        if controller.draftGeneration != shownDraft {
            shownDraft = controller.draftGeneration
            text.text = controller.draft.text
            textViewDidChange(text)
        }
        showAttachments(controller.draft.attachments)
        text.isEditable = controller.draftRestored
        let provider = controller.selection.provider
        let selected = controller.selectedModel
        let name = selected?.title ?? provider.name
        let effort = selected?.reasoningEfforts.isEmpty == false
            ? (controller.effort ?? selected?.defaultReasoningEffort)?.title : nil
        var title = AttributedString(name)
        if let effort {
            var detail = AttributedString(" · \(effort)")
            detail.foregroundColor = .secondaryLabel
            title += detail
        }
        title.font = .preferredFont(forTextStyle: .subheadline)
        if model.configuration?.attributedTitle != title { model.configuration?.attributedTitle = title }
        if provider != shownProvider {
            shownProvider = provider
            model.configuration?.image = AgentLogo.image(provider, side: 20, scale: TabIcon.inlineScale)
        }
        model.accessibilityLabel = "Model and reasoning effort"
        model.accessibilityValue = [provider.name, name, effort].compactMap { $0 }.joined(separator: ", ")
        model.menu = Self.menu(controller)
        plan.isHidden = !controller.planMode
        plan.isEnabled = controller.status == .idle || controller.status == .failed
        refreshPrimary()
    }

    /// Sends the typed message and attached files, if there are any.
    func sendNow() {
        guard hasDraft else { return }
        send()
    }

    func stopDictating() {
        dictation.stop()
    }

    private func showAttachments(_ attachments: [AgentChatAttachment]) {
        let ids = attachments.map(\.id)
        guard ids != shownAttachments else { return }
        let added = ids.count > shownAttachments.count
        shownAttachments = ids
        attachmentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attachment in attachments {
            attachmentStack.addArrangedSubview(AttachmentChip(attachment) { [weak self] id in self?.remove(id) })
        }
        attachmentStrip.isHidden = attachments.isEmpty
        refreshPrimary()
        guard added else { return }
        layoutIfNeeded()
        let end = attachmentStrip.contentSize.width - attachmentStrip.bounds.width
        attachmentStrip.setContentOffset(CGPoint(x: max(0, end), y: 0), animated: true)
    }

    private func remove(_ id: String) {
        guard let controller else { return }
        controller.detach(id)
        showAttachments(controller.draft.attachments)
    }

    private var hasDraft: Bool {
        !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !shownAttachments.isEmpty
    }

    private func attachMenu() -> UIMenu {
        var actions = [UIAction(title: "Photos", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
            self?.onAttach?(.photos)
        }]
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            actions.append(UIAction(title: "Camera", image: UIImage(systemName: "camera")) { [weak self] _ in
                self?.onAttach?(.camera)
            })
        }
        actions.append(UIAction(title: "Files", image: UIImage(systemName: "folder")) { [weak self] _ in
            self?.onAttach?(.files)
        })
        return UIMenu(children: actions)
    }

    /// As the desktop's model picker: each agent with its models, locked to the
    /// conversation's agent once it has started, then the reasoning effort,
    /// then plan mode.
    private static func menu(_ controller: AgentChatController) -> UIMenu {
        let selection = controller.selection
        let current = controller.effectiveModel
        let providers = AgentChatProvider.allCases.map { provider -> UIMenuElement in
            let models = controller.models[provider]
            let locked = !controller.canChangeProvider && provider != controller.snapshot?.provider
            var children: [UIMenuElement] = (models ?? []).map { model in
                UIAction(title: model.title, attributes: locked ? .disabled : [],
                         state: provider == selection.provider && model.id == current ? .on : .off) { _ in
                    controller.select(provider: provider, model: model.id)
                }
            }
            if children.isEmpty {
                children = [UIAction(title: models == nil ? "Loading models…" : "No models reported", attributes: .disabled) { _ in }]
            }
            return UIMenu(title: provider.name, subtitle: locked ? "Open a new agent pane to use it" : nil,
                          image: AgentLogo.image(provider, side: 22, scale: TabIcon.inlineScale),
                          children: children)
        }
        var children: [UIMenuElement] = [UIMenu(options: .displayInline, children: providers)]
        let efforts = controller.selectedModel?.reasoningEfforts ?? []
        if !efforts.isEmpty {
            let auto = UIAction(title: "Auto", state: controller.effort == nil ? .on : .off) { _ in
                controller.select(effort: nil)
            }
            children.append(UIMenu(title: "Reasoning Effort", options: .displayInline, children: [auto] + efforts.map { effort in
                UIAction(title: effort.title, state: controller.effort == effort ? .on : .off) { _ in
                    controller.select(effort: effort)
                }
            }))
        }
        let free = controller.status == .idle || controller.status == .failed
        let plan = UIAction(title: "Plan Mode", image: UIImage(systemName: "list.bullet.clipboard"),
                            attributes: free ? [] : .disabled, state: controller.planMode ? .on : .off) { _ in
            controller.togglePlanMode()
        }
        plan.subtitle = free ? "Plans before changing anything" : "Changes after the current response"
        plan.discoverabilityTitle = "Plan Mode (Shift-Tab)"
        children.append(UIMenu(options: .displayInline, children: [plan]))
        return UIMenu(children: children)
    }

    /// Which action the one button offers: Send for a draft, which queues while
    /// the agent works; Stop while it works with nothing to send, or while a
    /// message is on its way; Dictate otherwise.
    private var action: Action {
        let dictating = dictation.state != .idle
        let submitting = controller?.submitting == true
        if hasDraft && !dictating && !submitting { return .send }
        if controller?.isBusy == true && !dictating { return .stop }
        return .dictate
    }

    private func performPrimary() {
        switch action {
        case .send:
            send()
        case .stop:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            controller?.interrupt()
        case .dictate:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            dictation.toggle()
        }
    }

    private func send() {
        guard let controller, controller.canSend, !controller.busy else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        controller.draftChanged(text: text.text ?? "")
        controller.send()
        text.resignFirstResponder()
    }

    /// Adds dictated words where the cursor is, spaced from the text around them.
    private func insertDictation(_ heard: String) {
        let current = text.text ?? ""
        let range = text.selectedRange.location <= (current as NSString).length
            ? text.selectedRange : NSRange(location: (current as NSString).length, length: 0)
        let before = (current as NSString).substring(to: range.location)
        let spaced = before.isEmpty || before.last?.isWhitespace == true ? heard : " " + heard
        text.textStorage.replaceCharacters(in: range, with: spaced)
        text.selectedRange = NSRange(location: range.location + (spaced as NSString).length, length: 0)
        textViewDidChange(text)
    }

    private func refreshPrimary() {
        let action = action
        let listening = dictation.state != .idle
        let symbol: String
        let label: String
        switch action {
        case .send: (symbol, label) = ("arrow.up", "Send")
        case .stop: (symbol, label) = ("stop.fill", "Stop")
        case .dictate: (symbol, label) = (listening ? "waveform.circle.fill" : "waveform", listening ? "Finish Dictation" : "Dictate")
        }
        // Dark on the light button: prominent glass would draw the glyph in its own light color.
        let ink: UIColor = listening ? .white : .systemBackground
        primary.configuration?.image = UIImage(systemName: symbol,
                                               withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))?
            .withTintColor(ink, renderingMode: .alwaysOriginal)
        primary.tintColor = listening ? .tintColor : .label
        primary.accessibilityLabel = label
        primary.isEnabled = controller?.canSend != false || action == .stop
        if listening {
            primary.imageView?.addSymbolEffect(.pulse, options: .repeat(.continuous))
        } else {
            primary.imageView?.removeAllSymbolEffects()
        }
        placeholder.text = listening ? "Listening…" : "Message \(controller?.selection.provider.name ?? "the agent")"
        placeholder.isHidden = !text.text.isEmpty
    }

    func textViewDidChange(_ textView: UITextView) {
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        let maximum = (textView.font?.lineHeight ?? 20) * 6 + 16
        heightConstraint.constant = min(max(Self.minimumTextHeight, fitting), maximum)
        textView.isScrollEnabled = fitting > maximum
        controller?.draftChanged(text: textView.text ?? "")
        refreshPrimary()
    }
}

/// An attached file above the message: a photo's thumbnail, or a file's
/// icon and name, with a button that takes it off.
private final class AttachmentChip: UIView {
    let id: String

    init(_ attachment: AgentChatAttachment, onRemove: @escaping (String) -> Void) {
        id = attachment.id
        super.init(frame: .zero)
        let card = UIView()
        card.backgroundColor = .tertiarySystemFill
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let image = attachment.mimeType.hasPrefix("image/")
            ? UIImage(data: attachment.data)?.preparingThumbnail(of: CGSize(width: 112, height: 112)) : nil
        if let image {
            let view = UIImageView(image: image)
            view.contentMode = .scaleAspectFill
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(equalTo: card.heightAnchor),
                view.topAnchor.constraint(equalTo: card.topAnchor),
                view.bottomAnchor.constraint(equalTo: card.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            ])
        } else {
            let icon = UIImageView(image: UIImage(systemName: "doc.text"))
            icon.tintColor = .secondaryLabel
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let name = UILabel()
            name.text = attachment.name
            name.font = .preferredFont(forTextStyle: .footnote)
            name.lineBreakMode = .byTruncatingMiddle
            let size = UILabel()
            size.text = ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)
            size.font = .preferredFont(forTextStyle: .caption2)
            size.textColor = .secondaryLabel
            let labels = UIStackView(arrangedSubviews: [name, size])
            labels.axis = .vertical
            let row = UIStackView(arrangedSubviews: [icon, labels])
            row.alignment = .center
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(row)
            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
                row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
                row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
                row.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            ])
        }

        let remove = UIButton(configuration: .filled())
        remove.configuration?.image = UIImage(systemName: "xmark",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        remove.configuration?.cornerStyle = .capsule
        remove.configuration?.baseBackgroundColor = .systemGray
        remove.configuration?.baseForegroundColor = .white
        remove.configuration?.contentInsets = .zero
        remove.accessibilityLabel = "Remove \(attachment.name)"
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.addAction(UIAction { _ in onRemove(attachment.id) }, for: .primaryActionTriggered)
        addSubview(remove)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            remove.centerXAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
            remove.centerYAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            remove.widthAnchor.constraint(equalToConstant: 20),
            remove.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The remove button sits partly outside the chip and still takes taps.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -10, dy: -10).contains(point)
    }
}
