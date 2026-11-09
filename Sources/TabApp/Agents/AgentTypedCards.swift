import AppKit
import TabProtocol
import UniformTypeIdentifiers

/// What a plan card can ask of the conversation. A nil writer means the
/// workspace is unavailable, which the card reports when Save is pressed.
@MainActor
struct AgentPlanCardServices {
    /// `(relativePath, contents, cwd)`; returns the path the project server confirmed.
    var writeProjectFile: ((String, String, String?) async throws -> String)?
    /// Asks where to save a download; nil when the person cancels.
    var chooseDownloadURL: (String) async -> URL? = { await AgentPlanCardServices.presentSavePanel(suggestedName: $0) }
    var pasteboard: NSPasteboard = .general
    var cwd: String?
    var now: () -> Date = { Date() }

    static func presentSavePanel(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard let window = NSApp.keyWindow else { return panel.runModal() == .OK ? panel.url : nil }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}

/// Shared chrome of the transcript's typed cards: one item, an optional rounded card.
@MainActor
class AgentCardRow: AgentTimelineRow {
    private(set) var item: AgentChatItem?
    var cardFill: NSColor? { nil }
    var cardBorder: NSColor? { nil }

    static func make(_ kind: AgentTypedCardKind) -> AgentCardRow {
        switch kind {
        case .plan: AgentPlanCardRow()
        case .todo: AgentTodoCardRow()
        case .compaction: AgentCompactionRow()
        case .error: AgentErrorCardRow()
        case .notice: AgentNoticeRow()
        case .peer(let mode): AgentPeerCardRow(mode: mode)
        }
    }

    override func update(_ items: [AgentChatItem]) {
        guard let next = items.first, next != item else { return }
        item = next
        render()
    }

    /// Applies the current item and theme to the row's views.
    func render() {}

    override func themeDidChange() {
        render()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard cardFill != nil || cardBorder != nil else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        if let cardFill { cardFill.setFill(); path.fill() }
        if let cardBorder { cardBorder.setStroke(); path.lineWidth = 1; path.stroke() }
    }
}

/// A small rounded status label, such as a plan's "Active".
@MainActor
final class AgentStatusPill: NSView {
    var text = "" { didSet { if oldValue != text { needsDisplay = true } } }
    var color = NSColor.secondaryLabelColor { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    private var attributes: [NSAttributedString.Key: Any] { [.font: AppFont.footnoteMedium, .foregroundColor: color] }
    var naturalWidth: CGFloat { ceil((text as NSString).size(withAttributes: attributes).width) + 14 }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }
}

// MARK: Plan

/// A proposed plan: read-only Markdown with a status pill and Copy, Download and Save.
@MainActor
final class AgentPlanCardRow: AgentCardRow {
    var services = AgentPlanCardServices()
    private let icon: NSImageView
    private let title: NSTextField
    private let status = AgentStatusPill()
    private let body: AgentResponseView
    private let feedback: NSTextField
    let copyButton = PillButton("", style: .plain)
    let downloadButton = PillButton("", style: .plain)
    let saveButton = PillButton("", style: .plain)
    private var bodyHeight: CGFloat = 0
    private var copyReset: Task<Void, Never>?
    private(set) var feedbackText: String?
    private(set) var feedbackIsFailure = false
    private let padding: CGFloat = 14
    private let headerHeight: CGFloat = 40

    var planStatus: AgentPlanStatus { AgentPlanStatus(item?.workContext?.planStatus) }
    var isStreaming: Bool { item.map { !$0.isComplete || $0.workContext?.sourceStatus == "running" } ?? false }
    var markdown: String { AgentPlanExport.markdown(item?.detail ?? "") }
    override var findTextViews: [AgentRichTextView] { body.textViews }

    override init(frame frameRect: NSRect) {
        icon = NSImageView()
        title = makeLabel("Plan", font: AppFont.header)
        feedback = makeLabel("", font: AppFont.footnote)
        body = AgentResponseView(frame: .zero)
        super.init(frame: frameRect)
        for view in [icon, title, feedback, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        body.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
        body.onOpenCitation = { [weak self] citation in self?.onOpenCitation?(citation) }
        body.onHeightChanged = { [weak self] in self?.onDisclosure?() }
        addSubview(body)
        feedback.isHidden = true
        feedback.lineBreakMode = .byTruncatingMiddle
        for (button, glyph, label) in [(copyButton, AppIcon.copy, "Copy plan as Markdown"),
                                       (downloadButton, .download, "Download plan"),
                                       (saveButton, .folderPlus, "Save plan to workspace")] {
            button.translatesAutoresizingMaskIntoConstraints = true
            button.image = glyph.image(size: 12, scale: AppIcon.inlineScale)
            button.imagePosition = .imageOnly
            button.toolTip = label
            button.setAccessibilityLabel(label)
            addSubview(button)
        }
        copyButton.onPress = { [weak self] in self?.copyPlan() }
        downloadButton.onPress = { [weak self] in Task { await self?.downloadPlan() } }
        saveButton.onPress = { [weak self] in Task { await self?.savePlan() } }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var cardFill: NSColor? { theme.fg.withAlphaComponent(0.025) }
    override var cardBorder: NSColor? { theme.fg.withAlphaComponent(0.1) }

    override func render() {
        guard let item else { return }
        icon.image = AppIcon.fileText.image(size: 15, scale: AppIcon.inlineScale, theme: theme)
        title.textColor = theme.fg
        status.text = planStatus.title
        status.color = switch planStatus {
        case .proposed, .active: theme.accent
        case .completed: theme.diffAdd
        case .superseded: theme.fgDim
        }
        status.setAccessibilityLabel("Plan status")
        body.isStreaming = isStreaming
        body.setContent(item.detail ?? "", theme: theme)
        for button in [copyButton, downloadButton, saveButton] {
            button.contentTintColor = theme.fgDim
            button.isEnabled = !isStreaming
        }
        feedback.textColor = feedbackIsFailure ? theme.danger : theme.fgDim
        needsDisplay = true
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat {
        bodyHeight = body.height(for: max(1, width - 2 * padding))
        return headerHeight + bodyHeight + padding + (feedback.isHidden ? 0 : 22)
    }

    override func layoutRow(width: CGFloat) {
        icon.frame = NSRect(x: padding, y: 12, width: 16, height: 16)
        let titleWidth = ceil(title.intrinsicContentSize.width)
        title.frame = NSRect(x: padding + 24, y: 11, width: titleWidth, height: 18)
        status.frame = NSRect(x: title.frame.maxX + 8, y: 11, width: status.naturalWidth, height: 18)
        var x = width - 8
        for button in [saveButton, downloadButton, copyButton] {
            x -= 28
            button.frame = NSRect(x: x, y: 8, width: 28, height: 24)
        }
        body.frame = NSRect(x: padding, y: headerHeight, width: max(1, width - 2 * padding), height: bodyHeight)
        body.layoutSubtreeIfNeeded()
        feedback.frame = NSRect(x: padding, y: body.frame.maxY + 2, width: max(1, width - 2 * padding), height: 16)
    }

    func copyPlan() {
        do {
            try AgentConversationClipboard.write(flavors: ["text/plain": markdown], to: services.pasteboard)
            copyButton.image = AppIcon.check.image(size: 12, scale: AppIcon.inlineScale)
            copyReset?.cancel()
            copyReset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.copyButton.image = AppIcon.copy.image(size: 12, scale: AppIcon.inlineScale)
            }
        } catch { show(error.message, failure: true) }
    }

    func downloadPlan() async {
        let contents = markdown
        let name = AgentPlanExport.fileName(contents, date: services.now())
        guard let url = await services.chooseDownloadURL(name) else { return }
        do {
            try Data(contents.utf8).write(to: url, options: .atomic)
            show("Downloaded " + url.lastPathComponent, failure: false)
        } catch { show("The plan could not be downloaded: " + error.message, failure: true) }
    }

    func savePlan() async {
        let contents = markdown
        let path = AgentPlanExport.workspacePath(contents, date: services.now())
        guard let write = services.writeProjectFile else {
            show("Saving to the workspace is unavailable.", failure: true)
            return
        }
        do {
            let saved = try await write(path, contents, services.cwd)
            show("Saved to " + saved, failure: false)
        } catch { show("The plan could not be saved: " + error.message, failure: true) }
    }

    private func show(_ message: String, failure: Bool) {
        let wasHidden = feedback.isHidden
        feedbackText = message
        feedbackIsFailure = failure
        feedback.stringValue = message
        feedback.toolTip = message
        feedback.textColor = failure ? theme.danger : theme.fgDim
        feedback.isHidden = false
        feedback.setAccessibilityLabel(message)
        NSAccessibility.post(element: feedback, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        if wasHidden { onDisclosure?() }
    }

    override func captureState() -> AgentTimelineRowState {
        AgentTimelineRowState(responseState: body.captureState())
    }

    override func restoreState(_ state: AgentTimelineRowState) {
        if let response = state.responseState { body.restoreState(response) }
    }
}

// MARK: Todo

/// A todo list: one status glyph per step, completed steps struck through.
@MainActor
final class AgentTodoCardRow: AgentCardRow {
    private let icon: NSImageView
    private let title: NSTextField
    private let progress: NSTextField
    private let explanation = AgentRichTextView(frame: .zero)
    private let steps = AgentRichTextView(frame: .zero)
    private var explanationHeight: CGFloat = 0
    private var stepsHeight: CGFloat = 0
    private let padding: CGFloat = 14
    private let headerHeight: CGFloat = 40
    private(set) var list: AgentTodoList?

    override init(frame frameRect: NSRect) {
        icon = NSImageView()
        title = makeLabel("Todo", font: AppFont.header)
        progress = makeLabel("", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
        super.init(frame: frameRect)
        progress.alignment = .right
        for view in [icon, title, progress, explanation, steps] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var cardFill: NSColor? { theme.fg.withAlphaComponent(0.025) }
    override var cardBorder: NSColor? { theme.fg.withAlphaComponent(0.1) }

    /// Rendered list text, for tests and accessibility checks.
    var stepsText: NSAttributedString { steps.attributedString() }
    var progressText: String { progress.stringValue }

    override func render() {
        guard let item else { return }
        list = AgentTodoList(detail: item.detail)
        icon.image = AppIcon.listTodo.image(size: 15, scale: AppIcon.inlineScale, color: theme.fgDim)
        title.textColor = theme.fg
        progress.textColor = theme.fgDim
        progress.stringValue = list?.progress ?? ""
        progress.setAccessibilityLabel(list?.progress)
        explanation.isHidden = list?.explanation == nil
        explanation.setContent(AgentMarkdown.plain(list?.explanation ?? "", theme: theme, muted: true))
        steps.setContent(list.map { Self.stepsText($0, theme: theme) } ?? NSAttributedString())
        let selection: [NSAttributedString.Key: Any] = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        explanation.selectedTextAttributes = selection
        steps.selectedTextAttributes = selection
        needsDisplay = true
    }

    static func stepsText(_ list: AgentTodoList, theme: AppTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
        paragraph.headIndent = 24
        paragraph.paragraphSpacing = 6
        paragraph.lineSpacing = 3
        for (index, step) in list.steps.enumerated() {
            let glyph: AppIcon, color: NSColor, accessibility: String
            switch step.status {
            case .pending: (glyph, color, accessibility) = (.circle, theme.fgDim, "Pending")
            case .running: (glyph, color, accessibility) = (.spinner, theme.accent, "In progress")
            case .completed: (glyph, color, accessibility) = (.circleCheck, theme.diffAdd, "Completed")
            }
            let attachment = NSTextAttachment()
            attachment.image = glyph.image(size: 14, scale: AppIcon.inlineScale, color: color)?.tiffRepresentation.flatMap(NSImage.init(data:))
            attachment.image?.accessibilityDescription = accessibility
            attachment.bounds = NSRect(x: 0, y: -2, width: 14, height: 14)
            let line = NSMutableAttributedString(attachment: attachment)
            var attributes: [NSAttributedString.Key: Any] = [.font: AppFont.system(14), .foregroundColor: theme.fg, .paragraphStyle: paragraph]
            if step.status == .completed {
                attributes[.foregroundColor] = theme.fgDim
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attributes[.strikethroughColor] = theme.fgDim
            } else if step.status == .running {
                attributes[.font] = AppFont.system(14, weight: .medium)
            }
            line.append(NSAttributedString(string: "\t" + step.text, attributes: attributes))
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            if index < list.steps.count - 1 { line.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph])) }
            result.append(line)
        }
        return result
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat {
        let inner = max(1, width - 2 * padding)
        explanationHeight = explanation.isHidden ? 0 : explanation.height(for: inner)
        stepsHeight = (list?.steps.isEmpty ?? true) ? 0 : steps.height(for: inner)
        return headerHeight + (explanationHeight > 0 ? explanationHeight + 8 : 0) + stepsHeight + padding
    }

    override func layoutRow(width: CGFloat) {
        let inner = max(1, width - 2 * padding)
        icon.frame = NSRect(x: padding, y: 12, width: 16, height: 16)
        title.frame = NSRect(x: padding + 24, y: 11, width: 120, height: 18)
        progress.frame = NSRect(x: width - padding - 160, y: 12, width: 160, height: 16)
        explanation.frame = NSRect(x: padding, y: headerHeight, width: inner, height: explanationHeight)
        steps.frame = NSRect(x: padding, y: headerHeight + (explanationHeight > 0 ? explanationHeight + 8 : 0), width: inner, height: stepsHeight)
    }
}

// MARK: Compaction

/// A quiet boundary row; the summary is behind a disclosure.
@MainActor
final class AgentCompactionRow: AgentCardRow {
    var provider: AgentChatProvider? { didSet { if oldValue != provider { render() } } }
    let header = AgentToolHeader(frame: .zero)
    private let summary: AgentResponseView
    private var summaryHeight: CGFloat = 0
    private(set) var expanded = false
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        summary = AgentResponseView(frame: .zero)
        super.init(frame: frameRect)
        header.translatesAutoresizingMaskIntoConstraints = true
        header.font = AppFont.system(13)
        header.activityIcon = .foldVertical
        header.onPress = { [weak self] in
            guard let self else { return }
            self.expanded.toggle()
            self.render()
            self.onDisclosure?()
        }
        addSubview(header)
        summary.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
        summary.onOpenCitation = { [weak self] citation in self?.onOpenCitation?(citation) }
        summary.onHeightChanged = { [weak self] in self?.onDisclosure?() }
        summary.isHidden = true
        addSubview(summary)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var title: String { item.map { AgentCompactionPresentation.label($0, provider: provider) } ?? "" }
    private var summarySource: String { item?.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    override func render() {
        guard item != nil else { return }
        let hasSummary = !summarySource.isEmpty
        header.title = title
        header.isEnabled = hasSummary
        header.expanded = expanded && hasSummary
        header.labelColor = theme.fgDim
        header.iconColor = item?.workContext?.sourceStatus == "failed" ? AgentToolRowPresentation.failureIconColor(theme: theme) : theme.fgDim
        header.focusColor = theme.accent
        header.plateColor = theme.fg.withAlphaComponent(0.06)
        header.setAccessibilityLabel((hasSummary ? (expanded ? "Collapse " : "Expand ") : "") + title)
        header.needsDisplay = true
        summary.isHidden = !(expanded && hasSummary)
        if !summary.isHidden { summary.setContent(summarySource, theme: theme) }
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat {
        summaryHeight = summary.isHidden ? 0 : summary.height(for: max(1, width - 40))
        return 28 + (summaryHeight > 0 ? summaryHeight + 12 : 0)
    }

    override func layoutRow(width: CGFloat) {
        header.frame = NSRect(x: 0, y: 0, width: header.naturalWidth(maximum: width), height: 28)
        summary.frame = NSRect(x: 32, y: 32, width: max(1, width - 40), height: summaryHeight)
        summary.layoutSubtreeIfNeeded()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { header.hovered = true }
    override func mouseExited(with event: NSEvent) { header.hovered = false }

    override func captureState() -> AgentTimelineRowState { AgentTimelineRowState(expanded: expanded) }

    override func restoreState(_ state: AgentTimelineRowState) {
        guard expanded != state.expanded else { return }
        expanded = state.expanded
        render()
    }
}

// MARK: Error

/// A failed run: danger-tinted, never folded into completed work.
@MainActor
final class AgentErrorCardRow: AgentCardRow {
    private let icon: NSImageView
    private let title: NSTextField
    private let body = AgentRichTextView(frame: .zero)
    private var bodyHeight: CGFloat = 0
    private let padding: CGFloat = 12

    override init(frame frameRect: NSRect) {
        icon = NSImageView()
        title = makeLabel("Agent failed", font: AppFont.header)
        super.init(frame: frameRect)
        for view in [icon, title, body] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent failed")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var cardFill: NSColor? { theme.danger.withAlphaComponent(0.07) }
    override var cardBorder: NSColor? { theme.danger.withAlphaComponent(0.3) }

    var message: String { AgentErrorPresentation.message(item?.text ?? "") }
    var isMonospaced: Bool { AgentErrorPresentation.looksLikeStackTrace(message) }
    var bodyText: String { body.string }
    var bodyFont: NSFont? { body.textStorage?.length ?? 0 > 0 ? body.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil }

    override func render() {
        guard item != nil else { return }
        icon.image = AppIcon.triangleAlert.image(size: 15, scale: AppIcon.inlineScale, color: theme.danger)
        title.textColor = theme.danger
        body.setContent(AgentMarkdown.plain(message, theme: theme, monospaced: isMonospaced))
        body.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        needsDisplay = true
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat {
        bodyHeight = body.height(for: max(1, width - 2 * padding))
        return padding + 20 + 6 + bodyHeight + padding
    }

    override func layoutRow(width: CGFloat) {
        icon.frame = NSRect(x: padding, y: padding + 2, width: 16, height: 16)
        title.frame = NSRect(x: padding + 24, y: padding + 1, width: max(1, width - 2 * padding - 24), height: 18)
        body.frame = NSRect(x: padding, y: padding + 26, width: max(1, width - 2 * padding), height: bodyHeight)
    }
}

// MARK: Notice

/// An informational notice from the app or provider, quiet like the compaction row.
@MainActor
final class AgentNoticeRow: AgentCardRow {
    private let icon: NSImageView
    private let body = AgentRichTextView(frame: .zero)
    private var bodyHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        icon = NSImageView()
        super.init(frame: frameRect)
        for view in [icon, body] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func render() {
        guard let item else { return }
        icon.image = AppIcon.info.image(size: 16, scale: AppIcon.inlineScale, color: theme.fgDim)
        body.setContent(AgentMarkdown.plain(item.text, theme: theme, muted: true))
        body.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat {
        bodyHeight = body.height(for: max(1, width - 32))
        return max(24, bodyHeight + 4)
    }

    override func layoutRow(width: CGFloat) {
        icon.frame = NSRect(x: 6, y: 4, width: 16, height: 16)
        body.frame = NSRect(x: 32, y: 1, width: max(1, width - 32), height: bodyHeight)
    }
}
