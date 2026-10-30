import AppKit
import TabProtocol

@MainActor
class AgentTimelineRow: ThemedView {
    var onDisclosure: (() -> Void)?
    var onApproval: ((String, Bool) -> Void)?
    var onOpenFile: ((String, Int?) -> Void)?
    func update(_ items: [AgentChatItem]) {}
    func preferredHeight(for width: CGFloat) -> CGFloat { 0 }
    func layoutRow(width: CGFloat) {}
    func setApprovalsEnabled(_ enabled: Bool) {}
    func setTimestamp(_ date: Date?) {}
    func captureState() -> AgentTimelineRowState { AgentTimelineRowState() }
    func restoreState(_ state: AgentTimelineRowState) {}

    static func bounded(_ text: String) -> String {
        guard text.utf8.count > 32_000 else { return text }
        return "[Earlier output omitted from this preview]\n" + String(text.suffix(32_000))
    }
}

@MainActor
final class AgentMessageRow: AgentTimelineRow, NSTextViewDelegate {
    private var item: AgentChatItem?
    private let body = AgentRichTextView(frame: .zero)
    private let response = AgentResponseView(frame: .zero)
    private let copy = PillButton("Copy", style: .plain)
    private let expandMessage = PillButton("Show more", style: .plain)
    private var messageExpanded = false
    private let timestamp = makeLabel("", font: AppFont.footnote)
    private var timestampDate: Date?
    private var copyReset: Task<Void, Never>?
    private let detail = AgentRichTextView(frame: .zero)
    private let bubble = ThemedBackground(color: { $0.fg.withAlphaComponent(0.055) })
    private let permissionTitle = makeLabel("Approval needed", font: AppFont.small)
    private let deny = PillButton("Deny", style: .normal)
    private let allow = PillButton("Allow", style: .primary)
    private var bubbleWidth: CGFloat = 0
    private var bodyHeight: CGFloat = 0
    private var detailHeight: CGFloat = 0
    private var attachmentLabels: [NSTextField] = []
    private var attachmentsHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bubble.cornerRadius = 15
        addSubview(bubble)
        addSubview(body)
        body.delegate = self
        addSubview(response)
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
        copy.onPress = { [weak self] in
            guard let text = self?.item?.text else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.copy.title = "Copied"
            self?.copyReset?.cancel()
            self?.copyReset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.copy.title = "Copy"
            }
        }
        response.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
        response.onHeightChanged = { [weak self] in self?.onDisclosure?() }
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

    override func update(_ items: [AgentChatItem]) {
        guard let next = items.first, next != item else { return }
        item = next
        renderText()
    }

    private func renderText() {
        guard let item else { return }
        var text = item.text
        let collapsible = item.kind == .user && (text.count > 600 || text.components(separatedBy: "\n").count > 8)
        expandMessage.isHidden = !collapsible
        expandMessage.title = messageExpanded ? "Show less" : "Show more"
        expandMessage.setTitleColor(theme.fgDim)
        if collapsible && !messageExpanded {
            text = String(text.prefix(600)).components(separatedBy: "\n").prefix(8).joined(separator: "\n") + "…"
        }
        body.isHidden = item.kind == .assistant
        let attachments = item.kind == .user ? item.attachments ?? [] : []
        while attachmentLabels.count > attachments.count { attachmentLabels.removeLast().removeFromSuperview() }
        while attachmentLabels.count < attachments.count {
            let label = makeLabel("", font: AppFont.small)
            label.lineBreakMode = .byTruncatingMiddle
            label.isSelectable = true
            addSubview(label)
            attachmentLabels.append(label)
        }
        for (index, attachment) in attachments.enumerated() {
            let size = ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)
            let label = attachmentLabels[index]
            label.stringValue = "📎 \(attachment.name) · \(size)"
            label.toolTip = attachment.name
            label.textColor = theme.fgMuted
            label.setAccessibilityLabel("Attachment: \(attachment.name), \(size)")
        }
        response.isHidden = item.kind != .assistant
        copy.isHidden = (item.kind != .assistant && item.kind != .user) || !item.isComplete
        copy.toolTip = item.kind == .user ? "Copy message" : "Copy response as Markdown"
        copy.setAccessibilityLabel(item.kind == .user ? "Copy message" : "Copy response")
        copy.title = "Copy"
        copy.setTitleColor(theme.fgDim)
        timestamp.textColor = theme.fgDim
        if item.kind == .assistant { response.setContent(text, theme: theme) }
        else if item.kind == .user { body.setContent(AgentMarkdown.render(text, theme: theme)) }
        else { body.setContent(AgentMarkdown.plain(text, theme: theme, muted: item.kind == .notice)) }
        detail.setContent(AgentMarkdown.plain(Self.bounded(item.detail ?? ""), theme: theme, muted: true, monospaced: true))
        body.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        detail.selectedTextAttributes = body.selectedTextAttributes
        bubble.isHidden = item.kind != .user
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
            let plain = body.string as NSString
            let natural = plain.boundingRect(with: NSSize(width: max(1, width * 0.85 - 28), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: AppFont.system(14)]).width
            let attachmentWidth = attachmentLabels.map {
                ($0.stringValue as NSString).size(withAttributes: [.font: AppFont.small]).width
            }.max() ?? 0
            bubbleWidth = min(width * 0.85, max(48, ceil(max(natural, attachmentWidth)) + 28))
            bodyHeight = body.string.isEmpty ? 0 : body.height(for: max(1, bubbleWidth - 28))
            if !expandMessage.isHidden && !messageExpanded { bodyHeight = min(176, bodyHeight) }
            attachmentsHeight = attachmentLabels.isEmpty ? 0 : CGFloat(attachmentLabels.count) * 22 + (bodyHeight > 0 ? 8 : 0)
            return bodyHeight + attachmentsHeight + 22 + (expandMessage.isHidden ? 0 : 26) + 28
        }
        bodyHeight = item.kind == .assistant ? response.height(for: width) : body.height(for: width)
        detailHeight = detail.isHidden ? 0 : detail.height(for: max(1, width - 24))
        if item.kind == .approval {
            return 24 + bodyHeight + (detail.isHidden ? 0 : detailHeight + 14) + (item.isComplete ? 0 : 42)
        }
        return bodyHeight + (copy.isHidden ? 0 : 28)
    }

    override func layoutRow(width: CGFloat) {
        guard let item else { return }
        if item.kind == .user {
            let left = width - bubbleWidth
            bubble.frame = NSRect(x: left, y: 0, width: bubbleWidth, height: bounds.height - 28)
            body.frame = NSRect(x: left + 14, y: 11, width: max(1, bubbleWidth - 28), height: bodyHeight)
            expandMessage.frame = NSRect(x: left + 10, y: body.frame.maxY + 4, width: 90, height: 24)
            let attachmentTop = body.frame.maxY + (expandMessage.isHidden ? 0 : 26) + (bodyHeight > 0 ? 8 : 0)
            for (index, label) in attachmentLabels.enumerated() {
                label.frame = NSRect(x: left + 14, y: attachmentTop + CGFloat(index) * 22,
                                     width: max(1, bubbleWidth - 28), height: 20)
            }
            copy.frame = NSRect(x: width - 60, y: bubble.frame.maxY + 4, width: 60, height: 24)
            timestamp.frame = NSRect(x: max(0, width - 220), y: copy.frame.minY + 4, width: 150, height: 18)
            timestamp.alignment = .right
        } else if item.kind == .approval {
            permissionTitle.frame = NSRect(x: 0, y: 0, width: width, height: 18)
            body.frame = NSRect(x: 0, y: 24, width: width, height: bodyHeight)
            detail.frame = NSRect(x: 12, y: body.frame.maxY + 12, width: max(1, width - 24), height: detailHeight)
            let actionsY = detail.isHidden ? body.frame.maxY + 12 : detail.frame.maxY + 12
            deny.frame = NSRect(x: 0, y: actionsY, width: 62, height: 26)
            allow.frame = NSRect(x: 70, y: actionsY, width: 66, height: 26)
        } else if item.kind == .assistant {
            response.frame = NSRect(x: 0, y: 0, width: width, height: bodyHeight)
            response.layoutSubtreeIfNeeded()
            copy.frame = NSRect(x: -4, y: bodyHeight + 4, width: 60, height: 24)
            timestamp.frame = NSRect(x: 64, y: copy.frame.minY + 4, width: max(0, width - 64), height: 18)
            timestamp.alignment = .left
        } else {
            body.frame = NSRect(x: 0, y: 0, width: width, height: bodyHeight)
        }
    }

    override func setApprovalsEnabled(_ enabled: Bool) {
        let pending = item?.kind == .approval && item?.isComplete == false
        allow.isEnabled = enabled && pending
        deny.isEnabled = enabled && pending
    }

    override func setTimestamp(_ date: Date?) {
        timestamp.isHidden = date == nil || copy.isHidden
        guard timestampDate != date else { return }
        timestampDate = date
        guard let date else { return }
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        formatter.timeStyle = .short
        timestamp.stringValue = formatter.string(from: date)
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        timestamp.toolTip = formatter.string(from: date)
    }

    override func themeDidChange() {
        bubble.theme = theme
        renderText()
    }

    override func captureState() -> AgentTimelineRowState {
        AgentTimelineRowState(expanded: messageExpanded, wrappedCodeSections: response.wrappedCodeSections)
    }

    override func restoreState(_ state: AgentTimelineRowState) {
        if messageExpanded != state.expanded {
            messageExpanded = state.expanded
            renderText()
        }
        response.wrappedCodeSections = state.wrappedCodeSections
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let destination = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        guard let target = AgentResponseLink.parse(destination) else { return true }
        switch target {
        case .file(let path, let line): onOpenFile?(path, line); return true
        case .external: return false
        }
    }
}

/// Consecutive tool events occupy one quiet work-log disclosure, never a wall of cards.
@MainActor
final class AgentActivityRow: AgentTimelineRow {
    private var items: [AgentChatItem] = []
    private var expanded = false
    private let disclosure = PillButton("", style: .plain)
    private let log = AgentToolDetailView(frame: .zero)
    private var logHeight: CGFloat = 0
    private var logLoaded = false
    private var savedToolExpandedIDs: Set<String> = []
    private var savedLogOffset: NSPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosure.translatesAutoresizingMaskIntoConstraints = true
        disclosure.alignment = .left
        disclosure.font = AppFont.small
        disclosure.imagePosition = .imageLeading
        disclosure.imageScaling = .scaleProportionallyDown
        addSubview(disclosure)
        addSubview(log)
        log.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
        log.onDisclosure = { [weak self] in self?.onDisclosure?() }
        disclosure.onPress = { [weak self] in
            guard let self else { return }
            self.expanded.toggle()
            if self.expanded { self.updateLog() }
            else { self.unloadLog() }
            self.updateDisclosure()
            self.onDisclosure?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func update(_ items: [AgentChatItem]) {
        guard self.items != items else { return }
        self.items = items
        if expanded { updateLog() }
        updateDisclosure()
    }

    private func updateDisclosure() {
        let running = items.contains { !$0.isComplete }
        let summary: String
        if items.count == 1 {
            let item = items[0]
            let action = item.tool?.summary ?? String(item.text.prefix(220)).components(separatedBy: "\n").first ?? "Tool activity"
            let state: String
            switch item.tool?.status {
            case .failed: state = " · Failed"
            case .denied: state = " · Denied"
            case .interrupted: state = " · Interrupted"
            default: state = running ? " · Running" : ""
            }
            summary = action + state
        } else {
            let failures = items.filter { $0.tool?.status == .failed || $0.tool?.status == .denied }.count
            summary = (running ? "Using \(items.count) tools…" : "\(items.count) tools used") + (failures > 0 ? " · \(failures) failed or denied" : "")
        }
        disclosure.title = (expanded ? "⌄  " : "›  ") + summary
        disclosure.setTitleColor(theme.fgDim)
        disclosure.setAccessibilityLabel((expanded ? "Collapse activity: " : "Expand activity: ") + summary)
        disclosure.toolTip = summary
        log.isHidden = !expanded
    }

    private func updateLog() {
        log.update(items: items, theme: theme)
        if !logLoaded {
            log.expandedIDs = savedToolExpandedIDs
            log.scrollOffset = savedLogOffset
        }
        logLoaded = true
    }

    private func unloadLog() {
        guard logLoaded else { return }
        savedToolExpandedIDs = log.expandedIDs
        savedLogOffset = log.scrollOffset
        log.update(items: [], theme: theme)
        logLoaded = false
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat {
        logHeight = expanded ? log.height(for: max(1, width - 20)) : 0
        return expanded ? 32 + logHeight : 24
    }

    override func layoutRow(width: CGFloat) {
        disclosure.frame = NSRect(x: -4, y: 0, width: width + 4, height: 24)
        log.frame = NSRect(x: 20, y: 32, width: max(1, width - 20), height: logHeight)
        log.layoutSubtreeIfNeeded()
    }

    override func themeDidChange() {
        if expanded { updateLog() }
        updateDisclosure()
    }

    override func captureState() -> AgentTimelineRowState {
        AgentTimelineRowState(expanded: expanded, toolExpandedIDs: logLoaded ? log.expandedIDs : savedToolExpandedIDs,
                              scrollOffset: logLoaded ? log.scrollOffset : savedLogOffset)
    }

    override func restoreState(_ state: AgentTimelineRowState) {
        expanded = state.expanded
        savedToolExpandedIDs = state.toolExpandedIDs
        savedLogOffset = state.scrollOffset
        if expanded {
            updateLog()
            log.expandedIDs = savedToolExpandedIDs
            log.scrollOffset = savedLogOffset
        } else { unloadLog() }
        updateDisclosure()
    }
}
