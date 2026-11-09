import TabMobileKit
import TabProtocol
import UIKit

/// The message field: Return sends from a hardware keyboard, Shift-Return
/// starts a new line, as on the desktop; the on-screen keyboard's Return
/// stays a line break with the Send button beside it.
final class ComposerTextView: UITextView {
    var onReturn: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(title: "Send", action: #selector(returnPressed), input: "\r")
        send.wantsPriorityOverSystemBehavior = true
        let newline = UIKeyCommand(title: "New Line", action: #selector(newLine), input: "\r", modifierFlags: .shift)
        newline.wantsPriorityOverSystemBehavior = true
        return [send, newline]
    }

    @objc private func returnPressed() { onReturn?() }
    @objc private func newLine() { insertText("\n") }
}

/// Where an attachment comes from.
enum AttachmentSource {
    case photos, camera, files
}

/// The composer in a glass card: attached files, the message, then a row
/// with Attach, the model and effort, and Send, which turns into Stop while
/// the agent works.
final class AgentComposerView: UIView, UITextViewDelegate {
    private static let minimumTextHeight: CGFloat = 40

    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let attachmentStrip = UIScrollView()
    private let attachmentStack = UIStackView()
    private let text = ComposerTextView()
    private let placeholder = UILabel()
    private let attach = UIButton(configuration: .gray())
    private let model = UIButton(configuration: .gray())
    private let send = UIButton(configuration: .prominentGlass())
    private var heightConstraint: NSLayoutConstraint!
    private var running = false
    private var shownProvider: AgentChatProvider?
    private(set) var attachments: [AgentChatAttachment] = []
    var onSend: ((String, [AgentChatAttachment]) -> Void)?
    var onStop: (() -> Void)?
    var onAttach: ((AttachmentSource) -> Void)?

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
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        text.addSubview(placeholder)

        attach.configuration?.image = UIImage(systemName: "plus",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        attach.configuration?.baseForegroundColor = .label
        attach.configuration?.cornerStyle = .capsule
        attach.showsMenuAsPrimaryAction = true
        attach.menu = attachMenu()
        attach.accessibilityLabel = "Attach"

        model.configuration?.baseForegroundColor = .label
        model.configuration?.cornerStyle = .capsule
        model.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 16)
        model.configuration?.imagePadding = 8
        model.configuration?.titleLineBreakMode = .byTruncatingTail
        model.showsMenuAsPrimaryAction = true
        model.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        send.configuration?.cornerStyle = .capsule
        send.tintColor = .label
        send.addAction(UIAction { [weak self] _ in self?.primary() }, for: .primaryActionTriggered)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = UIStackView(arrangedSubviews: [attach, model, spacer, send])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 8

        let content = UIStackView(arrangedSubviews: [attachmentStrip, text, bar])
        content.axis = .vertical
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(content)

        heightConstraint = text.heightAnchor.constraint(equalToConstant: Self.minimumTextHeight)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -8),
            content.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -8),
            attachmentStrip.heightAnchor.constraint(equalToConstant: 64),
            attachmentStack.topAnchor.constraint(equalTo: attachmentStrip.contentLayoutGuide.topAnchor, constant: 4),
            attachmentStack.bottomAnchor.constraint(equalTo: attachmentStrip.contentLayoutGuide.bottomAnchor),
            attachmentStack.leadingAnchor.constraint(equalTo: attachmentStrip.contentLayoutGuide.leadingAnchor, constant: 4),
            attachmentStack.trailingAnchor.constraint(equalTo: attachmentStrip.contentLayoutGuide.trailingAnchor, constant: -4),
            attachmentStack.heightAnchor.constraint(equalTo: attachmentStrip.frameLayoutGuide.heightAnchor, constant: -4),
            heightConstraint,
            placeholder.leadingAnchor.constraint(equalTo: text.leadingAnchor, constant: 9),
            placeholder.topAnchor.constraint(equalTo: text.topAnchor, constant: 10),
            attach.widthAnchor.constraint(equalToConstant: 44),
            attach.heightAnchor.constraint(equalToConstant: 44),
            model.heightAnchor.constraint(equalToConstant: 44),
            send.widthAnchor.constraint(equalToConstant: 44),
            send.heightAnchor.constraint(equalToConstant: 44),
        ])
        refreshSend()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ controller: AgentChatController) {
        running = controller.isRunning
        let provider = controller.selection.provider
        placeholder.text = "Message \(provider.name)"
        let selected = controller.selectedModel
        let name = selected?.title ?? provider.name
        let effort = selected?.reasoningEfforts.isEmpty == false
            ? (controller.effort ?? selected?.defaultReasoningEffort)?.title : nil
        var title = AttributedString(name)
        if let effort {
            var detail = AttributedString(" \(effort)")
            detail.foregroundColor = .secondaryLabel
            title += detail
        }
        title.font = .preferredFont(forTextStyle: .body)
        if model.configuration?.attributedTitle != title { model.configuration?.attributedTitle = title }
        if provider != shownProvider {
            shownProvider = provider
            model.configuration?.image = AgentLogo.image(provider, side: 22, scale: TabIcon.inlineScale)
        }
        model.accessibilityLabel = [provider.name, name, effort].compactMap { $0 }.joined(separator: ", ")
        model.menu = Self.menu(controller)
        refreshSend()
    }

    /// Sends the typed message and attached files, if there are any.
    func sendNow() {
        guard hasDraft else { return }
        primary()
    }

    /// Adds a file to the next message.
    func add(_ attachment: AgentChatAttachment) {
        attachments.append(attachment)
        let chip = AttachmentChip(attachment) { [weak self] id in self?.remove(id) }
        attachmentStack.addArrangedSubview(chip)
        attachmentStrip.isHidden = false
        refreshSend()
        layoutIfNeeded()
        let end = attachmentStrip.contentSize.width - attachmentStrip.bounds.width
        attachmentStrip.setContentOffset(CGPoint(x: max(0, end), y: 0), animated: true)
    }

    private func remove(_ id: String) {
        attachments.removeAll { $0.id == id }
        for case let chip as AttachmentChip in attachmentStack.arrangedSubviews where chip.id == id {
            chip.removeFromSuperview()
        }
        attachmentStrip.isHidden = attachments.isEmpty
        refreshSend()
    }

    private func clearAttachments() {
        attachments = []
        attachmentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        attachmentStrip.isHidden = true
    }

    private var hasDraft: Bool {
        !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
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

    /// As the desktop's model menu: each agent with its models, locked to the
    /// conversation's agent once it has started, then effort and access.
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
            let menu = UIMenu(title: provider.name, subtitle: locked ? "Open a new agent pane to use it" : nil,
                              image: AgentLogo.image(provider, side: 22, scale: TabIcon.inlineScale),
                              children: children)
            return menu
        }
        let efforts = (controller.selectedModel?.reasoningEfforts ?? []).map { effort in
            UIAction(title: effort.title, state: controller.effort == effort ? .on : .off) { _ in
                controller.select(effort: effort)
            }
        }
        let access = AgentAccessMode.allCases.map { mode in
            UIAction(title: mode.title, state: (controller.snapshot?.accessMode ?? .standard) == mode ? .on : .off) { _ in
                controller.setAccess(mode)
            }
        }
        var children: [UIMenuElement] = [UIMenu(options: .displayInline, children: providers)]
        if !efforts.isEmpty {
            children.append(UIMenu(title: "Effort", image: UIImage(systemName: "gauge.with.dots.needle.50percent"),
                                   children: [UIAction(title: "Auto", state: controller.effort == nil ? .on : .off) { _ in
                                       controller.select(effort: nil)
                                   }] + efforts))
        }
        children.append(UIMenu(title: "Access", image: UIImage(systemName: "lock.shield"), children: access))
        return UIMenu(children: children)
    }

    private func primary() {
        if running, !hasDraft {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            onStop?()
            return
        }
        guard hasDraft else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onSend?(text.text ?? "", attachments)
        text.text = ""
        clearAttachments()
        textViewDidChange(text)
        text.resignFirstResponder()
    }

    private func refreshSend() {
        let stop = running && !hasDraft
        // Dark on the light button: prominent glass would draw the glyph in its own light color.
        send.configuration?.image = UIImage(systemName: stop ? "stop.fill" : "arrow.up",
                                            withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))?
            .withTintColor(.systemBackground, renderingMode: .alwaysOriginal)
        send.accessibilityLabel = stop ? "Stop" : "Send"
        send.isEnabled = stop || hasDraft
        placeholder.isHidden = !text.text.isEmpty
    }

    func textViewDidChange(_ textView: UITextView) {
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        let maximum = (textView.font?.lineHeight ?? 20) * 6 + 16
        heightConstraint.constant = min(max(Self.minimumTextHeight, fitting), maximum)
        textView.isScrollEnabled = fitting > maximum
        refreshSend()
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
