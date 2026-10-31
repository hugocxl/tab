import AppKit
import TabCore

/// Native assistant response surface. Completed text/code/table sections retain their view and
/// selection while the final section grows; file links are delegated to the owning project pane.
@MainActor
final class AgentResponseView: NSView, NSTextViewDelegate {
    override func hitTest(_ point: NSPoint) -> NSView? {
        AgentTableCopyHitTesting.hitTest(point, in: self) ?? super.hitTest(point)
    }

    var onRunShellCommand: ((String) -> Void)? { didSet { updateCommandAvailability() } }
    var isStreaming = false { didSet { if oldValue != isStreaming { updateCommandAvailability() } } }
    var onOpenFile: ((String, Int?) -> Void)?
    var onOpenFragment: ((String) -> Bool)?
    var onReveal: (() -> Void)?
    /// Frame-measured transcript owners should remeasure their row when wrap controls change.
    var onHeightChanged: (() -> Void)?
    var compactProse = false { didSet { if oldValue != compactProse { source = nil } } }
    var inheritedReferences: [String: String] = [:] { didSet { if oldValue != inheritedReferences { source = nil } } }
    var lineBreaks = false { didSet { if oldValue != lineBreaks { source = nil } } }
    var parseRawHTML = true { didSet { if oldValue != parseRawHTML { source = nil } } }
    private var preparedBlocks: [AgentMarkdown.Block]?
    private var source: String?
    private var palette: ChromePalette?
    private var scheme: ColorScheme?
    private var sections: [AgentResponseSection] = []
    private var sectionGaps: [CGFloat] = []
    private var leadingBlockMargin: CGFloat = 0
    private var trailingBlockMargin: CGFloat = 0
    private var measuredWidth: CGFloat = 0
    private var retiredUpdateCount = 0
    private var retiredMeasurementCount = 0
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Section indices are stable across append-only streaming. Restore after `setContent`;
    /// restoration invalidates measurements silently, without invoking `onHeightChanged`.
    var wrappedCodeSections: Set<Int> {
        get {
            Set(sections.indices.filter { (sections[$0] as? AgentResponseCode)?.wrapped == true })
        }
        set {
            var changed = false
            for index in sections.indices {
                if let code = sections[index] as? AgentResponseCode,
                   code.setWrapped(newValue.contains(index)) { changed = true }
            }
            if changed {
                needsLayout = true
                invalidateIntrinsicContentSize()
            }
        }
    }

    func captureState() -> AgentResponseState {
        AgentResponseState(children: Dictionary(uniqueKeysWithValues: sections.enumerated().map { ($0.offset, $0.element.captureState()) }))
    }

    func restoreState(_ state: AgentResponseState) {
        for (index, child) in state.children where sections.indices.contains(index) { sections[index].restoreState(child) }
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    /// Cumulative actual work counters, including sections replaced during this view's lifetime.
    var sectionUpdateCount: Int { retiredUpdateCount + sections.reduce(0) { $0 + $1.updateCount } }
    var sectionMeasurementCount: Int { retiredMeasurementCount + sections.reduce(0) { $0 + $1.measurementCount } }

    func setContent(_ source: String, theme: AppTheme) {
        let themeChanged = palette != theme.palette || scheme != theme.scheme
        guard self.source != source || themeChanged else { return }
        self.source = source
        preparedBlocks = nil
        palette = theme.palette
        scheme = theme.scheme
        let blocks = AgentResponseParser.parse(source, parseRawHTML: parseRawHTML)
        let references = inheritedReferences.merging(AgentMarkdownReferences.collect(blocks, parseRawHTML: parseRawHTML)) { inherited, _ in inherited }
        applyBlocks(AgentMarkdownFootnotes.prepare(blocks, parseRawHTML: parseRawHTML), references: references, theme: theme)
    }

    func setPreparedContent(_ blocks: [AgentMarkdown.Block], theme: AppTheme) {
        guard preparedBlocks != blocks || palette != theme.palette || scheme != theme.scheme || source == nil else { return }
        preparedBlocks = blocks
        source = ""
        palette = theme.palette
        scheme = theme.scheme
        applyBlocks(blocks, references: inheritedReferences, theme: theme)
    }

    private func applyBlocks(_ blocks: [AgentMarkdown.Block], references: [String: String], theme: AppTheme) {
        let parts = AgentResponsePart.partition(blocks, compact: compactProse, parseRawHTML: parseRawHTML)
        leadingBlockMargin = parts.first?.outerMargin(first: true) ?? 0
        trailingBlockMargin = parts.last?.outerMargin(first: false) ?? 0
        sectionGaps = parts.indices.map { index in
            index == 0 ? 0 : parts[index].gap(after: parts[index - 1], compact: compactProse)
        }
        for index in parts.indices {
            let part = parts[index]
            let section: AgentResponseSection
            if sections.indices.contains(index), sections[index].kind == part.kind {
                section = sections[index]
            } else {
                switch part {
                case .prose: section = AgentResponseProse()
                case .code: section = AgentResponseCode()
                case .table: section = AgentResponseTable()
                case .container, .nested: section = AgentResponseContainer()
                case .footnotes: section = AgentResponseFootnotes()
                case .divider: section = AgentResponseDivider()
                }
                if sections.indices.contains(index) {
                    retire(sections[index])
                    sections[index].removeFromSuperview()
                    sections[index] = section
                } else { sections.append(section) }
                addSubview(section)
            }
            section.onHeightChanged = { [weak self] in
                guard let self else { return }
                self.needsLayout = true
                self.invalidateIntrinsicContentSize()
                self.onHeightChanged?()
            }
            if let container = section as? AgentResponseContainer {
                container.response.compactProse = compactProse
                container.response.lineBreaks = lineBreaks
                container.response.parseRawHTML = parseRawHTML
                container.response.inheritedReferences = references
                container.response.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
                container.response.onOpenFragment = { [weak self] id in self?.openFragment(id) ?? false }
            }
            if let notes = section as? AgentResponseFootnotes {
                notes.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
                notes.onOpenFragment = { [weak self] id in self?.openFragment(id) ?? false }
            }
            section.apply(part, theme: theme, delegate: self, references: references, compactProse: compactProse, lineBreaks: lineBreaks)
        }
        while sections.count > parts.count {
            let section = sections.removeLast()
            retire(section)
            section.removeFromSuperview()
        }
        updateCommandAvailability()
        measuredWidth = 0
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    private func updateCommandAvailability() {
        for section in sections {
            if let code = section as? AgentResponseCode {
                code.isStreaming = isStreaming
                code.onRunShellCommand = onRunShellCommand
            } else if let container = section as? AgentResponseContainer {
                container.response.isStreaming = isStreaming
                container.response.onRunShellCommand = onRunShellCommand
            } else if let notes = section as? AgentResponseFootnotes {
                notes.isStreaming = isStreaming
                notes.onRunShellCommand = onRunShellCommand
            }
        }
    }

    func height(for width: CGFloat) -> CGFloat {
        measuredWidth = max(1, width)
        var y = leadingBlockMargin
        for (index, section) in sections.enumerated() {
            if index > 0 { y += sectionGaps[index] }
            let height = section.measuredHeight(for: measuredWidth)
            section.place(in: NSRect(x: 0, y: y, width: measuredWidth, height: height))
            y += height
        }
        y += trailingBlockMargin
        return y
    }

    private func retire(_ section: AgentResponseSection) {
        retiredUpdateCount += section.updateCount
        retiredMeasurementCount += section.measurementCount
    }

    override func layout() {
        _ = height(for: bounds.width)
        super.layout()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(for: max(1, bounds.width)))
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let raw = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        guard let target = AgentResponseLink.parse(raw) else { return true }
        switch target {
        case .fragment(let id):
            _ = openFragment(id)
            return true
        case .file(let path, let line):
            onOpenFile?(path, line)
            return true
        case .external:
            return false // AppKit opens normal web/mail links; no arbitrary schemes are forwarded.
        }
    }

    var headingTargets: [AgentMarkdownHeadingTarget] {
        sections.flatMap { section in
            if let prose = section as? AgentResponseProse { return AgentMarkdownHeadingTarget.collect(in: prose.text) }
            if let container = section as? AgentResponseContainer { return container.response.headingTargets }
            if let notes = section as? AgentResponseFootnotes { return notes.headingTargets }
            if let table = section as? AgentResponseTable { return table.headingTargets }
            return []
        }
    }

    @discardableResult
    func openFragment(_ id: String) -> Bool {
        if let onOpenFragment { return onOpenFragment(id) }
        guard let target = AgentMarkdownFragments.target(id, in: headingTargets) else { return false }
        onReveal?()
        var ancestors: [AgentResponseContainer] = []
        var ancestor = target.text.superview
        while let view = ancestor, view !== self {
            if let container = view as? AgentResponseContainer { ancestors.append(container) }
            ancestor = view.superview
        }
        for container in ancestors.reversed() { container.reveal() }
        superview?.layoutSubtreeIfNeeded()
        guard let layout = target.text.layoutManager, let textContainer = target.text.textContainer else { return true }
        layout.ensureLayout(for: textContainer)
        let glyphs = layout.glyphRange(forCharacterRange: target.range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += target.text.textContainerOrigin.x
        rect.origin.y += target.text.textContainerOrigin.y
        if let scroll = enclosingScrollView, let document = scroll.documentView {
            let point = document.convert(rect.origin, from: target.text)
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: min(maximum, max(0, point.y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else { target.text.scrollToVisible(rect) }
        return true
    }
}

enum AgentResponsePart: Equatable {
    enum Container: Equatable {
        case quote
        case alert(String)
        case list(String, Int, indent: CGFloat? = nil, structure: AgentListItemStructure? = nil)
        case details(String, Bool)
    }
    case container(Container, String)
    case nested(Container, [AgentMarkdown.Block])
    case footnotes([AgentMarkdownFootnote])
    case divider
    case prose([AgentMarkdown.Block], listIndents: [Int: CGFloat] = [:])
    case code(String, String, closed: Bool = true)
    case table([String], [[String]], [AgentMarkdown.TableAlignment])

    var kind: Int {
        switch self { case .prose: return 0; case .code: return 1; case .table: return 2; case .container, .nested: return 3; case .footnotes: return 4; case .divider: return 5 }
    }

    private func edgeListItem(first: Bool) -> (depth: Int, structure: AgentListItemStructure?)? {
        switch self {
        case .prose(let blocks, _):
            guard let block = first ? blocks.first : blocks.last else { return nil }
            if case .list(_, _, let depth, let structure) = block { return (depth, structure) }
            return nil
        case .container(.list(_, let depth, _, let structure), _), .nested(.list(_, let depth, _, let structure), _):
            return (depth, structure)
        default: return nil
        }
    }

    func outerMargin(first: Bool) -> CGFloat {
        if case .table = self { return AgentMarkdownLayout.blockGap }
        return edgeListItem(first: first)?.structure?.isLoose == true ? AgentMarkdownLayout.blockGap : 0
    }

    func gap(after previous: Self, compact: Bool) -> CGFloat {
        if case .footnotes = self { return 20 }
        if let item = edgeListItem(first: true), let preceding = previous.edgeListItem(first: false),
           let structure = item.structure, let precedingStructure = preceding.structure,
           structure.id == precedingStructure.id, item.depth == preceding.depth,
           !structure.isLoose {
            return compact ? AgentMarkdownLayout.compactListGap : 4
        }
        return AgentMarkdownLayout.blockGap
    }

    @MainActor
    static func partition(_ blocks: [AgentMarkdown.Block], compact: Bool = false, parseRawHTML: Bool = true) -> [Self] {
        let indents = AgentListLayout.indents(blocks, font: AppFont.system(compact ? 12 : 14))
        var proseIndents: [Int: CGFloat] = [:]
        var result: [Self] = []
        var prose: [AgentMarkdown.Block] = []
        func flush() {
            if !prose.isEmpty { result.append(.prose(prose, listIndents: proseIndents)); prose.removeAll(keepingCapacity: true); proseIndents.removeAll(keepingCapacity: true) }
        }
        for (index, block) in blocks.enumerated() {
            switch block {
            case .reference, .footnoteDefinition: continue
            case .nested(.list(let marker, let depth, _, let structure), let blocks):
                flush(); result.append(.nested(.list(marker, depth, indent: indents[index], structure: structure), blocks))
            case .nested(let kind, let blocks): flush(); result.append(.nested(kind, blocks))
            case .footnotes(let notes): flush(); result.append(.footnotes(notes))
            case .divider: flush(); result.append(.divider)
            case .quote(let source):
                flush()
                let input = AgentMarkdownSource(source)
                let lines = input.lines
                let first = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
                let labels = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]
                if let label = labels.first(where: { first.uppercased() == "[!" + $0 + "]" }) {
                    result.append(.container(.alert(label.capitalized), input.join(Array(lines.dropFirst()), startingAt: 1)))
                } else { result.append(.container(.quote, source)) }
            case .listBlock(let marker, let source, let depth, let structure):
                flush()
                let ancestors = (structure?.ancestors ?? []) + [structure?.start != nil]
                result.append(.nested(.list(marker, depth, indent: indents[index], structure: structure), AgentResponseParser.parse(source, parseRawHTML: parseRawHTML, listAncestors: ancestors)))
            case .details(let title, let source, let open): flush(); result.append(.container(.details(title, open), source))
            case .code(let info, let source, let closed): flush(); result.append(.code(info, source, closed: closed))
            case .table(let headers, let rows, let alignments): flush(); result.append(.table(headers, rows, alignments))
            default:
                if let indent = indents[index] { proseIndents[prose.count] = indent }
                prose.append(block)
            }
        }
        flush()
        return result
    }
}

@MainActor
class AgentResponseSection: NSView {
    var onHeightChanged: (() -> Void)?
    private(set) var lineBreaks = false
    private(set) var compactProse = false
    private(set) var references: [String: String] = [:]
    private var part: AgentResponsePart?
    private var palette: ChromePalette?
    private var scheme: ColorScheme?
    private var measurementWidth: CGFloat?
    private var measurementHeight: CGFloat = 0
    private var childLayoutDirty = true
    private(set) var updateCount = 0
    private(set) var measurementCount = 0
    override var isFlipped: Bool { true }
    var kind: Int { -1 }

    final func apply(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate, references: [String: String] = [:], compactProse: Bool = false, lineBreaks: Bool = false) {
        guard self.part != part || palette != theme.palette || scheme != theme.scheme || self.references != references || self.compactProse != compactProse || self.lineBreaks != lineBreaks else { return }
        self.lineBreaks = lineBreaks
        self.compactProse = compactProse
        self.references = references
        self.part = part
        palette = theme.palette
        scheme = theme.scheme
        updateCount += 1
        invalidateMeasurement()
        update(part, theme: theme, delegate: delegate)
    }

    final func invalidateMeasurement() {
        measurementWidth = nil
        childLayoutDirty = true
        needsLayout = true
    }

    final func measuredHeight(for width: CGFloat) -> CGFloat {
        let width = max(1, width)
        if measurementWidth == width { return measurementHeight }
        measurementCount += 1
        measurementHeight = height(for: width)
        measurementWidth = width
        childLayoutDirty = true
        return measurementHeight
    }

    final func place(in rect: NSRect) {
        if frame != rect { frame = rect }
        if childLayoutDirty {
            layoutSection(width: rect.width)
            childLayoutDirty = false
        }
    }

    override func layout() {
        _ = measuredHeight(for: bounds.width)
        if childLayoutDirty {
            layoutSection(width: bounds.width)
            childLayoutDirty = false
        }
        super.layout()
    }

    func captureState() -> AgentResponseState { AgentResponseState() }
    func restoreState(_ state: AgentResponseState) {}
    func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {}
    func height(for width: CGFloat) -> CGFloat { 0 }
    func layoutSection(width: CGFloat) {}
}

@MainActor
private final class AgentResponseProse: AgentResponseSection {
    override var kind: Int { 0 }
    let text = AgentRichTextView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = false
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        guard case .prose(let blocks, let listIndents) = part else { return }
        text.delegate = delegate
        text.setContent(AgentMarkdown.render(blocks, theme: theme, fileLinks: true, references: references, compact: compactProse, lineBreaks: lineBreaks, listIndents: listIndents))
        text.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        text.linkTextAttributes = [:] // Inline spans already carry their own link or code color.
    }

    override func height(for width: CGFloat) -> CGFloat { text.height(for: width) }
    override func layoutSection(width: CGFloat) {
        let drawnWidth = text.layoutManager.flatMap { manager in text.textContainer.map { manager.usedRect(for: $0).maxX } } ?? width
        let prefixWidth = AgentExternalLinkLayout.minimumPrefixWidth(text.attributedString())
        text.frame = NSRect(x: 0, y: 0, width: max(width, ceil(drawnWidth), ceil(prefixWidth)), height: bounds.height)
    }
}

/// A real independently scrollable code block, not a paragraph with a shaded background.
@MainActor
final class AgentResponseCode: AgentResponseSection {
    override var kind: Int { 1 }
    let text = AgentRichTextView(frame: .zero)
    let scroll = NSScrollView()
    let copy = PillButton("", style: .plain)
    let wrap = PillButton("", style: .plain)
    let run = PillButton("", style: .plain)
    var onRunShellCommand: ((String) -> Void)? { didSet { refreshRunAction() } }
    var isStreaming = false { didSet { if oldValue != isStreaming { refreshRunAction() } } }
    private var fenceLanguage = ""
    private var fenceClosed = false
    private var copyReset: Task<Void, Never>?
    private var controlColor: NSColor = .secondaryLabelColor
    private var wrapBackground: NSColor = .clear
    private let titleLabel = makeLabel("", font: AppFont.mono(11))
    private let fileIcon = NSImageView()
    private var highlighter: SyntaxHighlighter?
    private(set) var code = ""
    private(set) var language = SyntaxLanguage.plain
    private(set) var wrapped = true
    private var documentWidth: CGFloat = 0
    private var documentHeight: CGFloat = 0
    private var longestCodeWidth: CGFloat?
    private var longestWidthFont: NSFont?
    private(set) var longestLineScanCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = text
        text.autoresizingMask = []
        text.isHorizontallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        for child in [scroll, titleLabel, fileIcon, wrap, run, copy] {
            child.translatesAutoresizingMaskIntoConstraints = true
            addSubview(child)
        }
        titleLabel.lineBreakMode = .byTruncatingTail
        wrap.font = AppFont.footnote
        copy.font = AppFont.footnote
        for button in [wrap, run, copy] {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
        }
        wrap.image = AgentConversationIcon.wrap.image()
        run.image = AgentConversationIcon.play.image()
        run.toolTip = "Run in terminal"
        run.setAccessibilityLabel("Run in terminal")
        run.isHidden = true
        run.onPress = { [weak self] in
            guard let self, let command = self.runnableCommand else { return }
            self.onRunShellCommand?(command)
        }
        refreshWrapAction()
        resetCopyAction()
        copy.onPress = { [weak self] in self?.copyCode() }
        wrap.onPress = { [weak self] in
            guard let self else { return }
            self.setWrapped(!self.wrapped)
            self.superview?.needsLayout = true
            self.superview?.invalidateIntrinsicContentSize()
            // The owning row is frame-measured; ask its view tree to reconsider its height too.
            self.window?.contentView?.needsLayout = true
            self.onHeightChanged?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func captureState() -> AgentResponseState { AgentResponseState(wrapped: wrapped) }
    override func restoreState(_ state: AgentResponseState) { if let wrapped = state.wrapped { setWrapped(wrapped) } }

    /// Silent state restoration; only the actual wrap button action invokes `onHeightChanged`.
    @discardableResult
    func setWrapped(_ value: Bool) -> Bool {
        guard wrapped != value else { return false }
        wrapped = value
        refreshWrapAction()
        scroll.contentView.scroll(to: .zero)
        invalidateMeasurement()
        return true
    }

    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        guard case .code(let info, let source, let closed) = part else { return }
        let metadata = AgentCodeFenceInfo(info)
        fenceLanguage = metadata.language
        fenceClosed = closed
        let iconPath = metadata.title ?? AgentFileIcon.syntheticFileName(language: metadata.language)
        fileIcon.isHidden = metadata.title == nil && !AgentFileIcon.hasSpecificIcon(for: iconPath)
        fileIcon.image = fileIcon.isHidden ? nil : AgentFileIcon.image(for: iconPath, dark: !theme.palette.isLight)
        fileIcon.toolTip = metadata.title == nil ? metadata.language : nil
        fileIcon.setAccessibilityElement(metadata.title == nil && !fileIcon.isHidden)
        fileIcon.setAccessibilityLabel(metadata.title == nil ? "Language: \(metadata.language)" : metadata.title)
        titleLabel.stringValue = metadata.title ?? (fileIcon.isHidden ? (metadata.language.isEmpty ? "text" : metadata.language) : "")
        titleLabel.toolTip = metadata.language
        titleLabel.textColor = theme.fgMuted
        let nextLanguage = Self.syntaxLanguage(metadata.language)
        if highlighter == nil || nextLanguage != language {
            language = nextLanguage
            highlighter = SyntaxHighlighter(language: language)
            highlighter?.setText(source)
        } else if source != code {
            if source.hasPrefix(code) {
                let oldLength = code.utf16.count
                let delta = source.utf16.count - oldLength
                highlighter?.update(source, editedRange: NSRange(location: oldLength, length: delta), changeInLength: delta)
            } else { highlighter?.setText(source) }
        }
        if code != source {
            copyReset?.cancel()
            resetCopyAction()
            longestCodeWidth = nil
        }
        code = source
        refreshRunAction()
        controlColor = theme.fgMuted
        wrapBackground = theme.fg.withAlphaComponent(0.08)
        for button in [wrap, run, copy] { button.contentTintColor = controlColor }
        refreshWrapAction()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 17.875
        paragraph.maximumLineHeight = 17.875
        paragraph.lineBreakMode = .byWordWrapping
        let content = NSMutableAttributedString(string: source, attributes: [
            .font: AppFont.mono(13), .foregroundColor: theme.fg, .paragraphStyle: paragraph,
        ])
        for token in highlighter?.tokens ?? [] where NSMaxRange(token.range) <= content.length {
            content.addAttributes(theme.syntaxColors.attributes(token.kind, font: AppFont.mono(13)), range: token.range)
        }
        text.setContent(content)
        text.delegate = delegate
        text.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        layer?.backgroundColor = theme.fg.withAlphaComponent(0.04).cgColor
        layer?.borderColor = theme.border.withAlphaComponent(0.65).cgColor
    }

    override func height(for width: CGFloat) -> CGFloat {
        let available = max(1, width - 30.8)
        let font = AppFont.mono(13)
        if longestCodeWidth == nil || longestWidthFont != font {
            longestLineScanCount += 1
            longestCodeWidth = AgentMarkdownSource(code).lines.reduce(CGFloat.zero) { longest, line in
                max(longest, (line as NSString).size(withAttributes: [.font: font]).width)
            }
            longestWidthFont = font
        }
        let longest = longestCodeWidth ?? 0
        documentWidth = wrapped ? available : max(available, ceil(longest) + 2)
        documentHeight = text.height(for: documentWidth)
        if code.hasSuffix("\n"), let manager = text.layoutManager, manager.extraLineFragmentTextContainer != nil {
            documentHeight = min(documentHeight, manager.extraLineFragmentRect.minY)
        }
        documentHeight = max(17.875, documentHeight)
        return 57.6 + documentHeight + (documentWidth > available ? 10 : 0)
    }

    override func layoutSection(width: CGFloat) {
        let side: CGFloat = 24
        copy.frame = NSRect(x: max(0, width - 7 - side), y: 7, width: side, height: side)
        run.frame = NSRect(x: max(0, copy.frame.minX - 2 - side), y: 7, width: side, height: side)
        wrap.frame = NSRect(x: max(0, (run.isHidden ? copy.frame.minX : run.frame.minX) - 2 - side), y: 7, width: side, height: side)
        fileIcon.frame = NSRect(x: 13, y: 12, width: 14, height: 14)
        let titleX: CGFloat = fileIcon.isHidden ? 13 : 33
        titleLabel.frame = NSRect(x: titleX, y: 11, width: max(0, wrap.frame.minX - titleX - 8), height: 16)
        scroll.frame = NSRect(x: 15.4, y: 43.8, width: max(1, width - 30.8), height: max(0, bounds.height - 57.6))
        text.frame = NSRect(x: 0, y: 0, width: documentWidth, height: documentHeight)
    }

    private func refreshWrapAction() {
        let label = wrapped ? "Disable line wrap" : "Wrap lines"
        wrap.toolTip = label
        wrap.setAccessibilityLabel(label)
        wrap.setAccessibilityValue(wrapped ? 1 : 0)
        wrap.layer?.backgroundColor = (wrapped ? wrapBackground : .clear).cgColor
    }

    var runnableCommand: String? {
        guard onRunShellCommand != nil, !isStreaming, fenceClosed else { return nil }
        return AgentCodeFenceInfo.runnableCommand(language: fenceLanguage, code: code)
    }

    private func refreshRunAction() {
        let hidden = runnableCommand == nil
        if run.isHidden != hidden { run.isHidden = hidden; invalidateMeasurement() }
    }

    private func resetCopyAction() {
        copy.image = AgentConversationIcon.copy.image()
        copy.toolTip = "Copy code"
        copy.setAccessibilityLabel("Copy code")
    }

    func copyCode() {
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(code, forType: .string)
        copy.image = (copied ? AgentConversationIcon.check : .warning).image()
        copy.toolTip = copied ? "Copied" : "Copy failed"
        copy.setAccessibilityLabel(copy.toolTip)
        copyReset?.cancel()
        copyReset = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.resetCopyAction()
        }
    }

    static func syntaxLanguage(_ value: String) -> SyntaxLanguage {
        let lower = value.lowercased()
        let aliases: [String: SyntaxLanguage] = [
            "js": .javaScript, "javascript": .javaScript, "ts": .typeScript, "typescript": .typeScript,
            "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell, "shell": .shell, "shellscript": .shell,
            "py": .python, "rb": .ruby, "rs": .rust, "c++": .cpp, "objective-c": .objectiveC,
            "yml": .yaml, "md": .markdown, "text": .plain, "plaintext": .plain,
        ]
        return aliases[lower] ?? SyntaxLanguage.allCases.first { $0.rawValue.lowercased() == lower } ?? .plain
    }
}

struct AgentCodeFenceInfo: Equatable {
    static func runnableCommand(language: String, code: String) -> String? {
        guard ["sh", "bash", "zsh", "fish", "shell", "powershell", "pwsh"].contains(language), code.hasSuffix("\n") else { return nil }
        let command = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !command.hasSuffix("\\"),
              !code.dropLast().unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }) else { return nil }
        return command
    }

    var language: String
    var title: String?

    init(_ info: String) {
        let parts = info.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        language = parts.first.map(String.init) ?? ""
        let rest = parts.count > 1 ? String(parts[1]) : ""
        title = nil
        let pattern = #"(?:^|\s)(?:title|file(?:name)?)=(?:"([^"]+)"|'([^']+)'|(\S+))"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: rest, range: NSRange(location: 0, length: rest.utf16.count)) {
            for index in 1...3 where match.range(at: index).location != NSNotFound {
                title = (rest as NSString).substring(with: match.range(at: index))
                break
            }
        }
        if title == nil {
            title = rest.split(whereSeparator: { $0.isWhitespace }).first {
                $0.range(of: #"^[\w@][\w@./-]*\.[A-Za-z0-9]+$"#, options: .regularExpression) != nil
            }.map(String.init)
        }
    }
}
