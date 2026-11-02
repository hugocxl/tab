import AppKit
import TabProtocol

@MainActor
class AgentTimelineRow: ThemedView {
    var onOpenAttachment: ((String, AgentChatAttachmentDescriptor, Bool) -> Void)?
    var fetchAttachment: AgentAttachmentCache.Fetch?
    var onHTMLDocument: ((AgentHtmlDocumentCard.Action, AgentHtmlDocumentReference) -> Void)?
    var onPreviewAttachments: ((String, [AgentChatAttachmentDescriptor], Int) -> Void)?
    var onDisclosure: (() -> Void)?
    var onApproval: ((String, Bool) -> Void)?
    var onRunShellCommand: ((String) -> Void)? { didSet { runCommandHandlerDidChange() } }
    func runCommandHandlerDidChange() {}
    var onOpenFile: ((String, Int?) -> Void)?
    var workspaceRoot: String?
    var onOpenToolDiff: ((String, AgentToolActivity) -> Void)?
    var onOpenCheckpoint: ((String, String?) -> Void)?
    var onOpenCitation: ((AgentAssistantCitation) -> Void)?
    var onOpenThread: ((AgentThreadLink) -> Void)?
    /// Link cards and file-link tooltips of assistant responses.
    var linkServices: AgentConversationLinkServices?
    /// The services' pull-request hosts changed; rows render their responses again.
    func linkServicesDidChange() {}
    func update(_ items: [AgentChatItem]) {}
    func preferredHeight(for width: CGFloat) -> CGFloat { 0 }
    func layoutRow(width: CGFloat) {}
    func setApprovalsEnabled(_ enabled: Bool) {}
    func setTimestamp(_ date: Date?) {}
    func captureState() -> AgentTimelineRowState { AgentTimelineRowState() }
    func restoreState(_ state: AgentTimelineRowState) {}
    /// The text views showing this row's searchable text, in reading order, for Find;
    /// empty for rows Find does not search. Hidden views, such as a folded `<details>`,
    /// are included: Find counts their text and opens them to show a match.
    var findTextViews: [AgentRichTextView] { [] }
    private var cachedFindText: AgentMessageTextMap?
    /// Changes whenever the row may show other text, so Find knows what it painted is stale.
    private(set) var findTextGeneration = 0

    /// The row's searchable text as rendered, built once per content generation.
    var findText: AgentMessageTextMap {
        if let cachedFindText { return cachedFindText }
        let text = AgentMessageTextMap(views: findTextViews)
        cachedFindText = text
        return text
    }

    /// The row rendered or measured again (tables build their text when measured).
    func invalidateFindText() {
        cachedFindText = nil
        findTextGeneration &+= 1
    }

    /// Opens what hides `range` of `view`, one of `findTextViews`: a folded `<details>`
    /// block, or a collapsed message. True when the row changed.
    func revealFindText(_ view: AgentRichTextView, range: NSRange) -> Bool {
        AgentResponseContainer.revealAncestors(of: view, below: self)
    }

    static func bounded(_ text: String) -> String {
        guard text.utf8.count > 32_000 else { return text }
        return "[Earlier output omitted from this preview]\n" + String(text.suffix(32_000))
    }
}

@MainActor
final class AgentMessageRow: AgentTimelineRow, NSTextViewDelegate {
    private var item: AgentChatItem?
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    private var actionsFocused = false
    private let messageFade = CAGradientLayer()
    var showsResponseActions = true { didSet { if oldValue != showsResponseActions { renderText() } } }
    private let body = AgentRichTextView(frame: .zero)
    private let response = AgentResponseView(frame: .zero)
    private let media = AgentMessageMediaView(frame: .zero)
    private var mediaSize = NSSize.zero
    private let changes = AgentChangedFilesRow(frame: .zero)
    private var changesHeight: CGFloat = 0
    var checkpoint: AgentTurnCheckpoint? {
        didSet {
            changes.checkpoint = checkpoint
            changes.isHidden = (checkpoint?.totalFiles ?? 0) == 0
        }
    }
    private let copy = PillButton("Copy", style: .plain)
    private let expandMessage = PillButton("Show full message", style: .plain)
    /// A long user message shows this much of its text until "Show full message".
    static let collapsedMessageHeight: CGFloat = 176
    /// The bottom of a collapsed message that fades out.
    static let collapsedMessageFade: CGFloat = 28
    private var messageExpanded = false
    private let timestamp = makeLabel("", font: AppFont.footnote)
    private var timestampDate: Date?
    /// How long the turn this message answers took, shown before its time.
    var duration: TimeInterval? { didSet { if oldValue != duration { updateTimestampText() } } }
    /// User and assistant messages fill at most this fraction of the conversation lane.
    static let widthFraction: CGFloat = 0.8
    private var copyReset: Task<Void, Never>?
    private let detail = AgentRichTextView(frame: .zero)
    private let bubble = ThemedBackground(color: { $0.accent.withAlphaComponent(0.12) })
    private let permissionTitle = makeLabel("Approval needed", font: AppFont.small)
    private let deny = PillButton("Deny", style: .normal)
    private let allow = PillButton("Allow", style: .primary)
    private var bubbleWidth: CGFloat = 0
    private var bodyHeight: CGFloat = 0
    private var detailHeight: CGFloat = 0
    private var attachmentCards: [AgentFileAttachmentCard] = []
    private var filesOnly = false
    private var attachmentsHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bubble.cornerRadius = AgentMessageShape.radius
        bubble.layer?.cornerCurve = .continuous
        addSubview(bubble)
        addSubview(body)
        body.delegate = self
        addSubview(response)
        addSubview(media)
        media.onHeightChanged = { [weak self] in self?.onDisclosure?() }
        changes.isHidden = true
        addSubview(changes)
        changes.onDisclosure = { [weak self] in self?.onDisclosure?() }
        changes.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
        changes.onOpenCheckpoint = { [weak self] id, path in self?.onOpenCheckpoint?(id, path) }
        copy.translatesAutoresizingMaskIntoConstraints = true
        copy.font = AppFont.footnote
        copy.toolTip = "Copy response as Markdown"
        copy.setAccessibilityLabel("Copy response")
        addSubview(copy)
        timestamp.translatesAutoresizingMaskIntoConstraints = true
        timestamp.isHidden = true
        addSubview(timestamp)
        expandMessage.translatesAutoresizingMaskIntoConstraints = true
        expandMessage.font = AppFont.footnote
        addSubview(expandMessage)
        expandMessage.onPress = { [weak self] in
            guard let self else { return }
            self.messageExpanded.toggle()
            self.renderText()
            self.onDisclosure?()
        }
        copy.onFocusChange = { [weak self] focused in
            self?.actionsFocused = focused
            self?.updateActionVisibility()
        }
        copy.onPress = { [weak self] in
            guard let text = self?.item?.text else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.copy.image = AgentConversationIcon.check.image()
            self?.copyReset?.cancel()
            self?.copyReset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.copy.image = AgentConversationIcon.copy.image()
            }
        }
        response.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
        response.onOpenCitation = { [weak self] citation in self?.onOpenCitation?(citation) }
        response.onOpenThread = { [weak self] link in self?.onOpenThread?(link) }
        response.onHeightChanged = { [weak self] in self?.onDisclosure?() }
        response.onReveal = { [weak self] in
            guard let self, self.item?.kind == .user, !self.messageExpanded else { return }
            self.messageExpanded = true
            self.renderText()
            self.onDisclosure?()
        }
        addSubview(detail)
        for child in [permissionTitle, deny, allow] {
            child.translatesAutoresizingMaskIntoConstraints = true
            addSubview(child)
        }
        allow.onPress = { [weak self] in
            guard let self, let item = self.item else { return }
            self.onApproval?(item.id, true)
        }
        deny.onPress = { [weak self] in
            guard let self, let item = self.item else { return }
            self.onApproval?(item.id, false)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The rendered assistant message, or nil for user, notice and approval rows.
    var assistantItem: AgentChatItem? { item?.kind == .assistant ? item : nil }

    /// The message as rendered, for selections, citations and highlights.
    var textMap: AgentMessageTextMap { AgentMessageTextMap(views: response.textViews) }

    override func update(_ items: [AgentChatItem]) {
        guard let next = items.first, next != item else { return }
        item = next
        renderText()
    }

    override func runCommandHandlerDidChange() {
        response.onRunShellCommand = item?.kind == .assistant ? onRunShellCommand : nil
    }

    override func linkServicesDidChange() { renderText() }

    private func renderText() {
        guard let item else { return }
        let text = item.text
        response.isStreaming = !item.isComplete
        runCommandHandlerDidChange()
        let collapsible = item.kind == .user && (text.count > 600 || text.components(separatedBy: "\n").count > 8)
        expandMessage.isHidden = !collapsible
        expandMessage.title = messageExpanded ? "Show less" : "Show full message"
        expandMessage.setTitleColor(theme.fgDim)
        body.isHidden = item.kind == .assistant || item.kind == .user
        let allAttachments = item.kind == .user ? item.attachments ?? [] : []
        let images = allAttachments.filter { $0.mimeType.lowercased().hasPrefix("image/") }
        let attachments = allAttachments.filter { !$0.mimeType.lowercased().hasPrefix("image/") }
        media.fetch = fetchAttachment
        media.onPreview = onPreviewAttachments
        media.update(item: item.id, attachments: images, theme: theme)
        filesOnly = item.kind == .user && images.isEmpty && !attachments.isEmpty && item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        while attachmentCards.count > attachments.count { attachmentCards.removeLast().removeFromSuperview() }
        while attachmentCards.count < attachments.count {
            let card = AgentFileAttachmentCard(frame: .zero)
            addSubview(card)
            attachmentCards.append(card)
        }
        for (index, attachment) in attachments.enumerated() {
            let card = attachmentCards[index]
            card.update(attachment, standalone: filesOnly, theme: theme)
            card.onOpen = { [weak self] download in self?.onOpenAttachment?(item.id, attachment, download) }
        }
        response.isHidden = item.kind != .assistant && item.kind != .user
        copy.isHidden = (item.kind != .assistant && item.kind != .user) || (item.kind == .user && item.text.isEmpty) || !item.isComplete || (item.kind == .assistant && !showsResponseActions)
        copy.toolTip = item.kind == .user ? "Copy message" : "Copy response as Markdown"
        copy.setAccessibilityLabel(item.kind == .user ? "Copy message" : "Copy response")
        copy.title = ""
        copy.image = AgentConversationIcon.copy.image()
        copy.imagePosition = .imageOnly
        updateActionVisibility()
        copy.setTitleColor(theme.fgDim)
        timestamp.textColor = theme.fgDim
        if item.kind == .assistant || item.kind == .user {
            response.parseRawHTML = item.kind == .assistant
            response.lineBreaks = item.kind == .user
            response.linkServices = item.kind == .assistant ? linkServices : nil
            response.setContent(text, theme: theme)
        }
        else { body.setContent(AgentMarkdown.plain(text, theme: theme, muted: item.kind == .notice)) }
        detail.setContent(AgentMarkdown.plain(Self.bounded(item.detail ?? ""), theme: theme, muted: true, monospaced: true))
        body.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        detail.selectedTextAttributes = body.selectedTextAttributes
        bubble.isHidden = item.kind != .user || filesOnly || (!media.isHidden && item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
        media.joinsTextBubble = !bubble.isHidden
        let pending = item.kind == .approval && !item.isComplete
        permissionTitle.isHidden = item.kind != .approval
        permissionTitle.stringValue = pending ? "Approval needed" : "Approval resolved"
        permissionTitle.textColor = pending ? theme.accent : theme.fgDim
        allow.isHidden = !pending
        deny.isHidden = !pending
        detail.isHidden = item.kind != .approval || (item.detail ?? "").isEmpty
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat {
        guard let item else { return 0 }
        if item.kind == .user {
            let plain = item.text as NSString
            let natural = plain.boundingRect(with: NSSize(width: max(1, width * Self.widthFraction - 28), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: AppFont.system(14, weight: .light)]).width
            let attachmentWidth = attachmentCards.map(\.naturalWidth).max() ?? 0
            bubbleWidth = min(width * Self.widthFraction, max(48, ceil(max(natural, attachmentWidth)) + 28))
            let hasRichBlocks = AgentResponsePart.partition(AgentResponseParser.parse(item.text, parseRawHTML: false)).contains { $0.kind != 0 }
            if hasRichBlocks { bubbleWidth = width * Self.widthFraction }
            bodyHeight = item.text.isEmpty ? 0 : response.height(for: max(1, bubbleWidth - 28))
            if !expandMessage.isHidden && !messageExpanded { bodyHeight = min(Self.collapsedMessageHeight, bodyHeight) }
            attachmentsHeight = attachmentCards.reduce(0) { $0 + $1.preferredHeight } + CGFloat(max(0, attachmentCards.count - 1)) * 4
            if !attachmentCards.isEmpty && bodyHeight > 0 { attachmentsHeight += 8 }
            if filesOnly { bubbleWidth = min(width * Self.widthFraction, 256); return attachmentsHeight + 28 }
            mediaSize = media.measuredSize(maxWidth: max(1, width * Self.widthFraction))
            if bubble.isHidden { return mediaSize.height + 28 }
            return mediaSize.height + (mediaSize.height > 0 ? 4 : 0) + bodyHeight + attachmentsHeight + 14 + (expandMessage.isHidden ? 0 : 26) + 28
        }
        bodyHeight = item.kind == .assistant ? response.height(for: Self.responseWidth(width)) : body.height(for: width)
        detailHeight = detail.isHidden ? 0 : detail.height(for: max(1, width - 24))
        if item.kind == .approval {
            return 24 + bodyHeight + (detail.isHidden ? 0 : detailHeight + 14) + (item.isComplete ? 0 : 42)
        }
        changesHeight = item.kind == .assistant && !changes.isHidden ? changes.preferredHeight(for: width) : 0
        return bodyHeight + (changesHeight > 0 ? 16 + changesHeight : 0) + (copy.isHidden ? 0 : 28)
    }

    override func layoutRow(width: CGFloat) {
        guard let item else { return }
        if item.kind == .user {
            let left = width - bubbleWidth
            media.frame = NSRect(x: width - mediaSize.width, y: 0, width: mediaSize.width, height: mediaSize.height)
            media.layoutSubtreeIfNeeded()
            let bubbleY = mediaSize.height + (mediaSize.height > 0 && !bubble.isHidden ? 4 : 0)
            bubble.frame = NSRect(x: left, y: bubbleY, width: bubbleWidth, height: max(0, bounds.height - 28 - bubbleY))
            if !media.isHidden && !bubble.isHidden {
                bubble.cornerRadius = 0
                AgentMessageShape.apply(to: bubble, topRight: AgentMessageShape.joinedRadius)
            } else { bubble.cornerRadius = AgentMessageShape.radius; bubble.layer?.mask = nil }
            response.frame = NSRect(x: left + 14, y: bubbleY + 7 + attachmentsHeight, width: max(1, bubbleWidth - 28), height: bodyHeight)
            expandMessage.frame = NSRect(x: max(left, width - 146), y: response.frame.maxY + 4, width: min(140, bubbleWidth), height: 24)
            response.layoutSubtreeIfNeeded()
            response.wantsLayer = true
            response.layer?.masksToBounds = true
            if !expandMessage.isHidden && !messageExpanded {
                messageFade.frame = response.bounds
                messageFade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
                messageFade.locations = [0, NSNumber(value: Double(max(0, 1 - Self.collapsedMessageFade / max(1, bodyHeight)))), 1]
                messageFade.startPoint = CGPoint(x: 0.5, y: 0)
                messageFade.endPoint = CGPoint(x: 0.5, y: 1)
                response.layer?.mask = messageFade
            } else { response.layer?.mask = nil }
            var attachmentTop: CGFloat = filesOnly ? 0 : bubbleY + 7
            for card in attachmentCards {
                card.frame = NSRect(x: filesOnly ? left : left + 14, y: attachmentTop,
                                    width: max(1, filesOnly ? bubbleWidth : bubbleWidth - 28), height: card.preferredHeight)
                card.layoutSubtreeIfNeeded()
                attachmentTop += card.preferredHeight + 4
            }
            copy.frame = NSRect(x: width - 60, y: (filesOnly ? attachmentsHeight : bubble.isHidden ? media.frame.maxY : bubble.frame.maxY) + 4, width: 60, height: 24)
            timestamp.frame = NSRect(x: max(0, width - (copy.isHidden ? 150 : 220)), y: copy.frame.minY + 4, width: 150, height: 18)
            timestamp.alignment = .right
        } else if item.kind == .approval {
            permissionTitle.frame = NSRect(x: 0, y: 0, width: width, height: 18)
            body.frame = NSRect(x: 0, y: 24, width: width, height: bodyHeight)
            detail.frame = NSRect(x: 12, y: body.frame.maxY + 12, width: max(1, width - 24), height: detailHeight)
            let actionsY = detail.isHidden ? body.frame.maxY + 12 : detail.frame.maxY + 12
            deny.frame = NSRect(x: 0, y: actionsY, width: 62, height: 26)
            allow.frame = NSRect(x: 70, y: actionsY, width: 66, height: 26)
        } else if item.kind == .assistant {
            response.frame = NSRect(x: 0, y: 0, width: Self.responseWidth(width), height: bodyHeight)
            response.layoutSubtreeIfNeeded()
            let footerY = bodyHeight + (changesHeight > 0 ? 16 + changesHeight : 0)
            changes.frame = NSRect(x: 0, y: bodyHeight + 16, width: width, height: changesHeight)
            changes.layoutRow(width: width)
            let timestampWidth = timestamp.isHidden ? 0 : min(max(0, width - 40), ceil(timestamp.attributedStringValue.size().width) + 4)
            timestamp.frame = NSRect(x: 0, y: footerY + 8, width: timestampWidth, height: 18)
            timestamp.alignment = .left
            copy.frame = NSRect(x: timestampWidth + (timestampWidth > 0 ? 4 : -4), y: footerY + 4, width: 28, height: 24)
        } else {
            body.frame = NSRect(x: 0, y: 0, width: width, height: bodyHeight)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateActionVisibility() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateActionVisibility() }

    /// An assistant message's width: the lane narrowed to the shared message fraction.
    static func responseWidth(_ width: CGFloat) -> CGFloat { max(1, floor(width * widthFraction)) }

    private func updateActionVisibility() {
        // An answer's footer always shows when its turn ended; a user message's only on hover.
        // Keep controls in the accessibility tree while matching the quiet resting footer.
        let opacity: CGFloat = hovered || actionsFocused || item?.kind == .assistant ? 1 : 0
        copy.alphaValue = opacity
        timestamp.alphaValue = opacity
    }

    override func setApprovalsEnabled(_ enabled: Bool) {
        let pending = item?.kind == .approval && item?.isComplete == false
        allow.isEnabled = enabled && pending
        deny.isEnabled = enabled && pending
    }

    override func setTimestamp(_ date: Date?) {
        timestamp.isHidden = date == nil || (copy.isHidden && item?.kind != .user)
        guard timestampDate != date else { return }
        timestampDate = date
        updateTimestampText()
    }

    private func updateTimestampText() {
        guard let date = timestampDate else { return }
        let time = AgentTurnTime.moment(date)
        let text = item?.kind == .assistant ? duration.map { AgentTurnTime.duration($0) + " · " + time } ?? time : time
        guard timestamp.stringValue != text else { return }
        timestamp.stringValue = text
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        timestamp.toolTip = formatter.string(from: date)
        needsLayout = true
    }

    override func themeDidChange() {
        bubble.theme = theme
        changes.theme = theme
        changes.themeDidChange()
        renderText()
    }

    override var findTextViews: [AgentRichTextView] {
        guard item?.kind == .user || item?.kind == .assistant else { return [] }
        return response.textViews
    }

    /// Also expands a collapsed long user message when the match is below its fold.
    override func revealFindText(_ view: AgentRichTextView, range: NSRange) -> Bool {
        let opened = super.revealFindText(view, range: range)
        guard item?.kind == .user, !expandMessage.isHidden, !messageExpanded,
              !isShownWhileCollapsed(range, in: view) else { return opened }
        messageExpanded = true
        renderText()
        onDisclosure?()
        return true
    }

    /// True when `range` lies above the fade of the collapsed message.
    private func isShownWhileCollapsed(_ range: NSRange, in view: AgentRichTextView) -> Bool {
        guard !view.isHiddenOrHasHiddenAncestor, let manager = view.layoutManager, let container = view.textContainer else { return false }
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += view.textContainerOrigin.y
        return response.convert(rect, from: view).maxY <= Self.collapsedMessageHeight - Self.collapsedMessageFade
    }

    override func captureState() -> AgentTimelineRowState {
        AgentTimelineRowState(expanded: messageExpanded, responseState: response.captureState(), wrappedCodeSections: response.wrappedCodeSections, children: ["changes": changes.captureState()])
    }

    override func restoreState(_ state: AgentTimelineRowState) {
        if messageExpanded != state.expanded {
            messageExpanded = state.expanded
            renderText()
        }
        if let state = state.responseState { response.restoreState(state) }
        else if let wrapped = state.wrappedCodeSections { response.wrappedCodeSections = wrapped }
        changes.restoreState(state.children["changes"] ?? AgentTimelineRowState())
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let destination = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        guard let target = AgentResponseLink.parse(destination) else { return true }
        switch target {
        case .fragment(let id): _ = response.openFragment(id); return true
        case .file(let path, let line): onOpenFile?(path, line); return true
        case .external: return false
        }
    }
}

/// Tool entries expose their own disclosure directly, without a second group toggle.
@MainActor
final class AgentActivityRow: AgentTimelineRow {
    private let tool = AgentToolDisclosure(frame: .zero)
    private var item: AgentChatItem?
    var grouped = false { didSet { tool.grouped = grouped } }
    private var expanded = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(tool)
        tool.onHeightChanged = { [weak self] in self?.onDisclosure?() }
        tool.onOpenToolDiff = { [weak self] id, activity in self?.onOpenToolDiff?(id, activity) }
        tool.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
        tool.onDisclosure = { [weak self] in
            guard let self else { return }
            self.expanded.toggle()
            self.refresh()
            self.onDisclosure?()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func update(_ items: [AgentChatItem]) {
        item = items.first
        refresh()
    }
    private func refresh() {
        tool.workspaceRoot = workspaceRoot
        tool.fetchAttachment = fetchAttachment
        tool.onPreviewAttachments = onPreviewAttachments
        tool.onHTMLDocument = onHTMLDocument
        if let item { tool.update(item, expanded: expanded, theme: theme) }
    }
    override func preferredHeight(for width: CGFloat) -> CGFloat { tool.height(for: width) }
    override func layoutRow(width: CGFloat) { tool.frame = bounds; tool.layoutSubtreeIfNeeded() }
    override func themeDidChange() { tool.refresh(theme: theme) }
    override func captureState() -> AgentTimelineRowState {
        AgentTimelineRowState(toolExpandedIDs: expanded ? Set(item.map { [$0.id] } ?? []) : [],
                              argumentScrollOffset: tool.argumentScrollPosition, scrollOffset: tool.outputScrollPosition)
    }
    override func restoreState(_ state: AgentTimelineRowState) {
        expanded = item.map { state.toolExpandedIDs.contains($0.id) } ?? false
        tool.restoreOutputScrollPosition(state.scrollOffset)
        tool.restoreArgumentScrollPosition(state.argumentScrollOffset)
        refresh()
    }
}

/// The bottom of a running turn: the sidebar's working glyph and the turn's live
/// elapsed time, to a tenth of a second.
@MainActor
final class AgentWorkingRow: AgentTimelineRow {
    var turn: AgentChatTurn? { didSet { if oldValue != turn { refresh() } } }
    private let glyph = ActivityGlyph()
    private let label = makeLabel("", font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular))
    private var ticker: Timer?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = true
        label.setAccessibilityLabel("Agent working time")
        addSubview(glyph)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ticker?.invalidate()
        ticker = nil
        guard window != nil else { return }
        // Only this label changes on each tick: no layout or row measurement.
        let ticker = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        ticker.tolerance = 0.02
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        refresh()
    }
    deinit { ticker?.invalidate() }
    private func refresh() {
        let text = AgentTurnTime.elapsed(Date().timeIntervalSince(turn?.startedAt ?? Date()))
        if label.stringValue != text { label.stringValue = text }
    }
    override func update(_ items: [AgentChatItem]) { refresh() }
    override func preferredHeight(for width: CGFloat) -> CGFloat { 28 }
    override func layoutRow(width: CGFloat) {
        glyph.frame = NSRect(x: 2, y: 8, width: 12, height: 12)
        label.frame = NSRect(x: 24, y: 4, width: max(0, width - 24), height: 20)
    }
    override func themeDidChange() {
        glyph.style = .dots(theme.accent)
        label.textColor = theme.fgDim
        refresh()
    }
}

/// How the conversation writes a turn's times.
enum AgentTurnTime {
    /// A running turn, to a tenth of a second: `40.3s`, `3m 05.2s`, `1h 03m 05.2s`.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded(.down))
        let fraction = String(format: "%04.1f", Double(tenths % 600) / 10)
        let minutes = tenths / 600
        if minutes == 0 { return String(format: "%.1fs", Double(tenths) / 10) }
        if minutes < 60 { return "\(minutes)m \(fraction)s" }
        return String(format: "%dh %02dm ", minutes / 60, minutes % 60) + fraction + "s"
    }

    /// A finished turn: `2s`, `3m, 0s`, `1h, 3m`.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m, \(total % 60)s" }
        return "\(total / 3600)h, \(total % 3600 / 60)m"
    }

    /// When a turn ended: the time today, the weekday and time this week, else the date.
    static func moment(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let time = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           days > 0, days < 7 {
            formatter.timeStyle = .none
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            return formatter.string(from: date) + " " + time
        }
        formatter.timeStyle = .none
        formatter.dateStyle = .short
        return formatter.string(from: date) + " " + time
    }
}
