import AppKit
import TabProtocol

/// A quiet, readable conversation above a bottom-anchored native composer.
@MainActor
final class AgentPaneView: ThemedView {
    let model = AgentTextPopUp(label: "Model")
    let effort = AgentReasoningPopUp(label: "Reasoning effort")
    let access = AgentTextPopUp(label: "Access mode")
    let composer = AgentComposerTextView()
    var citationEnvironmentId: String?
    var citationThreadId: String?
    let send = AgentRoundButton(kind: .send)
    let stop = AgentRoundButton(kind: .stop)
    let contextIndicator = AgentContextIndicator(frame: .zero)
    private let pickerSeparators = [NSView(), NSView()]
    let attach = PillButton("", style: .plain)
    let attachmentStrip = AgentAttachmentStrip(frame: .zero)
    let suggestions = AgentComposerSuggestionsView(frame: .zero)
    let retry = PillButton("Retry", style: .plain)
    let feedback = NSTextField(wrappingLabelWithString: "")
    let transcriptScroll = NSScrollView()
    let composerScroll = NSScrollView()
    private let transcript = AgentTranscriptDocument()
    let conversationWebView = AgentConversationWebView()
    private(set) var usesWebConversation = false
    private var awaitingConversationRender = true
    private(set) var conversationRendererFailure: String?
    private var conversationSnapshot: AgentChatSnapshot?
    var conversationIdentity: (session: SessionId, project: ProjectId)? {
        conversationSnapshot.map { ($0.session, $0.project) }
    }
    private var nativeThemeDirty = false
    private var sourceConversationAnchor: AgentConversationAnchor?
    private let conversationClipboard = AgentConversationClipboardTransfer()
    var onConversationProjectRefresh: (() -> Void)?
    var onConversationAction: ((String, [String: Any]) async throws -> Any?)?
    var conversationCapabilities: [String: Bool] = [:] { didSet { updateConversationCapabilities() } }
    var conversationProject: [String: Any]? { didSet { conversationWebView.project = conversationProject } }
    var conversationRemote = false { didSet { conversationWebView.remote = conversationRemote } }


    private let composerCard = ThemedBackground(color: { $0.floating })
    private let activity = NSView()
    private let activityLabel = makeLabel("", font: AppFont.small)
    private let activitySpinner = NSProgressIndicator()
    private var activityStatus: AgentChatStatus = .idle
    private var submitting = false
    private var renderedItems: [AgentChatItem] = []
    private var renderedTurns: [AgentChatTurn] = []
    private var lastViewportWidth: CGFloat = 0
    private var followingEnd = true
    private var scrollMutationDepth = 0
    private var boundsObserver: NSObjectProtocol?
    private let endButton = AgentEndButton()
    var onApproval: ((String, Bool) -> Void)?
    var onConversationApproval: ((String, Bool) async throws -> Void)?
    var onConversationModalChange: (() -> Void)?
    var onConversationActionFailure: ((Error) -> Void)?
    var isConversationModal: Bool { usesWebConversation && conversationWebView.isModal }
    private weak var responderBeforeModal: NSResponder?
    var onRunShellCommand: ((String) -> Void)? { didSet { transcript.onRunShellCommand = onRunShellCommand } }
    var onOpenAttachment: ((String, AgentChatAttachmentDescriptor, Bool) -> Void)? { didSet { transcript.onOpenAttachment = onOpenAttachment } }
    var fetchAttachment: AgentAttachmentCache.Fetch? { didSet {
        transcript.fetchAttachment = fetchAttachment
        conversationWebView.fetchAttachment = fetchAttachment
    } }
    var onPreviewAttachments: ((String, [AgentChatAttachmentDescriptor], Int) -> Void)? { didSet { transcript.onPreviewAttachments = onPreviewAttachments } }
    var onOpenFile: ((String, Int?) -> Void)?
    var workspaceRoot: String? { didSet { transcript.workspaceRoot = workspaceRoot } }
    var onOpenToolDiff: ((String, AgentToolActivity) -> Void)?
    var onOpenCheckpoint: ((String, String?) -> Void)?
    static let readableWidth: CGFloat = 800

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        conversationWebView.isHidden = true
        awaitingConversationRender = AgentConversationWebView.isAvailable
        transcriptScroll.isHidden = awaitingConversationRender
        conversationWebView.onReady = { [weak self] in self?.needsLayout = true }
        conversationWebView.onRendered = { [weak self] in
            guard let self, self.conversationWebView.supportsFullTimeline else { return }
            self.awaitingConversationRender = false
            self.usesWebConversation = true
            self.conversationRendererFailure = nil
            self.transcriptScroll.isHidden = true
            self.conversationWebView.isHidden = false
            self.endButton.isHidden = true
            self.activity.isHidden = true
            self.needsLayout = true
        }
        conversationWebView.onWillReload = { [weak self] in
            guard let self else { return }
            self.awaitingConversationRender = true
            self.usesWebConversation = false
            self.conversationClipboard.cancel()
            self.conversationWebView.isHidden = true
            self.transcriptScroll.isHidden = true
            self.needsLayout = true
        }
        conversationWebView.onFailure = { [weak self] message in
            guard let self else { return }
            self.conversationRendererFailure = message
            self.awaitingConversationRender = false
            self.usesWebConversation = false
            self.conversationWebView.isHidden = true
            self.transcriptScroll.isHidden = false
            self.conversationClipboard.cancel()
            self.materializeNativeTranscript()
            self.restoreSourceConversationAnchor()
            self.needsLayout = true
        }
        conversationWebView.onCite = { [weak self] in self?.insertCitation($0) == true }
        conversationWebView.onScrollState = { [weak self] in self?.followingEnd = $0 }
        conversationWebView.onAnchor = { [weak self] in self?.sourceConversationAnchor = $0 }
        conversationWebView.onActionFailure = { [weak self] in self?.onConversationActionFailure?($0) }
        conversationWebView.onModalChange = { [weak self] modal in
            guard let self else { return }
            if modal {
                if let responder = self.window?.firstResponder,
                   responder === self.composer || (responder as? NSView)?.isDescendant(of: self.composerCard) == true {
                    self.responderBeforeModal = responder
                }
                self.window?.makeFirstResponder(self.conversationWebView.webView)
            }
            self.onConversationModalChange?()
            if !modal, let responder = self.responderBeforeModal {
                self.responderBeforeModal = nil
                if let current = self.window?.firstResponder as? NSView,
                   current === self.conversationWebView.webView || current.isDescendant(of: self.conversationWebView.webView),
                   self.composer.isEditable { self.window?.makeFirstResponder(responder) }
            }
        }
        conversationWebView.onAction = { [weak self] kind, payload in
            guard let self else { throw ModelError("The conversation was closed.") }
            return try await self.handleConversationAction(kind, payload)
        }
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
        composer.font = AppFont.system(14)
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
        composer.setAccessibilityHelp("Ask anything. Return sends; Shift-Return adds a new line.")
        composer.onEdit = { [weak self] in self?.refreshComposer() }
        composerScroll.documentView = composer
        composerScroll.drawsBackground = false
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.scrollerStyle = .overlay
        composerCard.cornerRadius = 18
        composerCard.layer?.borderWidth = Metrics.border
        attach.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attach files")
        attach.imagePosition = .imageOnly
        attach.setAccessibilityLabel("Attach files")
        attach.toolTip = "Attach files or drop them into the message box"
        for separator in pickerSeparators { separator.wantsLayer = true; composerCard.addSubview(separator) }
        for child in [composerScroll, attachmentStrip, attach, model, effort, access, contextIndicator, send, stop] {
            composerCard.addSubview(child)
            // This surface uses measured frames: controls must not bring their own size constraints.
            child.translatesAutoresizingMaskIntoConstraints = true
        }
        stop.isHidden = true
        model.toolTip = "Choose the provider and model for the next message"
        effort.toolTip = "Choose the reasoning effort for the next message"
        access.toolTip = "Choose which actions require approval"
        activitySpinner.style = .spinning
        activitySpinner.controlSize = .small
        activitySpinner.isDisplayedWhenStopped = false
        activityLabel.setAccessibilityLabel("Agent activity")
        activity.addSubview(activitySpinner)
        activity.addSubview(activityLabel)
        activity.isHidden = true
        feedback.font = AppFont.footnote
        feedback.maximumNumberOfLines = 2
        feedback.lineBreakMode = .byTruncatingTail
        for child in [transcriptScroll, activity, composerCard, feedback, retry, endButton] { addSubview(child) }
        addSubview(conversationWebView)
        addSubview(suggestions)
        suggestions.isHidden = true
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
        let anchor = captureScrollAnchor()
        scrollMutationDepth += 1
        defer { scrollMutationDepth -= 1 }
        let width = max(0, min(Self.readableWidth, bounds.width - 32))
        let left = floor((bounds.width - width) / 2)
        let retryWidth = retry.isHidden ? 0 : min(56, retry.fittingSize.width)
        let feedbackWidth = max(1, width - retryWidth - (retryWidth > 0 ? 8 : 0))
        let footerTextHeight = (feedback.stringValue as NSString).boundingRect(
            with: NSSize(width: feedbackWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: AppFont.footnote]).height
        let footerHeight = feedback.stringValue.isEmpty && retry.isHidden ? 0 : max(retry.isHidden ? 14 : 24, min(30, ceil(footerTextHeight)))
        feedback.isHidden = footerHeight == 0
        let footerTop = max(0, bounds.height - 10 - footerHeight)
        feedback.frame = NSRect(x: left + 4, y: footerTop, width: max(0, feedbackWidth - 4), height: footerHeight)
        retry.frame = NSRect(x: left + width - retryWidth, y: footerTop, width: retryWidth, height: footerHeight)

        let editorWidth = max(1, width - 28)
        composerScroll.frame.size.width = editorWidth
        composer.frame.size.width = editorWidth
        if let container = composer.textContainer { composer.layoutManager?.ensureLayout(for: container) }
        let usedHeight = composer.layoutManager.flatMap { manager in
            composer.textContainer.map { manager.usedRect(for: $0).height }
        } ?? 0
        let editorHeight = min(164, max(56, ceil(usedHeight) + 12))
        // Pack intrinsic widths; wrap only when the next whole picker will not fit.
        // The trailing usage/send buttons have reserved space on the first row.
        var pickerFrames: [NSRect] = []
        var separatorFrames: [NSRect?] = []
        var x: CGFloat = 46
        var row: CGFloat = 0
        let fitsSingleRow = 46 + [model, effort, access].reduce(CGFloat(26)) { $0 + $1.intrinsicContentSize.width } <= width - 82
        for (index, picker) in [model, effort, access].enumerated() {
            var right = row == 0 ? width - 82 : width - 14
            let desired = picker.intrinsicContentSize.width
            let gap: CGFloat = index == 0 ? 0 : 13
            var wraps = false
            if index > 0 && ((index == 1 && !fitsSingleRow) || x + gap + desired > right) {
                row += 1
                x = 14
                right = width - 14
                wraps = true
            }
            if index > 0 {
                separatorFrames.append(wraps ? nil : NSRect(x: x + 6, y: row * 32 + 8, width: 1, height: 12))
                if !wraps { x += gap }
            }
            let measuredWidth = min(desired, max(0, right - x))
            pickerFrames.append(NSRect(x: x, y: row * 32, width: measuredWidth, height: 28))
            x += measuredWidth
        }
        let controlsHeight: CGFloat = 40 + row * 32
        let attachmentHeight: CGFloat = attachmentStrip.hasAttachments ? 76 : 0
        let cardHeight = attachmentHeight + editorHeight + 14 + controlsHeight
        composerCard.frame = NSRect(x: left, y: max(0, footerTop - 8 - cardHeight), width: width, height: cardHeight)
        attachmentStrip.frame = NSRect(x: 14, y: 8, width: editorWidth, height: attachmentHeight)
        attachmentStrip.isHidden = attachmentHeight == 0
        composerScroll.frame = NSRect(x: 14, y: 10 + attachmentHeight, width: editorWidth, height: editorHeight)
        composer.frame.size.height = max(editorHeight, ceil(usedHeight) + 12)
        let controlsY = attachmentHeight + editorHeight + 16
        attach.frame = NSRect(x: 12, y: controlsY + 1, width: 28, height: 28)
        let actionFrame = NSRect(x: max(0, width - 44), y: controlsY, width: 30, height: 30)
        send.frame = actionFrame
        stop.frame = actionFrame
        contextIndicator.frame = NSRect(x: max(0, width - 78), y: controlsY + 1, width: 28, height: 28)
        for (picker, frame) in zip([model, effort, access], pickerFrames) {
            picker.frame = frame.offsetBy(dx: 0, dy: controlsY + 1)
        }
        for (separator, frame) in zip(pickerSeparators, separatorFrames) {
            separator.isHidden = frame == nil
            if let frame { separator.frame = frame.offsetBy(dx: 0, dy: controlsY + 1) }
        }

        let activityHeight: CGFloat = activity.isHidden ? 0 : 30
        let transcriptBottom = max(0, composerCard.frame.minY - 12 - activityHeight)
        activity.frame = NSRect(x: left + 4, y: transcriptBottom, width: max(0, width - 8), height: activityHeight)
        activitySpinner.frame = NSRect(x: 0, y: 5, width: 16, height: 16)
        activityLabel.frame = NSRect(x: activityStatus == .waiting ? 0 : 24, y: 4,
                                     width: max(0, activity.bounds.width - 24), height: 20)
        transcriptScroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: transcriptBottom)
        let fullPane = conversationWebView.supportsFullPaneComposition
        conversationWebView.frame = fullPane ? bounds : transcriptScroll.frame
        conversationWebView.setViewport(composer: fullPane
            ? NSRect(x: 0, y: transcriptBottom, width: bounds.width, height: max(0, bounds.height - transcriptBottom)) : nil)
        if !usesWebConversation && !awaitingConversationRender {
            transcript.reflow(viewportWidth: transcriptScroll.contentSize.width)
            if followingEnd || lastViewportWidth == 0 { scrollToEnd() }
            else { restoreScrollAnchor(anchor) }
        }
        endButton.frame = NSRect(x: floor((bounds.width - 126) / 2), y: max(0, transcriptBottom - 36), width: 126, height: 28)
        updateEndButton()
        let suggestionHeight = min(suggestions.preferredHeight, max(0, composerCard.frame.minY - 12))
        suggestions.frame = NSRect(x: left, y: max(0, composerCard.frame.minY - suggestionHeight - 6),
                                   width: width, height: suggestionHeight)
        lastViewportWidth = bounds.width
        super.layout()
    }

    /// Call after programmatic draft edits; user edits already call this through the text view.
    func refreshComposer() {
        composer.needsDisplay = true
        needsLayout = true
        model.needsDisplay = true
        effort.needsDisplay = true
        access.needsDisplay = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        guard composerCard.frame.contains(point), sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil else { return [] }
        composerCard.layer?.borderColor = theme.accent.cgColor
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = draggingEntered(sender)
        if operation.isEmpty { draggingExited(sender) }
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        composerCard.layer?.borderColor = theme.fg.withAlphaComponent(0.10).cgColor
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
        let busy = submitting || status == .working || status == .waiting
        send.isHidden = busy
        stop.isHidden = !busy
        activity.isHidden = awaitingConversationRender || usesWebConversation || (!submitting && status != .waiting)
        guard changed else { return }
        let text = submitting ? "Sending…" : status == .waiting ? "Waiting for approval" : "Working…"
        activityLabel.stringValue = busy ? text : ""
        activityLabel.setAccessibilityValue(activityLabel.stringValue)
        activitySpinner.isHidden = !busy || status == .waiting
        if busy && status != .waiting { activitySpinner.startAnimation(nil) }
        else { activitySpinner.stopAnimation(nil) }
        needsLayout = true
    }

    func render(_ snapshot: AgentChatSnapshot) {
        conversationSnapshot = snapshot
        updateConversationCapabilities()
        conversationWebView.update(snapshot, theme: theme, cwd: workspaceRoot)
        if usesWebConversation || awaitingConversationRender {
            setActivity(status: snapshot.status, submitting: submitting)
            refreshComposer()
            return
        }
        materializeNativeTranscript()
        refreshComposer()
    }

    private func materializeNativeTranscript() {
        guard let snapshot = conversationSnapshot else { return }
        if nativeThemeDirty { transcript.theme = theme; nativeThemeDirty = false }
        preserveScroll {
            // Keep every retained entry as lightweight data. Native row views are
            // limited by the viewport, not by dropping older conversation items.
            let visible = snapshot.items.filter { $0.kind != .approval || !$0.isComplete }
            let turns = snapshot.turns ?? []
            if visible != self.renderedItems || turns != self.renderedTurns {
                self.transcript.update(visible, omittedCount: 0, turns: turns)
                self.renderedItems = visible
                self.renderedTurns = turns
            }
            self.setActivity(status: snapshot.status, submitting: self.submitting)
            self.layoutSubtreeIfNeeded()
            self.transcript.reflow(viewportWidth: self.transcriptScroll.contentSize.width)
        }
    }

    private func restoreSourceConversationAnchor() {
        guard !followingEnd, let sourceConversationAnchor,
              let anchor = transcript.resolveConversationAnchor(sourceConversationAnchor) else { return }
        scrollMutationDepth += 1
        defer { scrollMutationDepth -= 1 }
        transcript.reflow(viewportWidth: transcriptScroll.contentSize.width)
        restoreScrollAnchor(anchor)
        updateEndButton()
    }

    var isAtBottom: Bool {
        if usesWebConversation { return conversationWebView.isAtBottom }
        return transcript.bounds.height - transcriptScroll.contentView.bounds.maxY <= 36
    }

    func scrollToEnd() {
        if usesWebConversation { conversationWebView.scrollToEnd(); return }
        followingEnd = true
        scrollMutationDepth += 1
        defer { scrollMutationDepth -= 1 }
        settleViewport(at: max(0, transcript.bounds.height - transcriptScroll.contentSize.height))
        updateEndButton()
    }

    private func updateEndButton() {
        endButton.isHidden = awaitingConversationRender || usesWebConversation || followingEnd || isAtBottom || transcript.bounds.height <= transcriptScroll.contentSize.height
    }

    private func didScroll() {
        guard !usesWebConversation, scrollMutationDepth == 0, !transcript.isUpdatingViewport else { return }
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
        conversationWebView.setApprovalsEnabled(enabled)
    }
    func disposeConversation() {
        awaitingConversationRender = false
        usesWebConversation = false
        transcriptScroll.isHidden = false
        conversationClipboard.cancel()
        conversationWebView.dispose()
    }

    private func updateConversationCapabilities() {
        let native: [String: Bool] = [
            "cite": citationEnvironmentId != nil && citationThreadId != nil,
            "runShellCommand": onRunShellCommand != nil && workspaceRoot != nil,
            "openToolDiff": onOpenToolDiff != nil,
            "openTurnDiff": onOpenCheckpoint != nil,
            "openAttachment": onOpenAttachment != nil,
            "downloadAttachment": onOpenAttachment != nil,
        ]
        conversationWebView.capabilities = native.merging(conversationCapabilities) { _, override in override }
    }

    func handleConversationAction(_ kind: String, _ payload: [String: Any]) async throws -> Any? {
        func field(_ name: String) throws -> String {
            guard let value = payload[name] as? String, !value.isEmpty else { throw ModelError("Missing conversation action field: " + name) }
            return value
        }
        func item(_ id: String) throws -> AgentChatItem {
            guard let item = conversationSnapshot?.items.first(where: { $0.id == id }) else { throw ModelError("This message is no longer retained.") }
            return item
        }
        switch kind {
        case "copy":
            return try conversationClipboard.handle(payload)
        case "openLink":
            if payload["mode"] as? String == "preview", let action = onConversationAction {
                return try await action(kind, payload)
            }
            let raw = (payload["url"] ?? payload["href"]) as? String ?? ""
            if let citation = AgentAssistantCitation.parse(raw) {
                guard let action = onConversationAction else { throw ModelError("Citation navigation is unavailable.") }
                return try await action("navigateCitation", ["kind": "navigateCitation", "citation": try JSONSerialization.jsonObject(with: JSONEncoder().encode(citation))])
            }
            guard let link = AgentResponseLink.parse(raw) else { throw ModelError("This link cannot be opened.") }
            switch link {
            case .external(let url): guard NSWorkspace.shared.open(url) else { throw ModelError("No application could open this link.") }
            case .file(let path, let line):
                guard let open = onOpenFile else { throw ModelError("The project editor is unavailable.") }; open(path, line)
            case .fragment: throw ModelError("Document anchors are handled by the conversation renderer.")
            }
            return true
        case "openFile":
            if payload["mode"] as? String == "preview", let action = onConversationAction {
                return try await action(kind, payload)
            }
            guard let open = onOpenFile else { throw ModelError("The project editor is unavailable.") }
            open(try field("path"), payload["line"] as? Int); return true
        case "runShellCommand":
            guard let run = onRunShellCommand else { throw ModelError("A project terminal is unavailable.") }
            run(try field("command")); return true
        case "approve":
            let id = try field("requestId")
            if let decision = payload["decision"] as? String, decision != "accept" && decision != "decline" {
                throw ModelError("This provider supports one-time approval or denial only.")
            }
            guard let pending = conversationSnapshot?.items.first(where: { $0.kind == .approval && !$0.isComplete && ($0.id == id || $0.id == "approval:" + id) }) else { throw ModelError("This approval is no longer pending.") }
            guard let approve = onConversationApproval else { throw ModelError("Approval controls are unavailable.") }
            try await approve(pending.id, payload["allow"] as? Bool ?? false); return true
        case "openToolDiff":
            let target = payload["target"] as? [String: Any] ?? payload
            guard let id = target["itemId"] as? String else { throw ModelError("Missing recorded tool identity.") }
            guard let activity = try item(id).tool, let open = onOpenToolDiff else { throw ModelError("The recorded tool diff is unavailable.") }
            open(id, activity); return true
        case "openTurnDiff":
            let runID = try field("runId")
            let userID = runID.hasPrefix("native-turn:") ? String(runID.dropFirst("native-turn:".count)) : runID
            guard let checkpoint = conversationSnapshot?.turns?.first(where: { $0.userItemID == userID })?.checkpoint,
                  let open = onOpenCheckpoint else { throw ModelError("The recorded turn diff is unavailable.") }
            open(checkpoint.id, payload["filePath"] as? String); return true
        case "loadAttachment", "openAttachment", "downloadAttachment":
            let requested = payload["attachment"] as? [String: Any] ?? payload
            let sourceID = (requested["attachmentId"] ?? requested["id"]) as? String ?? ""
            guard let snapshot = conversationSnapshot,
                  let owner = AgentConversationWebView.ownedAttachment(sourceID, itemID: payload["itemId"] as? String, snapshot: snapshot) else {
                throw ModelError("This attachment does not belong to a retained message.")
            }
            let id = owner.item.id, descriptor = owner.attachment
            if kind == "loadAttachment" { return ["url": AgentConversationWebView.attachmentURL(item: id, attachment: descriptor.id)?.absoluteString ?? "", "mimeType": descriptor.mimeType] }
            guard let open = onOpenAttachment else { throw ModelError("The attachment viewer is unavailable.") }
            open(id, descriptor, kind == "downloadAttachment"); return true
        case "previewImages":
            let id = try field("itemId")
            let images = (try item(id).attachments ?? []).filter { $0.mimeType.hasPrefix("image/") }
            let index = payload["index"] as? Int ?? 0
            guard images.indices.contains(index), let preview = onPreviewAttachments else { throw ModelError("The image preview is unavailable.") }
            preview(id, images, index); return true
        case "createAssetUrl":
            let input = payload["input"] as? [String: Any] ?? payload
            let resource = input["resource"] as? [String: Any] ?? [:]
            if resource["renderIntent"] as? String == "mcp-app" {
                guard resource["_tag"] as? String == "attachment", let id = resource["attachmentId"] as? String,
                      let snapshot = conversationSnapshot,
                      let match = AgentConversationMcpAsset.match(attachmentID: id, items: snapshot.items) else {
                    throw ModelError("This MCP app has no matching retained HTML resource.")
                }
                let url = try await conversationWebView.prepareMcpAsset(match)
                return ["relativeUrl": url.absoluteString, "expiresAt": Date.distantFuture.timeIntervalSince1970 * 1000]
            }
            var ownerID: String?, descriptor: AgentChatAttachmentDescriptor?
            if resource["_tag"] as? String == "attachment", let id = resource["attachmentId"] as? String {
                if let url = try await conversationWebView.prepareHtmlRenderAsset(attachmentID: id) {
                    return ["relativeUrl": url.absoluteString, "expiresAt": Date.distantFuture.timeIntervalSince1970 * 1000]
                }
                if let snapshot = conversationSnapshot,
                   let owner = AgentConversationWebView.ownedAttachment(id, snapshot: snapshot) {
                    ownerID = owner.item.id; descriptor = owner.attachment
                }
            } else if resource["_tag"] as? String == "tool-output-image", let id = resource["itemId"] as? String,
                      resource["threadId"] as? String == conversationSnapshot?.session.description {
                let images = (try item(id).attachments ?? []).filter { $0.mimeType.hasPrefix("image/") }
                let index = resource["index"] as? Int ?? -1
                if images.indices.contains(index) { ownerID = id; descriptor = images[index] }
            }
            if let ownerID, let descriptor, let url = AgentConversationWebView.attachmentURL(item: ownerID, attachment: descriptor.id) {
                return ["relativeUrl": url.absoluteString, "expiresAt": Date.distantFuture.timeIntervalSince1970 * 1000]
            }
            guard let action = onConversationAction else { throw ModelError("This conversation asset is unavailable.") }
            return try await action(kind, payload)
        case "cite":
            guard let value = payload["citation"], JSONSerialization.isValidJSONObject(value) else { throw ModelError("Invalid assistant citation.") }
            let citation = try JSONDecoder().decode(AgentAssistantCitation.self, from: JSONSerialization.data(withJSONObject: value))
            return insertCitation(citation)
        case "reportFailure":
            throw ModelError(payload["message"] as? String ?? "A conversation action failed.")
        default:
            guard let action = onConversationAction else { throw ModelError("This conversation action is unavailable: " + kind) }
            return try await action(kind, payload)
        }
    }


    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = theme.card.cgColor
    }

    override func themeDidChange() {
        attachmentStrip.updateTheme(theme)
        suggestions.update(suggestions.items, theme: theme)
        needsDisplay = true
        composerCard.theme = theme
        composerCard.layer?.borderColor = theme.fg.withAlphaComponent(0.10).cgColor
        composer.textColor = theme.fg
        composer.insertionPointColor = theme.accent
        composer.placeholderColor = theme.fgDim
        composer.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.25)]
        activityLabel.textColor = theme.fgMuted
        feedback.textColor = theme.fgDim
        for control in [model, effort, access] { control.chatTheme = theme }
        for separator in pickerSeparators { separator.layer?.backgroundColor = theme.fg.withAlphaComponent(0.18).cgColor }
        contextIndicator.chatTheme = theme
        send.chatTheme = theme
        stop.chatTheme = theme
        endButton.chatTheme = theme
        if usesWebConversation { nativeThemeDirty = true }
        else { transcript.theme = theme; nativeThemeDirty = false }
        conversationWebView.updateTheme(theme)
        composer.needsDisplay = true
    }
}
