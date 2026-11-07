import AppKit
import TabCore
import TabProtocol

/// Native assistant response surface. Completed text/code/table sections retain their view and
/// selection while the final section grows; file links are delegated to the owning project pane.
@MainActor
final class AgentResponseView: NSView, NSTextViewDelegate {
    override func hitTest(_ point: NSPoint) -> NSView? {
        AgentTableCopyHitTesting.hitTest(point, in: self) ?? super.hitTest(point)
    }

    var onRunShellCommand: ((String) -> Void)? { didSet { updateCommandAvailability() } }
    /// While streaming, the last block's unclosed inline Markdown is completed before rendering.
    var isStreaming = false {
        didSet {
            guard oldValue != isStreaming else { return }
            // The completed source renders as written, so a repaired tail must render again.
            if completedStreamingTail { source = nil }
            updateCommandAvailability()
        }
    }
    private var completedStreamingTail = false
    var onOpenFile: ((String, Int?) -> Void)?
    var onOpenFragment: ((String) -> Bool)?
    /// An assistant quotation link (`tab-citation://`) was clicked.
    var onOpenCitation: ((AgentAssistantCitation) -> Void)?
    /// A link to another conversation (`tab-thread://`) was clicked.
    var onOpenThread: ((AgentThreadLink) -> Void)?
    var onReveal: (() -> Void)?
    /// A nested response forwards media activation to the message's top-level response,
    /// which opens every image of the message as one gallery.
    var onOpenMedia: ((AgentMarkdownMedia) -> Void)?
    /// Frame-measured transcript owners should remeasure their row when wrap controls change.
    var onHeightChanged: (() -> Void)?
    var compactProse = false { didSet { if oldValue != compactProse { source = nil } } }
    var inheritedReferences: [String: String] = [:] { didSet { if oldValue != inheritedReferences { source = nil } } }
    var lineBreaks = false { didSet { if oldValue != lineBreaks { source = nil } } }
    var parseRawHTML = true { didSet { if oldValue != parseRawHTML { source = nil } } }
    /// Pull-request cards, artifact templates and file-link tooltips; nil keeps links plain.
    var linkServices: AgentConversationLinkServices? { didSet { if oldValue !== linkServices { source = nil } } }
    private var renderedCardHosts: Set<String>?
    private var cardHosts: Set<String> { linkServices?.pullRequestHosts ?? [] }
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

    /// The rendered sections, in order.
    var sectionViews: [AgentResponseSection] { sections }

    /// Cumulative actual work counters, including sections replaced during this view's lifetime.
    var sectionUpdateCount: Int { retiredUpdateCount + sections.reduce(0) { $0 + $1.updateCount } }
    var sectionMeasurementCount: Int { retiredMeasurementCount + sections.reduce(0) { $0 + $1.measurementCount } }

    func setContent(_ source: String, theme: AppTheme) {
        let themeChanged = palette != theme.palette || scheme != theme.scheme
        guard self.source != source || themeChanged || renderedCardHosts != cardHosts else { return }
        self.source = source
        preparedBlocks = nil
        palette = theme.palette
        scheme = theme.scheme
        var blocks = AgentResponseParser.parse(source, parseRawHTML: parseRawHTML)
        completedStreamingTail = false
        if isStreaming {
            let completed = AgentStreamingCompletion.completingLastBlock(blocks)
            completedStreamingTail = completed != blocks
            blocks = completed
        }
        let references = inheritedReferences.merging(AgentMarkdownReferences.collect(blocks, parseRawHTML: parseRawHTML)) { inherited, _ in inherited }
        applyBlocks(AgentMarkdownFootnotes.prepare(blocks, parseRawHTML: parseRawHTML), references: references, theme: theme)
    }

    func setPreparedContent(_ blocks: [AgentMarkdown.Block], theme: AppTheme) {
        guard preparedBlocks != blocks || palette != theme.palette || scheme != theme.scheme || source == nil || renderedCardHosts != cardHosts else { return }
        preparedBlocks = blocks
        source = ""
        palette = theme.palette
        scheme = theme.scheme
        applyBlocks(blocks, references: inheritedReferences, theme: theme)
    }

    /// Renders again when the pull-request hosts changed since the last render; true when it did.
    @discardableResult
    func reapplyIfCardHostsChanged(theme: AppTheme) -> Bool {
        guard let rendered = renderedCardHosts, rendered != cardHosts else { return false }
        if let preparedBlocks {
            setPreparedContent(preparedBlocks, theme: theme)
        } else if let source {
            self.source = nil
            setContent(source, theme: theme)
        }
        return true
    }

    private func applyBlocks(_ blocks: [AgentMarkdown.Block], references: [String: String], theme: AppTheme) {
        renderedCardHosts = cardHosts
        let parts = AgentResponsePart.partition(blocks, compact: compactProse, parseRawHTML: parseRawHTML,
                                                pullRequestHosts: cardHosts, templates: linkServices != nil,
                                                media: linkServices?.mediaLoader != nil)
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
                case .math: section = AgentResponseMath()
                case .diagram: section = AgentResponseDiagram()
                case .pullRequest: section = AgentResponsePullRequest()
                case .template: section = AgentResponseTemplate()
                case .media: section = AgentResponseMedia()
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
            (section as? AgentResponseProse)?.services = linkServices
            (section as? AgentResponsePullRequest)?.services = linkServices
            (section as? AgentResponseTemplate)?.services = linkServices
            (section as? AgentResponseCode)?.services = linkServices
            (section as? AgentResponseDiagram)?.services = linkServices
            if let media = section as? AgentResponseMedia {
                media.services = linkServices
                media.onOpenMedia = { [weak self] media in self?.openMedia(media) }
            }
            if let container = section as? AgentResponseContainer {
                container.response.linkServices = linkServices
                container.response.compactProse = compactProse
                container.response.lineBreaks = lineBreaks
                container.response.parseRawHTML = parseRawHTML
                container.response.inheritedReferences = references
                container.response.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
                container.response.onOpenFragment = { [weak self] id in self?.openFragment(id) ?? false }
                container.response.onOpenCitation = { [weak self] citation in self?.onOpenCitation?(citation) }
                container.response.onOpenThread = { [weak self] link in self?.onOpenThread?(link) }
                container.response.onOpenMedia = { [weak self] media in self?.openMedia(media) }
            }
            if let notes = section as? AgentResponseFootnotes {
                notes.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
                notes.onOpenFragment = { [weak self] id in self?.openFragment(id) ?? false }
                notes.onOpenCitation = { [weak self] citation in self?.onOpenCitation?(citation) }
                notes.onOpenThread = { [weak self] link in self?.onOpenThread?(link) }
            }
            section.apply(part, theme: theme, delegate: self, references: references, compactProse: compactProse, lineBreaks: lineBreaks, rawHTML: parseRawHTML)
            if let container = section as? AgentResponseContainer, container.response.reapplyIfCardHostsChanged(theme: theme) {
                container.invalidateMeasurement()
            }
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
        if raw == AgentInlineMedia.linkURL?.absoluteString {
            if let storage = textView.textStorage, charIndex < storage.length,
               let media = storage.attribute(.agentInlineMedia, at: charIndex, effectiveRange: nil) as? AgentMarkdownMedia {
                openMedia(media)
            }
            return true
        }
        if let citation = AgentAssistantCitation.parse(raw) {
            onOpenCitation?(citation)
            return true
        }
        if let thread = AgentThreadLink(raw) {
            onOpenThread?(thread)
            return true
        }
        guard let target = AgentResponseLink.parse(raw) else { return true }
        switch target {
        case .fragment(let id):
            _ = openFragment(id)
            return true
        case .file(let path, let line):
            // Conversation services open the exact line and column and report failures.
            if let open = linkServices?.openFile, let url = link as? URL ?? URL(string: raw),
               let position = AgentConversationFileTarget(linkURL: url) { open(position) }
            else { onOpenFile?(path, line) }
            return true
        case .external:
            return false // AppKit opens normal web/mail links; no arbitrary schemes are forwarded.
        }
    }

    func textView(_ textView: NSTextView, clickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        guard let cell = cell as? AgentInlineMediaCell else { return }
        openMedia(cell.media)
    }

    /// Every image, video and audio reference of this response in reading order:
    /// media paragraphs, inline images, and those of nested quotes and lists.
    var mediaItems: [AgentMarkdownMedia] {
        sections.flatMap { section -> [AgentMarkdownMedia] in
            if let media = section as? AgentResponseMedia { return media.items }
            if let prose = section as? AgentResponseProse { return prose.inlineMedia }
            if let container = section as? AgentResponseContainer { return container.response.mediaItems }
            return []
        }
    }

    /// Opens `media`: images as a gallery of every image of the message, starting at
    /// it; video and audio in the isolated media window.
    func openMedia(_ media: AgentMarkdownMedia) {
        if let onOpenMedia { onOpenMedia(media); return }
        guard let services = linkServices else { return }
        guard media.kind == .image else { services.playMedia?(media); return }
        let gallery = mediaItems.filter { $0.kind == .image }
        services.previewMedia?(gallery, gallery.firstIndex(of: media) ?? 0)
    }

    /// Every selectable text view, in reading order: prose, code and table text, then
    /// nested containers and footnotes recursively. Labels drawn outside text views,
    /// such as list markers and alert titles, are not part of the message text.
    var textViews: [AgentRichTextView] {
        sections.flatMap { section -> [AgentRichTextView] in
            if let prose = section as? AgentResponseProse { return [prose.text] }
            if let code = section as? AgentResponseCode { return [code.text] }
            if let table = section as? AgentResponseTable { return [table.text] }
            if let container = section as? AgentResponseContainer { return container.response.textViews }
            if let notes = section as? AgentResponseFootnotes { return notes.textViews }
            return []
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
        AgentResponseContainer.revealAncestors(of: target.text, below: self)
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
    case math(String)
    case diagram(String)
    /// A card for a bare pull-request link of the preceding paragraph.
    case pullRequest(String)
    case template(AgentArtifactTemplate)
    /// An image-only paragraph: images and bare media links shown as tiles.
    case media([AgentMarkdownMedia])

    var kind: Int {
        switch self {
        case .prose: return 0; case .code: return 1; case .table: return 2; case .container, .nested: return 3
        case .footnotes: return 4; case .divider: return 5; case .math: return 6; case .diagram: return 7
        case .pullRequest: return 8; case .template: return 9; case .media: return 10
        }
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

    /// Groups blocks into sections. Paragraphs and list items showing bare links to a pull
    /// request on `pullRequestHosts` are followed by one card per pull request; with
    /// `templates`, artifact-template directive lines become template cards; with `media`,
    /// paragraphs of only images or bare media links become media tiles.
    @MainActor
    static func partition(_ blocks: [AgentMarkdown.Block], compact: Bool = false, parseRawHTML: Bool = true,
                          pullRequestHosts: Set<String> = [], templates: Bool = false, media: Bool = false) -> [Self] {
        let indents = AgentListLayout.indents(blocks, font: AppFont.system(compact ? 12 : 14, weight: .light))
        var proseIndents: [Int: CGFloat] = [:]
        var result: [Self] = []
        var prose: [AgentMarkdown.Block] = []
        func flush() {
            if !prose.isEmpty { result.append(.prose(prose, listIndents: proseIndents)); prose.removeAll(keepingCapacity: true); proseIndents.removeAll(keepingCapacity: true) }
        }
        func appendProse(_ block: AgentMarkdown.Block, at index: Int) {
            if let indent = indents[index] { proseIndents[prose.count] = indent }
            prose.append(block)
            let content: String
            switch block {
            case .paragraph(let text), .list(_, let text, _, _): content = text
            default: return
            }
            let urls = AgentPullRequestLink.urls(in: content, hosts: pullRequestHosts)
            guard !urls.isEmpty else { return }
            flush()
            result.append(contentsOf: urls.map { .pullRequest($0.absoluteString) })
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
            case .math(let latex): flush(); result.append(.math(latex))
            case .diagram(let source): flush(); result.append(.diagram(source))
            case .paragraph(let content) where templates && content.contains("::artifact-template"):
                var lines: [String] = []
                for line in content.components(separatedBy: "\n") {
                    guard let template = AgentArtifactTemplate.parse(line) else { lines.append(line); continue }
                    if !lines.isEmpty { appendProse(.paragraph(lines.joined(separator: "\n")), at: index); lines.removeAll() }
                    flush()
                    result.append(.template(template))
                }
                if !lines.isEmpty { appendProse(.paragraph(lines.joined(separator: "\n")), at: index) }
            default:
                if media, case .paragraph(let content) = block, let items = AgentMarkdownMedia.paragraph(content) {
                    flush()
                    result.append(.media(items))
                } else { appendProse(block, at: index) }
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
    /// Assistant sections render the sanitized inline-HTML subset.
    private(set) var rawHTML = false
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

    final func apply(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate, references: [String: String] = [:], compactProse: Bool = false, lineBreaks: Bool = false, rawHTML: Bool = false) {
        guard self.part != part || palette != theme.palette || scheme != theme.scheme || self.references != references || self.compactProse != compactProse || self.lineBreaks != lineBreaks || self.rawHTML != rawHTML else { return }
        self.lineBreaks = lineBreaks
        self.rawHTML = rawHTML
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
final class AgentResponseProse: AgentResponseSection {
    override var kind: Int { 0 }
    let text = AgentRichTextView(frame: .zero)
    /// File-link tooltips request metadata through these services.
    weak var services: AgentConversationLinkServices? {
        didSet { if oldValue !== services { text.setFileLinkServices(services, missingColor: missingColor, theme: fileIconTheme) } }
    }
    private var missingColor: NSColor = .secondaryLabelColor
    private var fileIconTheme = AppTheme.shared
    /// Inline image thumbnails, in reading order.
    private(set) var inlineCells: [AgentInlineMediaCell] = []
    private var inlineAttachments: [String: NSTextAttachment] = [:]
    private var inlineObservations: [AgentLazyRequestObservation] = []
    var inlineMedia: [AgentMarkdownMedia] { inlineCells.map(\.media) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = false
        addSubview(text)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeInlineMedia()
    }

    /// Loads inline thumbnails only while the prose is in a window.
    private func observeInlineMedia() {
        inlineObservations.forEach { $0.cancel() }
        inlineObservations.removeAll()
        guard window != nil, let loader = services?.mediaLoader else {
            for cell in inlineCells { cell.thumbnail = nil }
            return
        }
        for cell in inlineCells where cell.media.kind == .image {
            inlineObservations.append(loader.observe(cell.media) { [weak self, weak cell] state in
                guard let self, let cell else { return }
                switch state {
                case .loading: return
                case .loaded(let entry): cell.thumbnail = entry.image; cell.failed = entry.image == nil
                case .failed: cell.thumbnail = nil; cell.failed = true
                }
                self.text.needsDisplay = true
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        guard case .prose(let blocks, let listIndents) = part else { return }
        text.delegate = delegate
        let rendered = AgentMarkdown.render(blocks, theme: theme, fileLinks: true, references: references, compact: compactProse, lineBreaks: lineBreaks, listIndents: listIndents, rawHTML: rawHTML)
        fileIconTheme = theme
        missingColor = AgentMarkdownPalette(theme: theme).muted
        if let services {
            let content = NSMutableAttributedString(attributedString: rendered)
            let metadata = services.fileMetadata
            AgentFileLinkTooltip.markIcons(content, theme: theme) {
                guard case .loaded(let info)? = metadata.state(for: $0) else { return nil }
                return info
            }
            AgentFileLinkTooltip.markMissing(content, color: missingColor) { metadata.state(for: $0) == .loaded(nil) }
            AgentThreadLink.applyKnownTitles(content, titles: services.threadTitles)
            inlineCells = services.mediaLoader == nil ? [] : AgentInlineMedia.substitute(content, theme: theme, cells: &inlineAttachments)
            text.setContent(content)
        } else {
            inlineCells = []
            text.setContent(rendered)
        }
        observeInlineMedia()
        text.setFileLinkServices(services, missingColor: missingColor, theme: fileIconTheme)
        text.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        text.linkTextAttributes = [:] // Inline spans already carry their own link or code color.
    }

    override func height(for width: CGFloat) -> CGFloat { text.height(for: width) }
    override func layoutSection(width: CGFloat) {
        let drawnWidth = text.layoutManager.flatMap { manager in text.textContainer.map { manager.usedRect(for: $0).maxX } } ?? width
        let prefixWidth = AgentExternalLinkLayout.minimumPrefixWidth(text.attributedString())
        text.frame = NSRect(x: 0, y: 0, width: max(width, ceil(drawnWidth), ceil(prefixWidth)), height: bounds.height)
        text.fileLinkHover?.rebuild()
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
    /// Where Copy writes through the conversation actions; unset, it uses the general pasteboard.
    weak var services: AgentConversationLinkServices?
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
        let iconPath = metadata.title ?? FileIcon.syntheticFileName(language: metadata.language)
        fileIcon.isHidden = metadata.title == nil && !FileIcon.hasSpecificIcon(for: iconPath)
        fileIcon.image = fileIcon.isHidden ? nil : FileIcon.image(for: iconPath, dark: !theme.palette.isLight)
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

    private static func copyToGeneralPasteboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    func copyCode() {
        let copied = services?.copy(code) ?? Self.copyToGeneralPasteboard(code)
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
        SyntaxLanguage.forFence(value)
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
