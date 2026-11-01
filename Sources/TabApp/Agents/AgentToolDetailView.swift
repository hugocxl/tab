import AppKit
import TabProtocol

@MainActor
final class AgentToolDisclosure: NSView, NSTextViewDelegate {
    override var isFlipped: Bool { true }
    var fetchAttachment: AgentAttachmentCache.Fetch?
    var onPreviewAttachments: ((String, [AgentChatAttachmentDescriptor], Int) -> Void)?
    var onHeightChanged: (() -> Void)?
    private let images = AgentToolImagesView(frame: .zero)
    private let htmlCard = AgentHtmlDocumentCard(frame: .zero)
    private var htmlTitles: [String: String] = [:]
    private var htmlTitleTask: Task<Void, Never>?
    private var htmlTitleKey: String?
    /// Called when a button of the HTML document card is pressed.
    var onHTMLDocument: ((AgentHtmlDocumentCard.Action, AgentHtmlDocumentReference) -> Void)?
    /// Whether the card of the current item is showing.
    var showsHTMLDocument: Bool { !htmlCard.isHidden }
    var htmlDocumentCard: AgentHtmlDocumentCard { htmlCard }
    var onOpenFile: ((String, Int?) -> Void)?
    var workspaceRoot: String?
    var onOpenToolDiff: ((String, AgentToolActivity) -> Void)?
    var onDisclosure: (() -> Void)?
    private let header = AgentToolHeader(frame: .zero)
    private var hoverArea: NSTrackingArea?
    private let body = AgentRichTextView(frame: .zero)
    private let command = AgentRichTextView(frame: .zero)
    private let exitStatus = AgentRichTextView(frame: .zero)
    private let replArguments = AgentReplArguments(frame: .zero)
    private var usesReplArguments: Bool { usesArgumentPanel && AgentReplArguments.accepts(item?.tool) }
    private let argumentScroll = NSScrollView(frame: .zero)
    private var restoredArgumentPosition: NSPoint?
    var argumentScrollPosition: NSPoint { usesReplArguments ? replArguments.scrollPosition : restoredArgumentPosition ?? argumentScroll.contentView.bounds.origin }
    func restoreArgumentScrollPosition(_ position: NSPoint) { restoredArgumentPosition = position; replArguments.restoreScrollPosition(position) }
    private var scrollsArguments: Bool { usesArgumentPanel && AgentToolPresentation.argumentsNeedScroll(item?.tool?.input) }
    private let scroll = NSScrollView(frame: .zero)
    private let fileSearch = AgentFileSearchPanel(frame: .zero)
    private let fileChange = AgentFileChangePanel(frame: .zero)
    private let webSearch = AgentWebSearchPanel(frame: .zero)
    private var item: AgentChatItem?
    private var expanded = false
    var grouped = false { didSet { needsLayout = true } }
    private var headerHeight: CGFloat { grouped ? 24 : 28 }
    private var theme = AppTheme.shared
    private var restoredScrollPosition: NSPoint?
    private var bodyHeights: [CGFloat: CGFloat] = [:]
    private var usesArgumentPanel: Bool {
        guard let activity = item?.tool, !activity.presentsCommand else { return false }
        if activity.presentation == .dynamicTool { return true }
        return activity.presentation == nil && (activity.fileChanges ?? []).isEmpty
            && [.read, .search, .other].contains(activity.category ?? .other)
    }

    var outputScrollPosition: NSPoint {
        if item?.tool?.presentation == .fileChange { return fileChange.outputScrollPosition }
        return restoredScrollPosition ?? scroll.contentView.bounds.origin
    }
    func restoreOutputScrollPosition(_ position: NSPoint?) {
        restoredScrollPosition = position
        fileChange.restoreOutputScrollPosition(position)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        header.translatesAutoresizingMaskIntoConstraints = true
        header.alignment = .left
        header.font = AppFont.system(14)
        header.lineBreakMode = .byTruncatingTail
        header.imagePosition = .imageLeading
        header.imageScaling = .scaleProportionallyDown
        header.onPress = { [weak self] in
            guard let self else { return }
            self.onDisclosure?()
        }
        body.delegate = self
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = body
        addSubview(images)
        images.isHidden = true
        images.onHeightChanged = { [weak self] in self?.onHeightChanged?() }
        images.onPreview = { [weak self] item, attachments, index in self?.onPreviewAttachments?(item, attachments, index) }
        addSubview(header)
        addSubview(htmlCard)
        htmlCard.isHidden = true
        htmlCard.onAction = { [weak self] action in
            guard let reference = self?.htmlCard.reference else { return }
            self?.onHTMLDocument?(action, reference)
        }
        addSubview(scroll)
        argumentScroll.drawsBackground = false
        argumentScroll.hasVerticalScroller = true
        argumentScroll.autohidesScrollers = true
        argumentScroll.borderType = .noBorder
        argumentScroll.isHidden = true
        addSubview(argumentScroll)
        addSubview(replArguments)
        replArguments.isHidden = true
        addSubview(command)
        addSubview(exitStatus)
        addSubview(fileSearch)
        fileSearch.isHidden = true
        addSubview(fileChange)
        fileChange.isHidden = true
        fileChange.onOpenDiff = { [weak self] in
            guard let self, let item = self.item, let activity = item.tool else { return }
            self.onOpenToolDiff?(item.id, activity)
        }
        addSubview(webSearch)
        webSearch.isHidden = true
        webSearch.onOpenURL = { NSWorkspace.shared.open($0) }
        command.isHidden = true
        exitStatus.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { header.hovered = true }
    override func mouseExited(with event: NSEvent) { header.hovered = false }

    func update(_ item: AgentChatItem, expanded: Bool, theme: AppTheme) {
        guard self.item != item || self.theme !== theme || self.expanded != expanded else { return }
        self.item = item
        self.expanded = expanded
        refresh(theme: theme)
    }

    func refresh(theme: AppTheme) {
        self.theme = theme
        guard let item else { return }
        bodyHeights.removeAll(keepingCapacity: true)
        let activity = item.tool
        let status = activity?.status ?? (item.isComplete ? .completed : .running)
        let title = activity?.summary ?? String(item.text.prefix(240))
        let statusText = status.rawValue.capitalized
        switch activity?.category {
        case .command: header.activityIcon = .terminal
        case .read: header.activityIcon = .eye
        case .search: header.activityIcon = .search
        case .edit: header.activityIcon = .edit
        case .web: header.activityIcon = .globe
        case .subagent: header.activityIcon = .bot
        default: header.activityIcon = .wrench
        }
        let hasText = [item.detail, activity?.input, activity?.output].contains { $0?.isEmpty == false }
        header.isEnabled = hasText || activity?.exitCode != nil || !(activity?.filePaths ?? []).isEmpty
            || !(activity?.fileChanges ?? []).isEmpty || !(activity?.urls ?? []).isEmpty
            || (usesArgumentPanel && (item.attachments ?? []).contains { $0.mimeType.hasPrefix("image/") })
        header.expanded = expanded
        header.timestamp = activity?.startedAt
        header.timestampColor = theme.fgDim
        let indicatesFailure = AgentToolRowPresentation.indicatesFailure(activity, status: status)
        header.iconColor = indicatesFailure ? AgentToolRowPresentation.failureIconColor(theme: theme) : theme.fgDim
        header.focusColor = theme.accent
        header.title = title
        let skipped = AgentToolNonExecution.label(item.workContext?.toolNonExecutionKind)
        header.suffix = skipped
        header.labelColor = theme.fgMuted
        header.needsDisplay = true
        header.toolTip = ([([title, statusText, skipped].compactMap { $0 }).joined(separator: " · ")] + [header.timestampTooltip].compactMap { $0 }).joined(separator: "\n")
        let isFileSearch = activity?.presentation == .fileSearch
        fileSearch.isHidden = !expanded || !isFileSearch
        if isFileSearch {
            fileSearch.update(activity?.fileSearchDetails, root: workspaceRoot, theme: theme)
            header.isEnabled = fileSearch.hasContent
        }
        let isFileChange = activity?.presentation == .fileChange
        fileChange.isHidden = !expanded || !isFileChange
        if isFileChange, let activity {
            fileChange.update(activity, root: workspaceRoot, theme: theme)
            header.isEnabled = true
        }
        let isWebSearch = activity?.presentation == .webSearch
        webSearch.isHidden = !expanded || !isWebSearch
        if isWebSearch, let activity {
            webSearch.update(activity, theme: theme)
            header.isEnabled = webSearch.hasContent
        }
        header.setAccessibilityLabel((header.isEnabled ? (expanded ? "Collapse " : "Expand ") : "") + title + ", " + statusText
            + (skipped.map { ", " + $0 } ?? "") + (indicatesFailure ? ", tool call failed" : ""))
        scroll.isHidden = !expanded || isWebSearch || isFileChange || isFileSearch
        images.isHidden = !expanded || !usesArgumentPanel
        refreshHTMLDocument(item, status: status, theme: theme)
        images.fetch = fetchAttachment
        if expanded, usesArgumentPanel { images.update(item, theme: theme) }
        let isCommand = activity?.presentsCommand == true
        argumentScroll.isHidden = !expanded || !scrollsArguments
        if scrollsArguments {
            if command.superview !== argumentScroll.contentView { argumentScroll.documentView = command }
        } else if command.superview !== self {
            argumentScroll.documentView = nil
            addSubview(command)
        }
        replArguments.isHidden = !expanded || !usesReplArguments
        if usesReplArguments, let activity { replArguments.update(activity, theme: theme) }
        command.isHidden = !expanded || !(isCommand || usesArgumentPanel) || usesReplArguments
        exitStatus.isHidden = !expanded || !isCommand || activity?.exitCode == nil || activity?.exitCode == 0
        if expanded, isCommand, var activity {
            activity.status = status
            command.setContent(AgentCommandPresentation.source(activity, theme: theme))
            body.setContent(AgentCommandPresentation.output(activity, theme: theme))
            exitStatus.setContent(AgentCommandPresentation.text(exitStatus.isHidden ? "" : "exit \(activity.exitCode ?? 0)", color: .systemRed))
        } else if expanded, usesArgumentPanel {
            command.setContent(AgentToolPresentation.arguments(activity?.input, theme: theme))
            var presented = activity ?? AgentToolActivity()
            presented.status = status
            body.setContent(images.hasImages ? AgentToolPresentation.output(presented.output, isJSON: presented.outputIsJSON == true, theme: theme) : AgentToolPresentation.completedOutput(presented, theme: theme))
            exitStatus.setContent(AgentCommandPresentation.text("", color: theme.fgMuted))
        } else if expanded && !isWebSearch && !isFileChange && !isFileSearch { body.setContent(AgentToolText.content(item, theme: theme)) }
        body.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        command.selectedTextAttributes = body.selectedTextAttributes
        exitStatus.selectedTextAttributes = body.selectedTextAttributes
        needsLayout = true
    }

    /// Shows the card for a provider HTML document below the header, collapsed or expanded,
    /// so the document is visible without opening the tool call. The title is read once
    /// from the retained bytes.
    private func refreshHTMLDocument(_ item: AgentChatItem, status: AgentToolActivity.Status, theme: AppTheme) {
        let reference = usesArgumentPanel ? AgentHtmlDocumentReference.find(in: item) : nil
        guard let reference else {
            htmlTitleTask?.cancel(); htmlTitleTask = nil
            htmlCard.isHidden = true
            return
        }
        let available = item.isComplete && status == .completed && fetchAttachment != nil
        let key = reference.itemID + "/" + reference.attachmentID
        let cached = htmlTitles[key]
        htmlCard.isHidden = false
        htmlCard.update(reference, documentTitle: cached.flatMap { $0.isEmpty ? nil : $0 }, available: available, theme: theme)
        if htmlTitleKey != key { htmlTitleTask?.cancel(); htmlTitleTask = nil }
        guard available, cached == nil, htmlTitleTask == nil, let fetch = fetchAttachment,
              let attachment = item.attachments?.first(where: { $0.id == reference.attachmentID }) else { return }
        htmlTitleKey = key
        htmlTitleTask = Task { [weak self] in
            let data = try? await fetch(reference.itemID, attachment)
            guard !Task.isCancelled, let self else { return }
            self.htmlTitleTask = nil
            if self.htmlTitles.count >= 16 { self.htmlTitles.removeAll() }
            let title = data.flatMap { AgentHtmlDocumentReference.title(in: $0) }
            self.htmlTitles[key] = title ?? ""
            guard let title, self.htmlCard.reference == reference else { return }
            self.htmlCard.update(reference, documentTitle: title, available: self.htmlCard.isAvailable, theme: self.theme)
        }
    }

    func height(for width: CGFloat) -> CGFloat {
        guard expanded else { return headerHeight + (htmlCard.isHidden ? 0 : AgentHtmlDocumentCard.height + 8) }
        if item?.tool?.presentation == .fileSearch { return headerHeight + 16 + fileSearch.arrange(width: max(1, width - 4), apply: false) }
        if item?.tool?.presentation == .fileChange {
            fileChange.compactControls = (window?.contentView?.bounds.width ?? 640) >= 640
            return headerHeight + 16 + fileChange.arrange(width: max(1, width - 4), apply: false)
        }
        if item?.tool?.presentation == .webSearch { return headerHeight + 16 + webSearch.arrange(width: max(1, width - 4), apply: false) }
        if item?.tool?.presentsCommand == true || usesArgumentPanel {
            return commandLayout(width: width).height
        }
        return headerHeight + 10 + min(256, bodyHeight(for: max(1, width - 46)))
    }

    private func commandLayout(width: CGFloat) -> (card: NSRect, source: NSRect, images: NSRect, output: NSRect, exit: NSRect, height: CGFloat) {
        let width = max(1, width - 4)
        var y = headerHeight
        var card = NSRect(x: 2, y: y, width: width, height: 0)
        if !htmlCard.isHidden {
            card.size.height = AgentHtmlDocumentCard.height
            y = card.maxY
        }
        func frame(_ text: AgentRichTextView, limit: CGFloat = .greatestFiniteMagnitude) -> NSRect {
            guard !text.string.isEmpty else { return NSRect(x: 2, y: y, width: width, height: 0) }
            if y > headerHeight { y += 6 }
            let rounded = text.height(for: width)
            let measured = text.textContainer.flatMap { text.layoutManager?.usedRect(for: $0).maxY } ?? rounded
            let rect = NSRect(x: 2, y: y, width: width, height: min(limit, measured))
            y = rect.maxY
            return rect
        }
        let source: NSRect
        if usesReplArguments {
            source = NSRect(x: 2, y: y, width: width, height: replArguments.arrange(width: width, apply: false))
            y = source.maxY
        } else { source = frame(command, limit: scrollsArguments ? 320 : .greatestFiniteMagnitude) }
        var imageFrame = NSRect(x: 2, y: y, width: width, height: 0)
        if usesArgumentPanel && images.hasImages {
            if y > headerHeight { y += 6 }
            imageFrame = NSRect(x: 2, y: y, width: width, height: images.arrange(width: width, apply: false))
            y = imageFrame.maxY
        }
        let output = frame(body, limit: 320)
        let exit = frame(exitStatus)
        return (card, source, imageFrame, output, exit, y + 16)
    }

    private func bodyHeight(for width: CGFloat) -> CGFloat {
        if let height = bodyHeights[width] { return height }
        let height = body.height(for: width)
        if bodyHeights.count >= 4 { bodyHeights.removeAll(keepingCapacity: true) }
        bodyHeights[width] = height
        return height
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        if !expanded, !htmlCard.isHidden {
            htmlCard.frame = NSRect(x: 2, y: headerHeight, width: max(1, bounds.width - 4), height: AgentHtmlDocumentCard.height)
            htmlCard.layoutSubtreeIfNeeded()
            return
        }
        if expanded, item?.tool?.presentation == .fileSearch {
            fileSearch.frame = NSRect(x: 2, y: headerHeight, width: max(1, bounds.width - 4), height: max(0, bounds.height - headerHeight - 16))
            fileSearch.layoutSubtreeIfNeeded()
            return
        }
        if expanded, item?.tool?.presentation == .fileChange {
            fileChange.frame = NSRect(x: 2, y: headerHeight, width: max(1, bounds.width - 4), height: max(0, bounds.height - headerHeight - 16))
            fileChange.layoutSubtreeIfNeeded()
            return
        }
        if expanded, item?.tool?.presentation == .webSearch {
            webSearch.frame = NSRect(x: 2, y: headerHeight, width: max(1, bounds.width - 4), height: max(0, bounds.height - headerHeight - 16))
            webSearch.layoutSubtreeIfNeeded()
            return
        }
        if expanded {
            let follow = scroll.contentView.bounds.maxY >= body.bounds.height - 8
            if item?.tool?.presentsCommand == true || usesArgumentPanel {
                let frames = commandLayout(width: bounds.width)
                if usesReplArguments {
                    replArguments.frame = frames.source
                    replArguments.layoutSubtreeIfNeeded()
                } else if scrollsArguments {
                    argumentScroll.frame = frames.source
                    let contentWidth = max(1, argumentScroll.contentSize.width)
                    command.frame = NSRect(x: 0, y: 0, width: contentWidth, height: command.height(for: contentWidth))
                    if let position = restoredArgumentPosition {
                        command.scroll(NSPoint(x: 0, y: min(max(0, position.y), max(0, command.frame.height - argumentScroll.contentSize.height))))
                        restoredArgumentPosition = nil
                    }
                } else { command.frame = frames.source }
                htmlCard.frame = frames.card
                htmlCard.layoutSubtreeIfNeeded()
                images.frame = frames.images
                images.layoutSubtreeIfNeeded()
                scroll.frame = frames.output
                exitStatus.frame = frames.exit
            } else {
                scroll.frame = NSRect(x: 26, y: headerHeight + 4, width: max(1, bounds.width - 32), height: max(1, bounds.height - headerHeight - 10))
            }
            let width = max(1, scroll.contentSize.width)
            body.frame = NSRect(x: 0, y: 0, width: width, height: bodyHeight(for: width))
            if let position = restoredScrollPosition {
                body.scroll(NSPoint(x: 0, y: min(position.y, max(0, body.bounds.height - scroll.contentSize.height))))
                restoredScrollPosition = nil
            } else if follow, item?.tool?.presentsCommand == true {
                body.scroll(NSPoint(x: 0, y: max(0, body.bounds.height - scroll.contentSize.height)))
            }
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return true }
        if url.scheme == "agent-file", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let path = components.queryItems?.first(where: { $0.name == "path" })?.value {
            let line = components.queryItems?.first(where: { $0.name == "line" })?.value.flatMap(Int.init)
            onOpenFile?(path, line)
        } else if url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
        }
        return true
    }
}

/// Kept separate from views so output, diff colors and safe link targets are directly testable.
@MainActor
enum AgentToolText {
    static func content(_ item: AgentChatItem, theme: AppTheme) -> NSAttributedString {
        let activity = item.tool
        // Reasoning is prose that streams into one row, not tool output.
        if activity == nil, item.workContext?.itemType == "reasoning" {
            return AgentMarkdown.plain(bounded(item.detail ?? item.text), theme: theme, muted: true)
        }
        let result = NSMutableAttributedString(string: "")
        func heading(_ text: String) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(NSAttributedString(string: text + "\n", attributes: [.font: AppFont.system(11, weight: .semibold), .foregroundColor: theme.fgDim]))
        }
        if let input = activity?.input, !input.isEmpty {
            heading(activity?.presentsCommand == true ? "Command" : "Input")
            result.append(AgentMarkdown.plain(readableInput(input), theme: theme, monospaced: true))
        }
        for change in activity?.fileChanges ?? [] {
            heading(change.path)
            if let diff = change.diff {
                let displayed = change.kind == "add" && !diff.hasPrefix("+")
                    ? diff.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n") : diff
                result.append(diffText(displayed, theme: theme))
            }
        }
        if let output = activity?.output ?? (activity == nil ? item.detail : nil), !output.isEmpty {
            heading("Output")
            result.append(terminalText(output, theme: theme, terminal: activity?.presentsCommand == true))
        }
        if let code = activity?.exitCode {
            heading("Exit code: \(code)")
        }
        for path in activity?.filePaths ?? [] where !(activity?.fileChanges?.contains(where: { $0.path == path }) ?? false) {
            heading(path)
        }
        for url in activity?.urls ?? [] { heading(url) }
        if result.length == 0 { result.append(AgentMarkdown.plain(item.detail ?? "No output", theme: theme, muted: true, monospaced: true)) }
        addLinks(to: result, paths: activity?.filePaths ?? [], theme: theme)
        return result
    }

    static func readableInput(_ input: String) -> String {
        guard let data = input.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return bounded(input) }
        if let files = object as? [[String: Any]] {
            return bounded(files.map { file in
                let path = file["path"] as? String ?? "File"
                let kind = (file["kind"] as? [String: Any])?["type"] as? String
                return path + (kind.map { " · " + $0 } ?? "")
            }.joined(separator: "\n"))
        }
        guard let fields = object as? [String: Any] else { return bounded(input) }
        return bounded(fields.keys.sorted().map { key in
            let value = fields[key]
            let text = value as? String ?? value.map { String(describing: $0) } ?? ""
            return key.replacingOccurrences(of: "_", with: " ").capitalized + ": " + text
        }.joined(separator: "\n"))
    }

    static func diffText(_ diff: String, theme: AppTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for line in bounded(diff).components(separatedBy: "\n") {
            let color: NSColor = line.hasPrefix("+") && !line.hasPrefix("+++") ? .systemGreen
                : line.hasPrefix("-") && !line.hasPrefix("---") ? .systemRed : theme.fgMuted
            result.append(NSAttributedString(string: line + "\n", attributes: [.font: AppFont.mono(12), .foregroundColor: color]))
        }
        return result
    }

    static func terminalText(_ source: String, theme: AppTheme, terminal: Bool) -> NSAttributedString {
        // A carriage return overwrites the current progress line, as in the source renderer's command fixture.
        let source = bounded(source).components(separatedBy: "\n").map {
            $0.components(separatedBy: "\r").last ?? ""
        }.joined(separator: "\n")
        let result = NSMutableAttributedString(string: "")
        let expression = try? NSRegularExpression(pattern: "\u{1b}\\[[0-9;]*[A-Za-z]")
        let ns = source as NSString
        var offset = 0
        var color = theme.fg
        let palette: [Int: NSColor] = [30: .black, 31: .systemRed, 32: .systemGreen, 33: .systemYellow,
                                      34: .systemBlue, 35: .systemPurple, 36: .systemTeal, 37: .white]
        func append(_ range: NSRange) {
            guard range.length > 0 else { return }
            var attributes: [NSAttributedString.Key: Any] = [.font: AppFont.mono(12), .foregroundColor: color]
            if terminal { attributes[.backgroundColor] = theme.fg.withAlphaComponent(0.045) }
            result.append(NSAttributedString(string: ns.substring(with: range), attributes: attributes))
        }
        for match in expression?.matches(in: source, range: NSRange(location: 0, length: ns.length)) ?? [] {
            append(NSRange(location: offset, length: match.range.location - offset))
            let escape = ns.substring(with: match.range)
            if escape.hasSuffix("m") {
                for code in escape.dropFirst(2).dropLast().split(separator: ";").compactMap({ Int($0) }) {
                    if code == 0 || code == 39 { color = theme.fg }
                    else if let next = palette[code] ?? palette[code - 60] { color = next }
                }
            }
            offset = NSMaxRange(match.range)
        }
        append(NSRange(location: offset, length: ns.length - offset))
        return result
    }

    private static func bounded(_ text: String) -> String {
        text.count > 32_000 ? "[Earlier output omitted from preview]\n" + String(text.suffix(32_000)) : text
    }

    private static func addLinks(to text: NSMutableAttributedString, paths: [String], theme: AppTheme) {
        let ns = text.string as NSString
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector?.matches(in: text.string, range: NSRange(location: 0, length: text.length)) ?? [] {
            guard let url = match.url, ["http", "https"].contains(url.scheme ?? "") else { continue }
            text.addAttributes([.link: url, .foregroundColor: theme.accent], range: match.range)
        }
        for path in Set(paths) where !path.isEmpty {
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let range = ns.range(of: path, range: search)
                guard range.location != NSNotFound else { break }
                var components = URLComponents()
                components.scheme = "agent-file"
                components.queryItems = [URLQueryItem(name: "path", value: path)]
                let suffix = ns.substring(from: NSMaxRange(range))
                if suffix.hasPrefix(":"), let line = Int(suffix.dropFirst().prefix(while: \.isNumber)), line > 0 {
                    components.queryItems?.append(URLQueryItem(name: "line", value: String(line)))
                }
                if let url = components.url { text.addAttributes([.link: url, .foregroundColor: theme.accent], range: range) }
                search = NSRange(location: NSMaxRange(range), length: ns.length - NSMaxRange(range))
            }
        }
    }
}

/// Ordinary tool failures keep the source label quiet and mark the category icon.
/// Provider error/result flags have already been normalized into the lifecycle status.
@MainActor
enum AgentToolRowPresentation {
    static func indicatesFailure(_ activity: AgentToolActivity?, status: AgentToolActivity.Status) -> Bool {
        if status == .failed || status == .denied { return true }
        return activity?.presentsCommand == true && (activity?.exitCode ?? 0) != 0
    }

    static func failureIconColor(theme: AppTheme) -> NSColor {
        theme.danger.withAlphaComponent(theme.danger.alphaComponent * 0.28)
    }
}
