import ImageIO
import PhotosUI
import TabMobileKit
import TabProtocol
import TabShared
import UIKit
import UniformTypeIdentifiers

/// An agent pane: the conversation, and a glass composer riding the keyboard
/// with the task list's progress, running agents, the agent's question,
/// queued prompts and notices floating above it. The conversation scrolls
/// behind all of them.
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
    private let panelsScroll = UIScrollView()
    private let panels = UIStackView()
    private let taskProgressView = AgentTaskProgressView()
    private var taskProgress = AgentTaskProgress()
    private let subagents = AgentSubagentsView()
    private let notice = AgentNoticeView()
    private let question = AgentQuestionView()
    private let queue = AgentQueueView()
    private let emptyView = UIContentUnavailableView(configuration: .empty())
    private let latestButton = UIButton(configuration: .glass())
    /// What went wrong on this device, such as dictation; the controller's error shows otherwise.
    private var problem: String?
    private var problemRevision: UInt64?
    /// Sent images by attachment id, once loaded.
    private let images = NSCache<NSString, UIImage>()
    private var loadingImages: Set<String> = []
    private var didInitialScroll = false
    private var showsLatest = false
    private var followsEnd = true
    private var contentSizeObservation: NSKeyValueObservation?
    /// The prompt the previous and next prompt commands last moved to, until the reader scrolls.
    private var navigationPromptID: String?
    private var loadingHistory = false

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
        followEnd()

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)

        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.onAttach = { [weak self] source in self?.pickAttachments(from: source) }
        composer.onProblem = { [weak self] message in
            self?.problem = message
            self?.problemRevision = self?.controller.snapshot?.revision
            self?.updateNotice()
        }
        view.addSubview(composer)

        // From the top: the task list's progress, running agents, queued prompts,
        // the agent's question, then what went wrong. They scroll together when
        // the pane is too short for all of them.
        panels.axis = .vertical
        panels.spacing = 8
        panels.translatesAutoresizingMaskIntoConstraints = false
        for panel in [taskProgressView, subagents, queue, question, notice] as [UIView] { panels.addArrangedSubview(panel) }
        panelsScroll.addSubview(panels)
        panelsScroll.clipsToBounds = false
        panelsScroll.showsVerticalScrollIndicator = false
        panelsScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panelsScroll)
        configurePanels()

        latestButton.configuration?.image = UIImage(systemName: "arrow.down",
                                                    withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
        latestButton.configuration?.cornerStyle = .capsule
        latestButton.accessibilityLabel = "Scroll to latest"
        latestButton.isHidden = true
        latestButton.translatesAutoresizingMaskIntoConstraints = false
        latestButton.addAction(UIAction { [weak self] _ in
            self?.followsEnd = true
            self?.scrollToBottom(animated: true)
        }, for: .primaryActionTriggered)
        view.addSubview(latestButton)

        // Text keeps a readable measure: full width on a phone, a column on an iPad.
        let readable = ReadableColumn.guide(in: view, margin: 12)
        // The composer rests on the safe area's bottom edge, and keeps a gap above the keyboard.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        let composerOnSafeArea = composer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        composerOnSafeArea.priority = .defaultHigh
        // The composer and its cards fill the column whatever they hold.
        let composerFills = composer.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -24)
        composerFills.priority = .required - 1
        // As tall as the cards, until the pane is too short and they scroll.
        let panelsFit = panelsScroll.heightAnchor.constraint(equalTo: panels.heightAnchor)
        panelsFit.priority = .defaultHigh - 60
        NSLayoutConstraint.activate([
            composerOnSafeArea,
            composerFills,
            composer.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),
            composer.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor, constant: -40),
            emptyView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
            composer.leadingAnchor.constraint(equalTo: readable.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: readable.trailingAnchor),
            panelsScroll.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            panelsScroll.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            panelsScroll.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            panelsScroll.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            panels.topAnchor.constraint(equalTo: panelsScroll.contentLayoutGuide.topAnchor),
            panels.bottomAnchor.constraint(equalTo: panelsScroll.contentLayoutGuide.bottomAnchor),
            panels.leadingAnchor.constraint(equalTo: panelsScroll.contentLayoutGuide.leadingAnchor),
            panels.trailingAnchor.constraint(equalTo: panelsScroll.contentLayoutGuide.trailingAnchor),
            panels.widthAnchor.constraint(equalTo: panelsScroll.frameLayoutGuide.widthAnchor),
            panelsFit,
            question.heightAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.5),
            latestButton.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            latestButton.bottomAnchor.constraint(equalTo: panelsScroll.topAnchor, constant: -12),
            latestButton.widthAnchor.constraint(equalToConstant: 44),
            latestButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        // The transcript scrolls under the composer, which blurs it as glass does.
        collectionView.contentInset.bottom = 8
        addKeyCommand(UIKeyCommand(title: "Send", action: #selector(sendCommand), input: "\r", modifierFlags: .command))
        addKeyCommand(UIKeyCommand(title: "Plan Mode", action: #selector(planCommand), input: "\t", modifierFlags: .shift))
    }

    @objc private func sendCommand() { composer.sendNow() }
    @objc private func planCommand() { controller.togglePlanMode() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The last row can scroll clear of the topmost floating card.
        let shown = panels.arrangedSubviews.contains { !$0.isHidden }
        let top = shown ? panelsScroll.frame.minY : composer.frame.minY
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
        guard scrollView === collectionView else { return }
        if scrollView.isDragging || scrollView.isDecelerating {
            followsEnd = isNearBottom
            navigationPromptID = nil
        }
        updateLatestButton()
    }

    /// Rows start at estimated heights and grow as they're drawn, and images
    /// load late: while the reader is at the end, the end stays in view.
    private func followEnd() {
        contentSizeObservation = collectionView.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue != change.newValue else { return }
            MainActor.assumeIsolated {
                guard let self, self.followsEnd, self.didInitialScroll, !self.collectionView.isDragging else { return }
                self.scrollToBottom(animated: false)
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        controller.open()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        composer.stopDictating()
        controller.close()
    }

    /// Runs whenever the observed chat changes.
    override func updateProperties() {
        super.updateProperties()
        let snapshot = controller.snapshot
        composer.update(controller)
        apply(AgentTranscript.rows(snapshot, expanded: expandedTurns))
        emptyView.isHidden = snapshot == nil || !controller.isEmptyConversation
        if !emptyView.isHidden { showEmpty(controller.selection.provider) }
        let enabled = !controller.busy
        let pending = controller.pendingQuestion
        var changed = question.update(pending, enabled: enabled, saved: pending.flatMap { controller.draft.answers[$0.id] })
        changed = queue.update(controller.queuedPrompts, paused: controller.queuePaused, enabled: enabled,
                               earlier: controller.earlierQueued(than:)) || changed
        changed = subagents.update(controller.runningSubagents) || changed
        taskProgress.update(snapshot)
        changed = taskProgressView.show(taskProgress.target == nil ? nil : taskProgress.title) || changed
        // A problem here lasts until the conversation moves on.
        if snapshot?.revision != problemRevision { problem = nil }
        changed = notice.show(problem ?? controller.error) || changed
        if changed { animatePanels() }
    }

    private func updateNotice() {
        if notice.show(problem ?? controller.error) { animatePanels() }
    }

    private func animatePanels() {
        UIView.animate(withDuration: 0.25) {
            self.view.layoutIfNeeded()
        }
    }

    private func configurePanels() {
        question.onAnswer = { [weak self] item, answers, cancelled in
            self?.controller.answer(item, answers: answers, cancelled: cancelled)
        }
        question.onChange = { [weak self] item, answers in
            self?.controller.questionAnswersChanged(answers, for: item)
        }
        queue.onEdit = { [weak self] prompt in self?.editQueued(prompt) }
        queue.onRemove = { [weak self] prompt in self?.controller.removeQueued(prompt) }
        queue.onDeliver = { [weak self] prompt in self?.deliverQueued(prompt) }
        queue.onMoveEarlier = { [weak self] prompt in self?.controller.moveQueuedEarlier(prompt) }
        queue.onResume = { [weak self] in self?.controller.resumeQueue() }
        subagents.onReveal = { [weak self] id in self?.reveal(id) }
        taskProgressView.onReveal = { [weak self] in
            guard let self, let id = taskProgress.target else { return }
            reveal(id)
        }
    }

    /// Edits a queued prompt's text in a sheet that streaming updates leave
    /// alone; its files stay with it, and saving doesn't send it.
    private func editQueued(_ prompt: AgentQueuedPrompt) {
        guard presentedViewController == nil else { return }
        let editor = TextEditorViewController(
            title: "Edit Queued Prompt",
            note: prompt.state == .uncertain
                ? "The earlier delivery may have reached the agent. Editing doesn't send it again. Its attachments stay with it."
                : "Its attachments stay with it. Saving doesn't send it.",
            text: prompt.text, option: "Use the current model, reasoning effort and plan mode") { [weak self] outcome in
                guard case .saved(let text, let useCurrentSettings) = outcome else { return }
                self?.controller.editQueued(prompt, text: text, useCurrentSettings: useCurrentSettings)
            }
        present(editor.inSheet(), animated: true)
    }

    /// Sends a queued prompt now; one that may already have reached the agent asks first.
    private func deliverQueued(_ prompt: AgentQueuedPrompt) {
        guard prompt.state == .uncertain || prompt.state == .failed else {
            controller.deliverQueued(prompt)
            return
        }
        let alert = UIAlertController(
            title: "Send This Prompt Again?",
            message: "The earlier delivery may have reached the agent. Review the conversation first; sending again can repeat its actions.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Send Again", style: .default) { [weak self] _ in
            self?.controller.deliverQueued(prompt)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
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

    // MARK: Navigation

    /// The pane's own commands, for the tab's menu: the conversation's
    /// prompts, moving between them, and continuing a saved conversation.
    func paneMenu(openBeside: @escaping (AgentChatSnapshot) -> Void) -> UIMenu {
        let hasPrompts = controller.items.contains { $0.kind == .user }
        let outline = UIAction(title: "Prompts…", image: UIImage(systemName: "list.bullet.indent"),
                               attributes: hasPrompts ? [] : .disabled) { [weak self] _ in self?.showOutline() }
        let previous = UIAction(title: "Previous Prompt", image: UIImage(systemName: "chevron.up"),
                                attributes: hasPrompts ? [] : .disabled) { [weak self] _ in self?.navigatePrompt(previous: true) }
        let next = UIAction(title: "Next Prompt", image: UIImage(systemName: "chevron.down"),
                            attributes: hasPrompts ? [] : .disabled) { [weak self] _ in self?.navigatePrompt(previous: false) }
        let history = UIAction(title: "Continue a Conversation…", image: UIImage(systemName: "clock.arrow.circlepath"),
                               attributes: loadingHistory ? .disabled : []) { [weak self] _ in
            self?.showSavedConversations(openBeside: openBeside)
        }
        history.subtitle = "Saved by Claude Code or Codex for this folder"
        return UIMenu(title: "Conversation", options: .displayInline, children: [outline, previous, next, history])
    }

    /// A searchable list of the conversation's prompts; choosing one shows it.
    func showOutline() {
        guard presentedViewController == nil else { return }
        let picker = SearchPickerViewController(title: "Prompts", placeholder: "Search prompts") { [weak self] entry in
            self?.revealPrompt(entry.id)
        }
        picker.update(AgentPromptNavigation.entries(controller.items), note: "The prompts this conversation still holds.")
        present(picker.inSheet(), animated: true)
    }

    /// Shows the prompt before or after the last one moved to, or else the
    /// one above or below the top of the screen.
    func navigatePrompt(previous: Bool) {
        let prompts = controller.items.filter { $0.kind == .user }.map(\.id)
        let id: String?
        if let current = navigationPromptID {
            id = AgentPromptNavigation.destination(ids: prompts, current: current, previous: previous)
        } else {
            let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
            let positions = prompts.compactMap { id -> (String, CGFloat)? in
                guard let path = dataSource.indexPath(for: id),
                      let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { return nil }
                return (id, frame.minY)
            }
            id = previous ? positions.last(where: { $0.1 < top - 1 })?.0 : positions.first(where: { $0.1 > top + 1 })?.0
        }
        guard let id else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        revealPrompt(id)
    }

    private func revealPrompt(_ id: String) {
        reveal(id)
        navigationPromptID = id
    }

    /// Scrolls `id` to the top, unfolding its turn when one of its steps.
    private func reveal(_ id: String) {
        if rows[id] == nil, let turn = AgentTranscript.turn(holding: id, in: controller.snapshot) {
            expandedTurns.insert(turn)
            apply(AgentTranscript.rows(controller.snapshot, expanded: expandedTurns))
        }
        guard let path = dataSource.indexPath(for: id) else { return }
        followsEnd = false
        collectionView.scrollToItem(at: path, at: .top, animated: true)
        UISelectionFeedbackGenerator().selectionChanged()
        if let cell = collectionView.cellForItem(at: path) { UIAccessibility.post(notification: .layoutChanged, argument: cell) }
    }

    /// The files a turn changed, with their diffs to read and comment on.
    private func showChanges(_ checkpoint: AgentTurnCheckpoint) {
        guard presentedViewController == nil else { return }
        let changes = AgentChangesViewController(controller: controller, checkpoint: checkpoint)
        changes.onCommentsChanged = { [weak self] in self?.reconfigureChanges() }
        changes.onAddedToMessage = { [weak self] in
            guard let self else { return }
            composer.update(controller)
            composer.focus()
        }
        present(changes.inSheet(), animated: true)
    }

    /// Redraws the changed-files rows, whose comment counts may have changed.
    private func reconfigureChanges() {
        var snapshot = dataSource.snapshot()
        let ids = snapshot.itemIdentifiers.filter { if case .changes? = rows[$0] { true } else { false } }
        guard !ids.isEmpty else { return }
        snapshot.reconfigureItems(ids)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Lists the conversations Claude Code and Codex saved for this folder;
    /// choosing one continues it here when nothing has been said yet, or
    /// beside this pane otherwise.
    private func showSavedConversations(openBeside: @escaping (AgentChatSnapshot) -> Void) {
        guard !loadingHistory, presentedViewController == nil else { return }
        loadingHistory = true
        Task { [weak self] in
            guard let self else { return }
            defer { loadingHistory = false }
            let reply: AgentHistoryReply
            do {
                reply = try await controller.savedConversations()
            } catch {
                showHistoryProblem(error, doing: "list saved conversations")
                return
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let picker = SearchPickerViewController(title: "Continue a Conversation", placeholder: "Search titles or agents") {
                [weak self] entry in
                guard let saved = reply.entries.first(where: { $0.id == entry.id }) else { return }
                self?.continueConversation(saved, openBeside: openBeside)
            }
            picker.update(reply.entries.map { entry in
                AgentPickerEntry(id: entry.id, title: entry.title,
                                 detail: entry.provider.name + " · " + formatter.localizedString(for: entry.updatedAt, relativeTo: Date()))
            }, note: reply.truncated ? "The newest \(AgentHistoryReply.maxEntries) conversations. The Mac left older ones out."
                : reply.entries.isEmpty ? "Claude Code and Codex saved no other conversations for this folder."
                : "Conversations saved for this folder on the Mac.")
            present(picker.inSheet(), animated: true)
        }
    }

    private func continueConversation(_ entry: AgentHistoryEntry, openBeside: @escaping (AgentChatSnapshot) -> Void) {
        guard !loadingHistory else { return }
        loadingHistory = true
        Task { [weak self] in
            guard let self else { return }
            defer { loadingHistory = false }
            do {
                if let other = try await controller.continueConversation(entry) { openBeside(other) }
            } catch {
                showHistoryProblem(error, doing: "continue that conversation")
            }
        }
    }

    private func showHistoryProblem(_ error: Error, doing action: String) {
        problem = (error as? ClientError)?.serverCode == .unsupported
            ? "The Tab on this Mac can't \(action) yet. Update Tab on the Mac, then try again."
            : "Couldn't \(action): \(error.localizedDescription)"
        problemRevision = controller.snapshot?.revision
        updateNotice()
    }

    // MARK: Transcript

    private func configureDataSource() {
        let user = UICollectionView.CellRegistration<UserMessageCell, String> { [weak self] cell, _, id in
            guard let self, case .user(let item)? = rows[id] else { return }
            cell.configure(item) { [weak self] attachment in self?.image(attachment, in: item) }
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
            guard case .working(let turn)? = self?.rows[id] else { return }
            cell.configure(turn: turn)
        }
        let changes = UICollectionView.CellRegistration<ChangesCell, String> { [weak self] cell, _, id in
            guard let self, case .changes(_, let checkpoint)? = rows[id] else { return }
            cell.configure(checkpoint, comments: controller.reviewComments(for: checkpoint.id).count)
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
            case .changes?: view.dequeueConfiguredReusableCell(using: changes, for: path, item: id)
            case .notice?, nil: view.dequeueConfiguredReusableCell(using: notice, for: path, item: id)
            }
        }
    }

    /// A sent image, or nil while it loads; the row redraws once it has.
    private func image(_ attachment: AgentChatAttachmentDescriptor, in item: AgentChatItem) -> UIImage? {
        if let cached = images.object(forKey: attachment.id as NSString) { return cached }
        guard loadingImages.insert(attachment.id).inserted else { return nil }
        Task { [weak self] in
            guard let self else { return }
            let data = try? await controller.attachment(item: item.id, id: attachment.id).data
            let image = await Task.detached { data.flatMap { UIImage(data: $0)?.preparingThumbnail(of: CGSize(width: 720, height: 720)) } }.value
            loadingImages.remove(attachment.id)
            guard let image else { return }
            images.setObject(image, forKey: attachment.id as NSString)
            var snapshot = dataSource.snapshot()
            guard snapshot.indexOfItem(item.id) != nil else { return }
            snapshot.reconfigureItems([item.id])
            await dataSource.apply(snapshot, animatingDifferences: false)
        }
        return nil
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
            if didInitialScroll {
                scrollToBottom(animated: true)
                return
            }
            scrollToBottom(animated: false)
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
        case .changes(_, let checkpoint)?:
            showChanges(checkpoint)
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
        let room = AgentChatAttachment.maxCount - controller.draft.attachments.count
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
        if let problem = controller.attach(attachment) {
            showAttachmentProblem(problem)
            return
        }
        composer.update(controller)
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
