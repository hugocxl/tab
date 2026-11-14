import AppKit
import TabCore
import TabProtocol

/// A quiet, readable conversation above a bottom-anchored native composer.
@MainActor
final class AgentPaneView: ThemedView {
    let model = AgentTextPopUp(label: "Model")
    let effort = AgentReasoningPopUp(label: "Reasoning effort")
    let plan = AgentPlanButton(frame: .zero)
    let composer = AgentComposerTextView()
    let promptQueue = AgentQueueView(frame: .zero)
    let subagents = AgentSubagentsView(frame: .zero)
    let taskProgressButton = PillButton("", style: .plain)
    private var taskProgress = AgentTaskProgress()
    let panelScroll = NSScrollView()
    private let panelDocument = AgentPanelDocument()
    var outlinePicker: AgentSearchPicker?
    var outlineSource: [AgentChatItem]?
    var navigationPromptID: String?
    let questions = AgentQuestionView(frame: .zero)
    var citationEnvironmentId: String?
    var citationThreadId: String?
    let send = AgentRoundButton(kind: .send)
    let stop = AgentRoundButton(kind: .stop)
    let contextIndicator = AgentContextIndicator(frame: .zero)
    /// Dictation shares the send and stop slot: it shows while the draft is empty and idle.
    let microphone = AgentRoundButton(kind: .dictate)
    let attach = AgentIconButton(icon: .plus, label: "Attach files", iconSize: 18)
    /// The model and reasoning effort, chosen together; `model` and `effort` hold the menus.
    private(set) lazy var modelPicker = AgentModelPicker(model: model, effort: effort)
    /// Dictation is authorizing or listening.
    var dictating = false {
        didSet {
            guard dictating != oldValue else { return }
            microphone.active = dictating
            updatePrimaryAction()
        }
    }
    let attachmentStrip = AgentAttachmentStrip(frame: .zero)
    let suggestions = AgentComposerSuggestionsView(frame: .zero)
    let retry = PillButton("Refresh", style: .plain)
    /// Closes a composer notice; errors offer Refresh instead.
    let dismissNotice = AgentIconButton(icon: .close, label: "Dismiss message", iconSize: 12)
    let feedback = NSTextField(wrappingLabelWithString: "")
    let transcriptScroll = NSScrollView()
    let composerScroll = NSScrollView()
    let transcript = AgentTranscriptDocument()
    /// The find bar, created the first time Find opens; hidden while closed.
    var findBar: AgentConversationFindBar?
    /// Find's matches while the bar is open; nil when closed, so the transcript does no Find work.
    var findModel: AgentConversationFindModel?
    let findHighlighter = AgentConversationFindHighlighter()
    /// Off-screen renders of unmounted messages, so Find counts what the transcript shows.
    let findTexts = AgentConversationFindTextCache()
    /// Cite and Copy, floating above a finished selection in an assistant message.
    let selectionToolbar = AgentSelectionToolbar(frame: .zero)
    /// The quotation currently highlighted after following a citation.
    var citationHighlight: [(view: AgentRichTextView, range: NSRange)] = []
    var citationHighlightGeneration: UInt64 = 0
    /// Reports a failed conversation action, such as an unavailable citation or HTML document.
    var onActionError: ((String) -> Void)?
    /// The conversation as last rendered.
    private(set) var snapshot: AgentChatSnapshot?
    /// The typed services the conversation body and its controls call.
    let actions = AgentConversationActions()
    /// Pull-request previews, file metadata and template actions of assistant links.
    let linkServices = AgentConversationLinkServices()
    /// Images, video and audio of assistant Markdown, cached for this conversation.
    let mediaLoader = AgentMediaLoader()

    private let composerCard = AgentSurfaceCard(style: .agentComposer)
    /// Errors and status notes, in a glass card just above the composer.
    private let notice = AgentSurfaceCard(style: .agentPanel)
    private let emptyTitle = makeLabel("What can I help with?", font: AppFont.system(21, weight: .medium))
    private let emptyDetail = makeLabel("Ask a question or make something new.", font: AppFont.body)
    private let activity = AgentSurfaceCard(style: .agentActivity)
    private var busy = false
    private let activityLabel = makeLabel("", font: AppFont.small)
    private var activityStatus: AgentChatStatus = .idle
    private var submitting = false
    private var renderedItems: [AgentChatItem] = []
    private var renderedTurns: [AgentChatTurn] = []
    private var renderedOmitted = 0
    private var lastViewportWidth: CGFloat = 0
    private var followingEnd = true
    private var scrollMutationDepth = 0
    private var boundsObserver: NSObjectProtocol?
    private let endButton = AgentEndButton()
    var onApproval: ((String, Bool) -> Void)?
    var onApprovalChoice: ((String, AgentApprovalChoice) -> Void)? {
        didSet { transcript.onApprovalChoice = { [weak self] id, choice in self?.onApprovalChoice?(id, choice) } }
    }
    var onRunShellCommand: ((String) -> Void)? { didSet { transcript.onRunShellCommand = onRunShellCommand } }
    var onOpenAttachment: ((String, AgentChatAttachmentDescriptor, Bool) -> Void)? { didSet { transcript.onOpenAttachment = onOpenAttachment } }
    var fetchAttachment: AgentAttachmentCache.Fetch? { didSet { transcript.fetchAttachment = fetchAttachment } }
    var onPreviewAttachments: ((String, [AgentChatAttachmentDescriptor], Int) -> Void)? { didSet { transcript.onPreviewAttachments = onPreviewAttachments } }
    var onOpenFile: ((String, Int?) -> Void)?
    /// Loads archived items above the oldest shown; nil hides the button.
    var onLoadEarlier: (() -> Void)? {
        didSet { transcript.onEarlier = onLoadEarlier == nil ? nil : { [weak self] in self?.onLoadEarlier?() } }
    }
    /// Where a new conversation works, such as “Tab on main”, for the empty state.
    var workspaceDescription: (() -> String?)?
    var workspaceRoot: String? {
        didSet {
            transcript.workspaceRoot = workspaceRoot
            linkServices.workspaceRoot = workspaceRoot
        }
    }
    var onOpenToolDiff: ((String, AgentToolActivity) -> Void)?
    var onOpenCheckpoint: ((String, String?) -> Void)?
    /// Opens the steps of the agent a transcript's Agent tool row started.
    var onOpenSubagent: ((String) -> Void)? { didSet { transcript.onOpenSubagent = onOpenSubagent } }
    /// Puts a user message's text in the composer as a new prompt.
    var onEditPrompt: ((AgentChatItem) -> Void)? { didSet { transcript.onEditPrompt = onEditPrompt } }
    /// Opens a conversation forked from before a user message.
    var onForkPrompt: ((AgentChatItem) -> Void)? { didSet { transcript.onForkPrompt = onForkPrompt } }
    /// Reverts a turn's changed files, all or some.
    var onRevert: ((AgentTurnCheckpoint, [String]?) -> Void)? { didSet { transcript.onRevert = onRevert } }
    var onShowFullOutput: ((String) -> Void)? { didSet { transcript.onShowFullOutput = onShowFullOutput } }
    /// Copies the whole conversation as Markdown.
    var onCopyConversation: (() -> Void)? { didSet { transcript.conversationMenu = { [weak self] in self?.conversationMenuItems() ?? [] } } }
    /// Opens a new conversation in place of one that ended.
    let newConversation = PillButton("New Conversation", style: .plain)
    /// Submits the failed or stopped turn's prompt again as a new prompt.
    let retryTurn = PillButton("Retry", style: .plain)
    static let readableWidth: CGFloat = 896

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        actions.surface = self
        configureLinkServices()
        transcriptScroll.drawsBackground = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.scrollerStyle = .overlay
        transcriptScroll.documentView = transcript
        transcriptScroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: transcriptScroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didScroll() }
        }
        transcript.onOpenToolDiff = { [weak self] id, activity in self?.onOpenToolDiff?(id, activity) }
        transcript.onOpenCheckpoint = { [weak self] id, path in self?.onOpenCheckpoint?(id, path) }
        transcript.onApproval = { [weak self] id, allow in self?.onApproval?(id, allow) }
        transcript.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
        transcript.onHTMLDocument = { [weak self] action, reference in self?.performHTMLDocument(action, reference) }
        transcript.writeProjectFile = { [weak self] path, contents, cwd in
            guard let self else { throw ModelError("The conversation was closed.") }
            return try await self.actions.writeProjectFile(path, contents: contents, cwd: cwd)
        }
        transcript.onOpenCitation = { [weak self] citation in self?.openCitation(citation) }
        transcript.onDisclosure = { [weak self] in
            guard let self else { return }
            // A disclosure is deliberate navigation, not a reason to jump to the end.
            self.followingEnd = false
            self.preserveScroll {
                self.transcript.reflow(viewportWidth: self.transcriptScroll.contentSize.width)
            }
        }

        composer.isRichText = false
        composer.importsGraphics = false
        composer.allowsUndo = true
        composer.font = AppFont.system(14, weight: .light)
        composer.drawsBackground = false
        composer.isAutomaticQuoteSubstitutionEnabled = false
        composer.isAutomaticDashSubstitutionEnabled = false
        composer.isAutomaticTextReplacementEnabled = false
        composer.isVerticallyResizable = true
        composer.isHorizontallyResizable = false
        composer.autoresizingMask = [.width]
        composer.textContainer?.widthTracksTextView = true
        composer.textContainer?.lineFragmentPadding = 0
        composer.textContainerInset = NSSize(width: 4, height: 6)
        composer.minSize = .zero
        composer.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        composer.setAccessibilityLabel("Message to agent")
        composer.setAccessibilityHelp("Ask anything. Return sends; Shift-Return adds a new line; Shift-Tab toggles plan mode.")
        composer.onEdit = { [weak self] in self?.refreshComposer() }
        composer.onOpenCitation = { [weak self] citation in self?.openCitation(citation) }
        composer.onPasteContext = { [weak self] pasteboard in self?.pasteContextFragment(from: pasteboard) ?? false }
        composerScroll.documentView = composer
        composerScroll.drawsBackground = false
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.scrollerStyle = .overlay
        plan.isHidden = true
        plan.setAccessibilityLabel("Disable plan mode")
        plan.toolTip = "Plan mode · Shift-Tab to toggle"
        attach.toolTip = "Attach files or drop them into the message box"
        attach.filled = true
        // The pop-ups keep the menus and selection; the combined picker presents them.
        model.isHidden = true
        effort.isHidden = true
        for child in [composerScroll, attachmentStrip, attach, plan, model, effort, modelPicker, contextIndicator, microphone, send, stop] {
            composerCard.addSubview(child)
            // This surface uses measured frames: controls must not bring their own size constraints.
            child.translatesAutoresizingMaskIntoConstraints = true
        }
        stop.isHidden = true
        model.toolTip = "Choose the provider and model for the next message"
        effort.toolTip = "Choose the reasoning effort for the next message"
        activityLabel.setAccessibilityLabel("Agent activity")
        activity.addSubview(activityLabel)
        activityLabel.translatesAutoresizingMaskIntoConstraints = true
        activity.isHidden = true
        activity.toolTip = "Show what the agent is waiting for"
        activity.setAccessibilityRole(.button)
        activity.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(activityPressed)))
        NotificationCenter.default.addObserver(self, selector: #selector(textScaleDidChange), name: .agentTextScaleDidChange, object: nil)
        feedback.font = AppFont.small
        feedback.isSelectable = true
        feedback.maximumNumberOfLines = 2
        feedback.lineBreakMode = .byTruncatingTail
        for child in [feedback, retry, retryTurn, newConversation, dismissNotice] as [NSView] {
            notice.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = true
        }
        notice.isHidden = true
        for label in [emptyTitle, emptyDetail] {
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = true
        }
        // Suggestions sit behind the composer card so their lower edge tucks under it.
        // The transcript scrolls under everything that floats over its lower edge.
        for child in [transcriptScroll, emptyTitle, emptyDetail, endButton, suggestions, composerCard, notice, panelScroll, activity] {
            addSubview(child)
        }
        panelScroll.documentView = panelDocument
        panelScroll.drawsBackground = false
        panelScroll.hasVerticalScroller = true
        panelScroll.autohidesScrollers = true
        panelScroll.scrollerStyle = .overlay
        for panel in [subagents, promptQueue, questions, taskProgressButton] as [NSView] {
            panel.translatesAutoresizingMaskIntoConstraints = true
            panelDocument.addSubview(panel)
        }
        taskProgressButton.font = AppFont.small
        taskProgressButton.alignment = .left
        taskProgressButton.lineBreakMode = .byTruncatingTail
        taskProgressButton.isHidden = true
        taskProgressButton.onPress = { [weak self] in
            guard let self, let id = self.taskProgress.target else { return }
            self.reveal(.item(id))
        }
        retry.isHidden = true
        retryTurn.isHidden = true
        newConversation.isHidden = true
        dismissNotice.isHidden = true
        suggestions.isHidden = true
        selectionToolbar.isHidden = true
        selectionToolbar.onCite = { [weak self] in self?.citeSelection() }
        selectionToolbar.onCopy = { [weak self] in self?.copySelection() }
        addSubview(selectionToolbar)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        endButton.onPress = { [weak self] in self?.scrollToEnd() }
        endButton.isHidden = true
        retry.translatesAutoresizingMaskIntoConstraints = true
        themeDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    override func layout() {
        if lastViewportWidth != bounds.width { hideSelectionToolbar() }
        let anchor = captureScrollAnchor()
        scrollMutationDepth += 1
        defer { scrollMutationDepth -= 1 }
        let width = max(0, min(Self.readableWidth, bounds.width - 32))
        let left = floor((bounds.width - width) / 2)
        updatePrimaryAction()
        let editorX: CGFloat = 14
        let editorWidth = max(1, width - editorX * 2)
        composerScroll.frame.size.width = editorWidth
        composer.frame.size.width = editorWidth
        if let container = composer.textContainer { composer.layoutManager?.ensureLayout(for: container) }
        let usedHeight = composer.layoutManager.flatMap { manager in
            composer.textContainer.map { manager.usedRect(for: $0).height }
        } ?? 0
        let editorHeight = min(questions.isHidden ? 164 : 80, max(44, ceil(usedHeight) + 12))
        let attachmentHeight: CGFloat = attachmentStrip.hasAttachments ? 76 : 0
        let editorTop: CGFloat = attachmentHeight > 0 ? 10 + attachmentHeight : 10
        let controlsTop = editorTop + editorHeight + 2
        layoutComposerControls(width: width, top: controlsTop)
        let cardHeight = controlsTop + Self.controlSize + 10
        let empty = isEmptyConversation
        let cardY = empty ? floor((bounds.height - cardHeight) / 2) + 40 : bounds.height - 12 - cardHeight
        composerCard.frame = NSRect(x: left, y: max(0, cardY), width: width, height: cardHeight)
        attachmentStrip.frame = NSRect(x: editorX, y: 8, width: editorWidth, height: attachmentHeight)
        attachmentStrip.isHidden = attachmentHeight == 0
        composerScroll.frame = NSRect(x: editorX, y: editorTop, width: editorWidth, height: editorHeight)
        composer.frame.size.height = max(editorHeight, ceil(usedHeight) + 12)
        emptyTitle.isHidden = !empty
        emptyDetail.isHidden = !empty
        if empty {
            let place = workspaceDescription?() ?? ""
            let detail = place.isEmpty ? "Ask a question or make something new." : "Ask a question or make something new in \(place)."
            if emptyDetail.stringValue != detail { emptyDetail.stringValue = detail }
            emptyDetail.toolTip = "Type / for commands, @ for files, or /resume to continue a past conversation."
        }
        emptyTitle.frame = NSRect(x: left, y: composerCard.frame.minY - 82, width: width, height: 28)
        emptyDetail.frame = NSRect(x: left, y: composerCard.frame.minY - 48, width: width, height: 20)

        // Glass cards stack above the composer, each the composer's width: a notice,
        // then questions, then the queue, then running agents, then the activity capsule.
        let gap: CGFloat = 8
        var top = composerCard.frame.minY
        let noticeText = feedback.stringValue
        notice.isHidden = noticeText.isEmpty && retry.isHidden && retryTurn.isHidden && newConversation.isHidden
        feedback.isHidden = notice.isHidden
        if !notice.isHidden {
            // One action at a time: Refresh for errors, else Retry for a failed turn.
            let action = !retry.isHidden ? retry : !retryTurn.isHidden ? retryTurn : newConversation
            let retryWidth = action.isHidden ? 0 : ceil(action.fittingSize.width)
            let dismissWidth: CGFloat = dismissNotice.isHidden ? 0 : 24
            let trailing = (retryWidth > 0 ? retryWidth + 8 : 0) + (dismissWidth > 0 ? dismissWidth + 4 : 0)
            let textWidth = max(1, width - 28 - trailing)
            let textHeight = min(32, ceil((noticeText as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: AppFont.small]).height))
            let height = max(36, textHeight + 18)
            top -= gap + height
            notice.frame = NSRect(x: left, y: top, width: width, height: height)
            feedback.frame = NSRect(x: 14, y: floor((height - textHeight) / 2), width: textWidth, height: textHeight)
            dismissNotice.frame = NSRect(x: width - 8 - dismissWidth, y: floor((height - 24) / 2), width: dismissWidth, height: 24)
            let retryRight = width - 8 - (dismissWidth > 0 ? dismissWidth + 4 : 0)
            action.frame = NSRect(x: retryRight - retryWidth, y: floor((height - 24) / 2), width: retryWidth, height: 24)
        }
        let activityHeight: CGFloat = activity.isHidden ? 0 : 26
        let panelBudget = max(0, top - activityHeight - 64)
        let questionHeight = questions.isHidden ? 0 : min(questions.preferredHeight(for: width), max(160, panelBudget))
        let panels: [(NSView, CGFloat)] = [
            (taskProgressButton, taskProgressButton.isHidden ? 0 : 28),
            (subagents, subagents.isHidden ? 0 : subagents.preferredHeight),
            (promptQueue, promptQueue.isHidden ? 0 : promptQueue.preferredHeight),
            (questions, questionHeight)
        ]
        var panelY: CGFloat = 0
        for (panel, height) in panels {
            guard height > 0 else { panel.frame = .zero; continue }
            if panelY > 0 { panelY += gap }
            panel.frame = NSRect(x: 0, y: panelY, width: width, height: height)
            panelY += height
        }
        let panelHeight = min(panelY, panelBudget)
        panelScroll.isHidden = panelHeight == 0
        if panelHeight > 0 { top -= gap + panelHeight }
        panelScroll.frame = NSRect(x: left, y: top, width: width, height: panelHeight)
        panelDocument.frame = NSRect(x: 0, y: 0, width: width, height: panelY)
        if activityHeight > 0 {
            let labelWidth = ceil((activityLabel.stringValue as NSString).size(withAttributes: [.font: AppFont.small]).width) + 4
            top -= gap + activityHeight
            activity.frame = NSRect(x: left, y: top, width: labelWidth + 24, height: activityHeight)
            activityLabel.frame = NSRect(x: 12, y: floor((activityHeight - 16) / 2), width: labelWidth, height: 16)
        }
        // The conversation runs under the floating cards and ends where the composer does;
        // its last row can scroll clear of the topmost card.
        let transcriptHeight = empty ? bounds.height : composerCard.frame.maxY
        transcriptScroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: transcriptHeight)
        transcript.bottomInset = empty ? 0 : max(0, transcriptHeight - top + 12)
        transcript.reflow(viewportWidth: transcriptScroll.contentSize.width)
        if followingEnd || lastViewportWidth == 0 { scrollToEnd() }
        else { restoreScrollAnchor(anchor) }
        // The find bar overlays the transcript's top edge, so opening it never moves the text.
        findBar?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: AgentConversationFindBar.height)
        endButton.frame = NSRect(x: floor((bounds.width - 126) / 2), y: max(0, top - 40), width: 126, height: 28)
        updateEndButton()
        let suggestionTop = max(0, composerCard.frame.minY + AgentComposerSuggestionsView.tuck - suggestions.preferredHeight)
        let suggestionWidth = floor(width * 0.9)
        suggestions.frame = NSRect(x: left + floor((width - suggestionWidth) / 2), y: suggestionTop,
                                   width: suggestionWidth, height: composerCard.frame.minY + AgentComposerSuggestionsView.tuck - suggestionTop)
        lastViewportWidth = bounds.width
        super.layout()
    }

    private static let controlSize: CGFloat = 32

    /// Nothing sent, queued or running yet: the composer sits centered under a greeting.
    private var isEmptyConversation: Bool {
        (snapshot?.items.isEmpty ?? true) && (snapshot?.queuedPrompts?.isEmpty ?? true) && !submitting && activityStatus == .idle
    }

    /// Send queues a draft while working; Stop remains beside it. Dictate appears while idle.
    func updatePrimaryAction() {
        let hasDraft = !composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachmentStrip.hasAttachments
        // While a submission is in flight its draft is still shown, but the slot offers Stop.
        let showSend = hasDraft && !dictating && !submitting
        let showStop = busy && !dictating
        send.isHidden = !showSend
        stop.isHidden = !showStop
        microphone.isHidden = showSend || showStop
    }

    /// Lays out the composer's single control row at `top`: attach and the plan chip on
    /// the left; usage, the model picker and the primary action on the right.
    private func layoutComposerControls(width: CGFloat, top: CGFloat) {
        let padding: CGFloat = 10, size = Self.controlSize, gap: CGFloat = 6
        let action = NSRect(x: width - padding - size, y: top, width: size, height: size)
        for button in [send, stop, microphone] { button.frame = action }
        var right = action.minX - gap
        if !send.isHidden && !stop.isHidden {
            right -= size
            stop.frame = NSRect(x: right, y: top, width: size, height: size)
            right -= gap
        }
        // Usage stays out of the way until the context window is half full.
        contextIndicator.isHidden = (contextIndicator.fractionUsed ?? 0) < 0.5
        if !contextIndicator.isHidden {
            right -= 28
            contextIndicator.frame = NSRect(x: right, y: top + 2, width: 28, height: 28)
            right -= 2
        }
        var x = padding
        attach.frame = NSRect(x: x, y: top, width: size, height: size)
        x += size + gap
        if !plan.isHidden {
            let planWidth = plan.intrinsicContentSize.width
            plan.frame = NSRect(x: x, y: top + 2, width: planWidth, height: 28)
            x += planWidth + gap
        }
        let pickerWidth = max(0, min(modelPicker.intrinsicContentSize.width, right - x))
        modelPicker.frame = NSRect(x: right - pickerWidth, y: top, width: pickerWidth, height: size)
    }

    /// Call after programmatic draft edits; user edits already call this through the text view.
    func refreshComposer() {
        composer.needsDisplay = true
        needsLayout = true
        modelPicker.refresh()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Anywhere in the pane takes a drop, not just the composer.
        guard sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil else { return [] }
        composerCard.highlighted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = draggingEntered(sender)
        if operation.isEmpty { draggingExited(sender) }
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        composerCard.highlighted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !draggingEntered(sender).isEmpty }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { draggingExited(sender) }
        guard !draggingEntered(sender).isEmpty else { return false }
        return AgentAttachmentPasteboard.receive(sender.draggingPasteboard, onFiles: composer.onAttachFiles,
                                                 onImage: composer.onAttachImage)
    }

    /// The controller owns enabled states and actions; the surface presents honest activity.
    /// The conversation retains its working indicator through tool work and assistant streaming.
    func setActivity(status: AgentChatStatus, submitting: Bool) {
        let changed = activityStatus != status || self.submitting != submitting
        activityStatus = status
        self.submitting = submitting
        let busy = submitting || status == .working || status == .waiting || snapshot?.hasActiveQueue == true
        self.busy = busy
        updatePrimaryAction()
        // Only a wait on the user earns a capsule; sending and working show in the
        // conversation and the stop button, so a send never flashes a card.
        activity.isHidden = status != .waiting
        activityLabel.stringValue = status != .waiting ? ""
            : snapshot?.items.contains { $0.questionnaire != nil && !$0.isComplete } == true ? "Waiting for your answers" : "Waiting for approval"
        activityLabel.setAccessibilityValue(activityLabel.stringValue)
        guard changed else { return }
        needsLayout = true
    }

    /// Binds assistant link enrichments to this conversation's actions.
    private func configureLinkServices() {
        let actions = actions
        transcript.linkServices = linkServices
        linkServices.pullRequests.fetch = { raw in
            guard let url = URL(string: raw) else { throw ModelError("This is not a pull-request link.") }
            return try await actions.pullRequestPreview(url)
        }
        linkServices.fileMetadata.fetch = { path in try await actions.filesystemMetadata([path]).first ?? nil }
        linkServices.mediaLoader = mediaLoader
        mediaLoader.workspaceMedia = { path in try await actions.workspaceMedia(path) }
        linkServices.previewMedia = { gallery, index in
            do { try actions.previewMarkdownMedia(gallery, index: index) }
            catch { Log.app.error("Previewing assistant media failed: \(error.message, privacy: .public)") }
        }
        linkServices.playMedia = { [weak self] media in
            Task { @MainActor in
                do { try await actions.playMarkdownMedia(media) }
                catch { self?.onActionError?(error.localizedDescription) }
            }
        }
        linkServices.openLink = { [weak self] destination in
            Task { @MainActor in
                do { try await actions.openLink(destination) }
                catch {
                    Log.app.error("Opening a conversation link failed: \(error.message, privacy: .public)")
                    self?.reportActionError(error)
                }
            }
        }
        linkServices.copyText = { text in try actions.copy(text: text) }
        linkServices.useTemplate = { [weak self] template in
            do {
                let draft = try actions.composerPrompt()
                try actions.useArtifactTemplate(String(template.appending(to: draft).dropFirst(draft.count)), expectedPrompt: draft)
            } catch {
                Log.app.error("Using an artifact template failed: \(error.message, privacy: .public)")
                self?.reportActionError(error)
            }
        }
        linkServices.openFile = { [weak self] target in
            do { try actions.openEditor(target.editorTarget) }
            catch {
                Log.app.error("Opening a file link failed: \(error.message, privacy: .public)")
                self?.reportActionError(error)
            }
        }
        linkServices.isLocalProject = { actions.isLocalProject }
        linkServices.performLinkAction = { [weak self] item, target in self?.performLinkAction(item, target: target) }
        transcript.onOpenThread = { [weak self] link in self?.openThread(link) }
        linkServices.onPullRequestHostsChanged = { [weak self] in
            guard let self else { return }
            self.transcript.linkServicesDidChange()
            self.preserveScroll { self.transcript.reflow(viewportWidth: self.transcriptScroll.contentSize.width) }
        }
    }

    /// `itemsUnchanged` says the items are those last rendered, as an incremental read
    /// that changed no item reports, so the transcript skips comparing them.
    func render(_ snapshot: AgentChatSnapshot, itemsUnchanged: Bool = false) {
        if self.snapshot?.session != snapshot.session { navigationPromptID = nil }
        self.snapshot = snapshot
        taskProgress.update(snapshot)
        if taskProgressButton.title != taskProgress.title {
            taskProgressButton.title = taskProgress.title
            taskProgressButton.setTitleColor(theme.fgDim)
            taskProgressButton.toolTip = taskProgress.title
            taskProgressButton.setAccessibilityLabel(taskProgress.title)
        }
        taskProgressButton.isHidden = taskProgress.target == nil
        updateOutline()
        preserveScroll {
            // Keep every retained entry as lightweight data. Native row views are
            // limited by the viewport, not by dropping older conversation items.
            let visible = snapshot.items
            let turns = snapshot.turns ?? []
            self.transcript.provider = snapshot.provider
            let omitted = snapshot.omittedItems ?? 0
            let activityChanged = self.transcript.providerActivity != snapshot.activity
            self.transcript.providerActivity = snapshot.activity
            if (!itemsUnchanged && visible != self.renderedItems) || turns != self.renderedTurns || omitted != self.renderedOmitted || activityChanged {
                self.transcript.update(visible, omittedCount: omitted, turns: turns)
                self.renderedItems = visible
                self.renderedTurns = turns
                self.renderedOmitted = omitted
            }
            self.setActivity(status: snapshot.status, submitting: self.submitting)
            self.layoutSubtreeIfNeeded()
            self.transcript.reflow(viewportWidth: self.transcriptScroll.contentSize.width)
        }
        if findModel != nil { findTranscriptDidChange() }
        refreshComposer()
    }

    /// Shows a failed conversation action in the composer's error label.
    func reportActionError(_ error: Error) {
        guard !(error is CancellationError) else { return }
        onActionError?(error.message)
    }

    /// Runs a link context-menu item; its failure is shown in the composer.
    func performLinkAction(_ item: AgentLinkMenu.Item, target: AgentLinkMenu.Target) {
        let actions = actions, root = workspaceRoot
        Task { @MainActor [weak self] in
            do { try await AgentLinkMenu.perform(item, target: target, root: root, actions: actions.linkMenuActions) }
            catch {
                Log.app.error("A link action failed: \(error.message, privacy: .public)")
                self?.reportActionError(error)
            }
        }
    }

    /// Opens the conversation a thread link names; its failure is shown in the composer.
    func openThread(_ link: AgentThreadLink) {
        let actions = actions
        Task { @MainActor [weak self] in
            do { try await actions.openThread(link.session, project: link.project) }
            catch {
                Log.app.error("Opening a linked conversation failed: \(error.message, privacy: .public)")
                self?.reportActionError(error)
            }
        }
    }

    /// Runs a button of an HTML document card through the typed conversation actions.
    func performHTMLDocument(_ action: AgentHtmlDocumentCard.Action, _ reference: AgentHtmlDocumentReference) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch action {
                case .preview: try await self.actions.previewHTMLDocument(attachmentID: reference.attachmentID, title: nil)
                case .download: try self.actions.downloadAttachment(itemID: reference.itemID, attachmentID: reference.attachmentID)
                case .copySource: try await self.actions.copyHTMLDocument(attachmentID: reference.attachmentID)
                }
            } catch is CancellationError {
            } catch { self.onActionError?(error.localizedDescription) }
        }
    }

    @objc private func activityPressed() { revealPendingRequest() }

    var composerHasFocus: Bool { window?.firstResponder === composer }

    /// Scrolls to the next failed tool below the top of the view, wrapping to the first.
    @discardableResult
    func revealNextFailure() -> Bool {
        let failures = (snapshot?.items ?? []).filter { $0.kind == .tool && $0.tool?.status == .failed }.map(\.id)
        guard !failures.isEmpty else { return false }
        let top = transcriptScroll.contentView.bounds.minY + 1
        let below = failures.first { id in
            guard let entry = transcript.entryID(showing: id), let frame = transcript.frameForEntry(entry) else { return false }
            return frame.minY > top
        }
        return reveal(.item(below ?? failures[0]))
    }

    /// Page Up and Page Down from the composer page the conversation, not the draft.
    func scrollTranscriptPage(up: Bool) {
        let clip = transcriptScroll.contentView
        let page = max(40, clip.bounds.height - 40)
        let maxY = max(0, transcript.bounds.height - clip.bounds.height)
        let y = min(maxY, max(0, clip.bounds.minY + (up ? -page : page)))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        transcriptScroll.reflectScrolledClipView(clip)
    }

    @objc private func textScaleDidChange() {
        transcript.themeDidChange()
        needsLayout = true
    }

    /// Scrolls to the approval or question the agent waits on.
    @discardableResult
    func revealPendingRequest() -> Bool {
        guard let pending = snapshot?.items.first(where: { $0.kind == .approval && !$0.isComplete }) else { return false }
        return reveal(.item(pending.id))
    }

    /// Scrolls to a retained item or turn, expanding its work group if needed.
    @discardableResult
    func reveal(_ target: AgentTranscriptTarget, offset: CGFloat = 0) -> Bool {
        guard let anchor = transcript.anchor(revealing: target, offset: offset) else { return false }
        scroll(to: anchor)
        return true
    }

    /// Scrolls the transcript to a row anchor, as deliberate navigation away from the end.
    func scroll(to anchor: AgentTranscriptAnchor) {
        followingEnd = false
        scrollMutationDepth += 1
        defer { scrollMutationDepth -= 1 }
        transcript.reflow(viewportWidth: transcriptScroll.contentSize.width)
        restoreScrollAnchor(anchor)
        updateEndButton()
    }

    /// Escape with the keyboard in the transcript (outside a text view, which asks the
    /// selection host itself) hides the selection toolbar, else closes the find bar.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, transcriptDidPressEscape() { return }
        super.keyDown(with: event)
    }

    var isAtBottom: Bool {
        return transcript.bounds.height - transcriptScroll.contentView.bounds.maxY <= 36
    }

    func scrollToEnd() {
        followingEnd = true
        scrollMutationDepth += 1
        defer { scrollMutationDepth -= 1 }
        settleViewport(at: max(0, transcript.bounds.height - transcriptScroll.contentSize.height))
        updateEndButton()
    }

    private func updateEndButton() {
        endButton.isHidden = followingEnd || isAtBottom || transcript.bounds.height <= transcriptScroll.contentSize.height
    }

    private func didScroll() {
        if scrollMutationDepth == 0 { navigationPromptID = nil }
        hideSelectionToolbar()
        guard scrollMutationDepth == 0, !transcript.isUpdatingViewport else { return }
        followingEnd = isAtBottom
        scrollMutationDepth += 1
        defer { scrollMutationDepth -= 1 }
        settleViewport(at: transcriptScroll.contentView.bounds.minY)
        updateEndButton()
    }

    private func captureScrollAnchor() -> AgentTranscriptAnchor {
        transcript.captureAnchor(at: transcriptScroll.contentView.bounds.minY)
    }

    private func restoreScrollAnchor(_ anchor: AgentTranscriptAnchor) {
        transcript.restoreAnchor(anchor, viewport: transcriptScroll.contentView.bounds, followingEnd: followingEnd)
        transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: transcript.viewportOrigin))
        transcriptScroll.reflectScrolledClipView(transcriptScroll.contentView)
    }

    private func settleViewport(at y: CGFloat) {
        var rect = transcriptScroll.contentView.bounds
        rect.origin.y = y
        transcript.updateViewport(rect, followingEnd: followingEnd)
        transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: transcript.viewportOrigin))
        transcriptScroll.reflectScrolledClipView(transcriptScroll.contentView)
    }

    private func preserveScroll(_ changes: () -> Void) {
        let anchor = captureScrollAnchor()
        scrollMutationDepth += 1
        defer { scrollMutationDepth -= 1 }
        changes()
        if followingEnd { scrollToEnd() }
        else { restoreScrollAnchor(anchor) }
        updateEndButton()
    }

    func setApprovalsEnabled(_ enabled: Bool) {
        transcript.setApprovalsEnabled(enabled)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = theme.paneBackground.cgColor
    }

    override func themeDidChange() {
        taskProgressButton.setTitleColor(theme.fgDim)
        appearance = theme.nsAppearance
        attach.chatTheme = theme
        modelPicker.chatTheme = theme
        microphone.chatTheme = theme
        retry.setTitleColor(theme.fg)
        retryTurn.setTitleColor(theme.fg)
        newConversation.setTitleColor(theme.fg)
        dismissNotice.chatTheme = theme
        notice.theme = theme
        activity.theme = theme
        promptQueue.theme = theme
        subagents.theme = theme
        questions.theme = theme
        attachmentStrip.updateTheme(theme)
        suggestions.update(suggestions.items, theme: theme)
        needsDisplay = true
        composerCard.theme = theme
        composer.textColor = theme.fg
        composer.insertionPointColor = theme.accent
        composer.placeholderColor = theme.fgDim
        plan.chatTheme = theme
        composer.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.25)]
        activityLabel.textColor = theme.fgMuted
        emptyTitle.textColor = theme.fg
        emptyDetail.textColor = theme.fgDim
        feedback.textColor = theme.fgMuted
        for control in [model, effort] { control.chatTheme = theme }
        contextIndicator.chatTheme = theme
        send.chatTheme = theme
        stop.chatTheme = theme
        endButton.chatTheme = theme
        transcript.theme = theme
        findBar?.theme = theme
        if findModel != nil { findHighlighter.setTheme(theme); paintFindMatches() }
        selectionToolbar.theme = theme
        selectionToolbar.themeDidChange()
        composer.needsDisplay = true
    }
}

@MainActor
private final class AgentPanelDocument: NSView {
    override var isFlipped: Bool { true }
}
