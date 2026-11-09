import ImageIO
import PhotosUI
import TabMobileKit
import TabProtocol
import UIKit
import UniformTypeIdentifiers

/// An agent pane: the conversation, and a glass composer riding the keyboard.
final class AgentPaneViewController: UIViewController, UICollectionViewDelegate {
    let controller: AgentChatController
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var rows: [String: TranscriptRow] = [:]
    private var order: [String] = []
    private var expandedTurns: Set<String> = []
    private var expandedItems: Set<String> = []
    private var stepPositions: [String: StepPosition] = [:]
    /// Rendered Markdown by item id, redone only when the text changes.
    private var rendered: [String: (text: String, value: NSAttributedString)] = [:]
    private let composer = AgentComposerView()
    private let emptyView = UIContentUnavailableView(configuration: .empty())
    private let latestButton = UIButton(configuration: .glass())
    private let errorNotice = UILabel()
    private var didInitialScroll = false
    private var showsLatest = false

    init(controller: AgentChatController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        var list = UICollectionLayoutListConfiguration(appearance: .plain)
        list.showsSeparators = false
        list.backgroundColor = .clear
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: list))
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.topEdgeEffect.style = .soft
        collectionView.allowsSelection = true
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        configureDataSource()

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)

        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.onSend = { [weak self] text, attachments in self?.controller.send(text, attachments: attachments) }
        composer.onStop = { [weak self] in self?.controller.interrupt() }
        composer.onAttach = { [weak self] source in self?.pickAttachments(from: source) }
        view.addSubview(composer)

        // What went wrong with the last command, above the composer until the next reply.
        errorNotice.font = .preferredFont(forTextStyle: .footnote)
        errorNotice.adjustsFontForContentSizeCategory = true
        errorNotice.textColor = .systemRed
        errorNotice.textAlignment = .center
        errorNotice.numberOfLines = 3
        errorNotice.isHidden = true
        errorNotice.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorNotice)

        latestButton.configuration?.image = UIImage(systemName: "arrow.down",
                                                    withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
        latestButton.configuration?.cornerStyle = .capsule
        latestButton.accessibilityLabel = "Scroll to latest"
        latestButton.isHidden = true
        latestButton.translatesAutoresizingMaskIntoConstraints = false
        latestButton.addAction(UIAction { [weak self] _ in self?.scrollToBottom(animated: true) }, for: .primaryActionTriggered)
        view.addSubview(latestButton)

        // Text keeps a readable measure: full width on a phone, a column on an iPad.
        let readable = ReadableColumn.guide(in: view, margin: 12)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor, constant: -40),
            emptyView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
            composer.leadingAnchor.constraint(equalTo: readable.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: readable.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            errorNotice.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 12),
            errorNotice.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -12),
            errorNotice.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            latestButton.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            latestButton.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -12),
            latestButton.widthAnchor.constraint(equalToConstant: 44),
            latestButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        // The transcript scrolls under the composer, which blurs it as glass does.
        collectionView.contentInset.bottom = 8
        addKeyCommand(UIKeyCommand(title: "Send", action: #selector(sendCommand), input: "\r", modifierFlags: .command))
    }

    @objc private func sendCommand() { composer.sendNow() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = errorNotice.isHidden ? composer.frame.minY : errorNotice.frame.minY
        let inset = view.bounds.maxY - top - view.safeAreaInsets.bottom + 8
        if collectionView.contentInset.bottom != inset {
            let atBottom = isNearBottom
            collectionView.contentInset.bottom = inset
            collectionView.verticalScrollIndicatorInsets.bottom = inset
            if atBottom { scrollToBottom(animated: false) }
        }
        updateLatestButton()
    }

    /// Offers a way back to the newest message once the reader has scrolled up.
    private func updateLatestButton() {
        let wanted = !order.isEmpty && !isNearBottom
        guard wanted != showsLatest else { return }
        showsLatest = wanted
        if wanted { latestButton.isHidden = false }
        UIView.animate(withDuration: 0.2) {
            self.latestButton.alpha = wanted ? 1 : 0
            self.latestButton.transform = wanted ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
        } completion: { _ in
            if !self.showsLatest { self.latestButton.isHidden = true }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateLatestButton()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        controller.open()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        controller.close()
    }

    /// Runs whenever the observed chat changes.
    override func updateProperties() {
        super.updateProperties()
        let snapshot = controller.snapshot
        composer.update(controller)
        apply(AgentTranscript.rows(snapshot, expanded: expandedTurns))
        emptyView.isHidden = !(snapshot?.items.isEmpty ?? false)
        if !emptyView.isHidden { showEmpty(controller.selection.provider) }
        let error = controller.error
        if errorNotice.text != error {
            errorNotice.text = error
            errorNotice.isHidden = error == nil
            view.setNeedsLayout()
        }
    }

    /// A new conversation: which agent it starts with, and that the menu changes it.
    private func showEmpty(_ provider: AgentChatProvider) {
        var empty = UIContentUnavailableConfiguration.empty()
        empty.image = AgentLogo.image(provider, side: 44)
        empty.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        empty.text = "New Agent"
        empty.secondaryText = "\(provider.name) runs on your Mac, in this project. Choose another agent or model from the menu beside the message."
        emptyView.configuration = empty
    }

    // MARK: Transcript

    private func configureDataSource() {
        let user = UICollectionView.CellRegistration<UserMessageCell, String> { [weak self] cell, _, id in
            guard case .user(let item)? = self?.rows[id] else { return }
            cell.configure(item)
        }
        let assistant = UICollectionView.CellRegistration<AssistantMessageCell, String> { [weak self] cell, _, id in
            guard let self, case .assistant(let item)? = rows[id] else { return }
            cell.configure(render(item))
        }
        let tool = UICollectionView.CellRegistration<ToolCell, String> { [weak self] cell, _, id in
            guard let self, case .tool(let item)? = rows[id] else { return }
            cell.configure(item, expanded: expandedItems.contains(id), position: stepPositions[id] ?? .only)
        }
        let thinking = UICollectionView.CellRegistration<ThinkingCell, String> { [weak self] cell, _, id in
            guard let self, case .thinking(let item)? = rows[id] else { return }
            cell.configure(item, expanded: expandedItems.contains(id))
        }
        let approval = UICollectionView.CellRegistration<ApprovalCell, String> { [weak self] cell, _, id in
            guard let self, case .approval(let item)? = rows[id] else { return }
            cell.configure(item, busy: controller.busy)
            cell.onAnswer = { [weak self] allow in self?.controller.approve(item, allow: allow) }
        }
        let notice = UICollectionView.CellRegistration<NoticeCell, String> { [weak self] cell, _, id in
            guard case .notice(let item, let isError)? = self?.rows[id] else { return }
            cell.configure(item, isError: isError)
        }
        let work = UICollectionView.CellRegistration<WorkCell, String> { [weak self] cell, _, id in
            guard case .work(_, let steps, let duration, let expanded)? = self?.rows[id] else { return }
            cell.configure(steps: steps, duration: duration, expanded: expanded)
        }
        let working = UICollectionView.CellRegistration<WorkingCell, String> { [weak self] cell, _, id in
            guard case .working(let since)? = self?.rows[id] else { return }
            cell.configure(since: since)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] view, path, id in
            switch self?.rows[id] {
            case .user?: view.dequeueConfiguredReusableCell(using: user, for: path, item: id)
            case .assistant?: view.dequeueConfiguredReusableCell(using: assistant, for: path, item: id)
            case .tool?: view.dequeueConfiguredReusableCell(using: tool, for: path, item: id)
            case .thinking?: view.dequeueConfiguredReusableCell(using: thinking, for: path, item: id)
            case .approval?: view.dequeueConfiguredReusableCell(using: approval, for: path, item: id)
            case .work?: view.dequeueConfiguredReusableCell(using: work, for: path, item: id)
            case .working?: view.dequeueConfiguredReusableCell(using: working, for: path, item: id)
            case .notice?, nil: view.dequeueConfiguredReusableCell(using: notice, for: path, item: id)
            }
        }
    }

    private func render(_ item: AgentChatItem) -> NSAttributedString {
        if let cached = rendered[item.id], cached.text == item.text { return cached.value }
        let value = MarkdownRenderer.render(item.text)
        rendered[item.id] = (item.text, value)
        return value
    }

    /// Where each tool step sits in its run of steps, which share one card.
    private static func stepPositions(_ order: [String], rows: [String: TranscriptRow]) -> [String: StepPosition] {
        let isStep = order.map { id -> Bool in
            if case .tool? = rows[id] { true } else { false }
        }
        var positions: [String: StepPosition] = [:]
        for (index, id) in order.enumerated() where isStep[index] {
            positions[id] = StepPosition(joinsPrevious: index > 0 && isStep[index - 1],
                                         joinsNext: index + 1 < order.count && isStep[index + 1])
        }
        return positions
    }

    /// Applies new rows, reconfiguring only the ones whose content changed.
    private func apply(_ next: [TranscriptRow]) {
        let wasAtBottom = isNearBottom || !didInitialScroll
        let previous = rows
        var nextRows: [String: TranscriptRow] = [:]
        var nextOrder: [String] = []
        for row in next where nextRows[row.id] == nil {
            nextRows[row.id] = row
            nextOrder.append(row.id)
        }
        rows = nextRows
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(nextOrder)
        let previousPositions = stepPositions
        stepPositions = Self.stepPositions(nextOrder, rows: nextRows)
        // A step whose neighbors changed redraws its corners.
        let changed = nextOrder.filter { id in
            guard let old = previous[id] else { return false }
            return old != nextRows[id] || previousPositions[id] != stepPositions[id]
        }
        // Reconfiguring keeps the cell, so only rows that keep their kind may;
        // an answered approval becomes a notice and needs a new cell.
        let sameKind = changed.filter { previous[$0]?.kind == nextRows[$0]?.kind }
        snapshot.reconfigureItems(sameKind)
        snapshot.reloadItems(changed.filter { !sameKind.contains($0) })
        let structural = nextOrder != order
        order = nextOrder
        dataSource.apply(snapshot, animatingDifferences: didInitialScroll && structural) { [weak self] in
            guard let self, wasAtBottom, !nextOrder.isEmpty else { return }
            scrollToBottom(animated: didInitialScroll)
            didInitialScroll = true
        }
    }

    private var isNearBottom: Bool {
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        return collectionView.contentSize.height - visibleBottom < 120
    }

    private func scrollToBottom(animated: Bool) {
        let height = collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
        let offset = max(-collectionView.adjustedContentInset.top, height - collectionView.bounds.height)
        collectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: animated)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return false }
        switch rows[id] {
        case .tool?, .thinking?:
            if expandedItems.contains(id) { expandedItems.remove(id) } else { expandedItems.insert(id) }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([id])
            dataSource.apply(snapshot, animatingDifferences: true)
        case .work(let turn, _, _, _)?:
            if expandedTurns.contains(turn) { expandedTurns.remove(turn) } else { expandedTurns.insert(turn) }
            apply(AgentTranscript.rows(controller.snapshot, expanded: expandedTurns))
        default:
            break
        }
        UISelectionFeedbackGenerator().selectionChanged()
        return false
    }

    /// Long press copies a tool's output or a thought. On a message's text it
    /// selects instead, so part of the message can be copied.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        if isOnMessageText(point, in: collectionView) { return nil }
        guard let path = indexPaths.first, let id = dataSource.itemIdentifier(for: path), let text = copyText(rows[id]) else {
            return nil
        }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            }])
        })
    }

    private func isOnMessageText(_ point: CGPoint, in collectionView: UICollectionView) -> Bool {
        var view = collectionView.hitTest(point, with: nil)
        while let current = view, current !== collectionView {
            if current is TranscriptTextView { return true }
            view = current.superview
        }
        return false
    }

    private func copyText(_ row: TranscriptRow?) -> String? {
        let text: String?
        switch row {
        case .user(let item)?, .assistant(let item)?: text = item.text
        case .tool(let item)?: text = item.tool?.output ?? item.detail ?? item.tool?.summary
        case .thinking(let item)?: text = item.detail
        default: text = nil
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

// MARK: Attachments

extension AgentPaneViewController: PHPickerViewControllerDelegate, UIDocumentPickerDelegate,
    UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func pickAttachments(from source: AttachmentSource) {
        let room = AgentChatAttachment.maxCount - composer.attachments.count
        guard room > 0 else {
            showAttachmentProblem("A message can carry up to \(AgentChatAttachment.maxCount) files.")
            return
        }
        switch source {
        case .photos:
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = room
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            present(picker, animated: true)
        case .camera:
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = self
            present(picker, animated: true)
        case .files:
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
            picker.allowsMultipleSelection = true
            picker.delegate = self
            present(picker, animated: true)
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            let name = (result.itemProvider.suggestedName ?? "Photo") + ".jpg"
            result.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                let attachment = data.flatMap { AttachmentFiles.photo($0, name: name) }
                Task { @MainActor in
                    guard let attachment else {
                        self?.showAttachmentProblem("Couldn't read \(name).")
                        return
                    }
                    self?.addAttachment(attachment)
                }
            }
        }
    }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 1),
              let attachment = AttachmentFiles.photo(data, name: "Photo.jpg") else { return }
        addAttachment(attachment)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for url in urls {
            guard let attachment = AttachmentFiles.file(at: url) else {
                showAttachmentProblem("Couldn't read \(url.lastPathComponent).")
                continue
            }
            addAttachment(attachment)
        }
    }

    private func addAttachment(_ attachment: AgentChatAttachment) {
        if let problem = AgentDraftAttachments.problem(adding: attachment, to: composer.attachments) {
            showAttachmentProblem(problem)
            return
        }
        composer.add(attachment)
    }

    private func showAttachmentProblem(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Can't Attach", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// Turns picked photos and files into attachments the agent can read.
enum AttachmentFiles {
    /// Photos are sent as JPEG no larger than an agent reads, whatever their format.
    static func photo(_ data: Data, name: String) -> AgentChatAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { return nil }
        return AgentChatAttachment(name: name, mimeType: "image/jpeg", data: jpeg)
    }

    static func file(at url: URL) -> AgentChatAttachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let name = url.lastPathComponent
        let mimeType = AgentDraftAttachments.mimeType(forFilename: name)
        if AgentDraftAttachments.needsConversion(mimeType: mimeType) {
            return photo(data, name: url.deletingPathExtension().lastPathComponent + ".jpg")
        }
        return AgentChatAttachment(name: name, mimeType: mimeType, data: data)
    }
}

/// The agents' marks from Tab Icons, in their hues, as the desktop shows them.
enum AgentLogo {
    @MainActor
    static func image(_ provider: AgentChatProvider, side: CGFloat, scale: CGFloat = 1) -> UIImage? {
        TabIcon.agent(provider == .claude ? .claude : .codex).image(side: side, scale: scale)
    }
}
