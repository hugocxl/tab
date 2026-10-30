import AppKit
import TabProtocol

/// A quiet, readable conversation above a bottom-anchored native composer.
@MainActor
final class AgentPaneView: ThemedView {
    let model = AgentTextPopUp(label: "Model")
    let effort = AgentTextPopUp(label: "Reasoning effort")
    let access = AgentTextPopUp(label: "Access mode")
    let composer = AgentComposerTextView()
    let send = AgentRoundButton(kind: .send)
    let stop = AgentRoundButton(kind: .stop)
    let retry = PillButton("Retry", style: .plain)
    let feedback = NSTextField(wrappingLabelWithString: "")
    let transcriptScroll = NSScrollView()
    let composerScroll = NSScrollView()
    private let transcript = AgentTranscriptDocument()
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
    var onOpenFile: ((String, Int?) -> Void)?
    static let readableWidth: CGFloat = 800

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        for child in [composerScroll, model, effort, access, send, stop] {
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
        let footerHeight = max(retry.isHidden ? 14 : 24, min(30, ceil(footerTextHeight)))
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
        let twoRows = width < 560
        let controlsHeight: CGFloat = twoRows ? 72 : 40
        let cardHeight = editorHeight + 14 + controlsHeight
        composerCard.frame = NSRect(x: left, y: max(0, footerTop - 8 - cardHeight), width: width, height: cardHeight)
        composerScroll.frame = NSRect(x: 14, y: 10, width: editorWidth, height: editorHeight)
        composer.frame.size.height = max(editorHeight, ceil(usedHeight) + 12)
        let controlsY = editorHeight + 16
        let actionFrame = NSRect(x: max(0, width - 44), y: controlsY, width: 30, height: 30)
        send.frame = actionFrame
        stop.frame = actionFrame

        if twoRows {
            model.frame = NSRect(x: 14, y: controlsY + 2, width: max(0, width - 72), height: 26)
            let available = max(0, width - 36)
            let effortWidth = min(140, available * 0.5)
            effort.frame = NSRect(x: 14, y: controlsY + 34, width: effortWidth, height: 26)
            access.frame = NSRect(x: effort.frame.maxX + 8, y: controlsY + 34,
                                  width: max(0, available - effortWidth), height: 26)
        } else {
            let effortWidth = min(120, max(80, effort.intrinsicContentSize.width))
            let accessWidth = min(180, max(104, access.intrinsicContentSize.width))
            let modelWidth = min(240, max(0, width - 82 - effortWidth - accessWidth))
            model.frame = NSRect(x: 14, y: controlsY + 2, width: modelWidth, height: 26)
            effort.frame = NSRect(x: model.frame.maxX + 8, y: controlsY + 2, width: effortWidth, height: 26)
            access.frame = NSRect(x: effort.frame.maxX + 8, y: controlsY + 2, width: accessWidth, height: 26)
        }

        let activityHeight: CGFloat = activity.isHidden ? 0 : 30
        let transcriptBottom = max(0, composerCard.frame.minY - 12 - activityHeight)
        activity.frame = NSRect(x: left + 4, y: transcriptBottom, width: max(0, width - 8), height: activityHeight)
        activitySpinner.frame = NSRect(x: 0, y: 5, width: 16, height: 16)
        activityLabel.frame = NSRect(x: activityStatus == .waiting ? 0 : 24, y: 4,
                                     width: max(0, activity.bounds.width - 24), height: 20)
        transcriptScroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: transcriptBottom)
        transcript.reflow(viewportWidth: transcriptScroll.contentSize.width)
        if followingEnd || lastViewportWidth == 0 { scrollToEnd() }
        else { restoreScrollAnchor(anchor) }
        endButton.frame = NSRect(x: floor((bounds.width - 126) / 2), y: max(0, transcriptBottom - 36), width: 126, height: 28)
        updateEndButton()
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

    /// The controller owns enabled states and actions; the surface presents honest activity.
    /// T3 retains its working indicator through tool work and assistant streaming.
    func setActivity(status: AgentChatStatus, submitting: Bool) {
        let changed = activityStatus != status || self.submitting != submitting
        activityStatus = status
        self.submitting = submitting
        let busy = submitting || status == .working || status == .waiting
        send.isHidden = busy
        stop.isHidden = !busy
        guard changed else { return }
        activity.isHidden = !busy
        let text = submitting ? "Sending…" : status == .waiting ? "Waiting for approval" : "Working…"
        activityLabel.stringValue = busy ? text : ""
        activityLabel.setAccessibilityValue(activityLabel.stringValue)
        activitySpinner.isHidden = !busy || status == .waiting
        if busy && status != .waiting { activitySpinner.startAnimation(nil) }
        else { activitySpinner.stopAnimation(nil) }
        needsLayout = true
    }

    func render(_ snapshot: AgentChatSnapshot) {
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
        refreshComposer()
    }

    var isAtBottom: Bool {
        transcript.bounds.height - transcriptScroll.contentView.bounds.maxY <= 36
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

    func setApprovalsEnabled(_ enabled: Bool) { transcript.setApprovalsEnabled(enabled) }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = theme.card.cgColor
    }

    override func themeDidChange() {
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
        send.chatTheme = theme
        stop.chatTheme = theme
        endButton.chatTheme = theme
        transcript.theme = theme
        composer.needsDisplay = true
    }
}
