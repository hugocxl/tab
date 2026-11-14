import AppKit
import TabProtocol

/// A parsed Mermaid fence: the diagram family's document, or why it can't be drawn.
enum AgentDiagramParse {
    case document(any AgentDiagramDocument, label: String, widthDependent: Bool)
    case failure(AgentDiagramError)
}

/// Mermaid source → parsed document, plus the last few layouts of each, so a transcript
/// re-measuring rows while a response streams or scrolls never parses the same diagram twice.
@MainActor
final class AgentDiagramCache {
    /// The transcript-wide cache.
    static let shared = AgentDiagramCache(capacity: 64)

    /// Layout inputs: the width offered (zero for families that ignore it) and the colors drawn.
    struct LayoutKey: Hashable {
        var width: CGFloat
        var foreground: NSColor
        var muted: NSColor
        var surface: NSColor
        var border: NSColor
        var accent: NSColor
    }

    private struct Entry {
        var parse: AgentDiagramParse
        var layouts: [LayoutKey: AgentDiagramLayout] = [:]
        var lastUse: UInt64
    }

    let capacity: Int
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    /// Sources actually parsed, for tests.
    private(set) var parseCount = 0
    /// Layouts actually computed, for tests.
    private(set) var layoutCount = 0

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { entries.count }

    func parse(_ source: String) -> AgentDiagramParse {
        clock += 1
        if var entry = entries[source] {
            entry.lastUse = clock
            entries[source] = entry
            return entry.parse
        }
        parseCount += 1
        let parse = Self.parseUncached(source)
        insert(Entry(parse: parse, lastUse: clock), for: source)
        return parse
    }

    func layout(_ source: String, maxWidth: CGFloat, style: AgentDiagramStyle) -> AgentDiagramLayout? {
        guard case .document(let document, _, let widthDependent) = parse(source) else { return nil }
        let key = LayoutKey(width: widthDependent ? max(1, maxWidth.rounded(.down)) : 0, foreground: style.foreground,
                            muted: style.muted, surface: style.surface, border: style.border, accent: style.accent)
        if let layout = entries[source]?.layouts[key] { return layout }
        layoutCount += 1
        let layout = document.layout(maxWidth: max(1, maxWidth), style: style)
        if var entry = entries[source] {
            // Width-dependent families keep a few widths for column resizes; old colors go.
            if entry.layouts.count >= 4 { entry.layouts.removeAll(keepingCapacity: true) }
            entry.layouts[key] = layout
            entries[source] = entry
        }
        return layout
    }

    func removeAll() {
        entries.removeAll()
        parseCount = 0
        layoutCount = 0
    }

    private func insert(_ entry: Entry, for source: String) {
        entries[source] = entry
        guard entries.count > capacity,
              let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { return }
        entries.removeValue(forKey: oldest)
    }

    private struct Family {
        var type: any AgentDiagramDocument.Type
        var label: String
        var widthDependent = false
        /// Whether the parser reads a `---` front matter block itself.
        var readsFrontMatter = true
    }

    private static let families: [Family] = [
        Family(type: AgentFlowchartDiagram.self, label: "Flowchart", readsFrontMatter: false),
        Family(type: AgentSequenceDiagram.self, label: "Sequence diagram"),
        Family(type: AgentStateDiagram.self, label: "State diagram", readsFrontMatter: false),
        Family(type: AgentClassDiagram.self, label: "Class diagram"),
        Family(type: AgentPieDiagram.self, label: "Pie chart"),
        Family(type: AgentGanttDiagram.self, label: "Gantt chart", widthDependent: true),
        Family(type: AgentXYChartDiagram.self, label: "XY chart", widthDependent: true),
    ]

    static func parseUncached(_ source: String) -> AgentDiagramParse {
        guard let header = header(of: source) else {
            return .failure(AgentDiagramError(message: "The diagram is empty.", line: nil))
        }
        guard let family = families.first(where: { $0.type.keywords.contains(header.keyword) }) else {
            return .failure(AgentDiagramError(message: "“\(header.word)” diagrams aren't drawn here, so this shows the source.",
                                              line: header.line, unsupported: true))
        }
        do {
            let input = family.readsFrontMatter || header.frontMatter.isEmpty ? source : blanking(header.frontMatter, in: source)
            return .document(try family.type.init(source: input), label: family.label, widthDependent: family.widthDependent)
        } catch let error as AgentDiagramError {
            return .failure(error)
        } catch {
            return .failure(AgentDiagramError(message: error.localizedDescription, line: nil))
        }
    }

    /// The header keyword after any `---` front matter, `%%` comments and blank lines, with the
    /// 0-based line indices the front matter occupies.
    static func header(of source: String) -> (keyword: String, word: String, line: Int, frontMatter: Range<Int>)? {
        var frontMatterStart: Int?
        var frontMatter = 0..<0
        var sawContent = false
        for (offset, rawLine) in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let start = frontMatterStart {
                if line == "---" { frontMatter = start..<(offset + 1); frontMatterStart = nil }
                continue
            }
            if line.isEmpty || line.hasPrefix("%%") { continue }
            if !sawContent, line == "---" { frontMatterStart = offset; sawContent = true; continue }
            sawContent = true
            guard let keyword = AgentDiagramSource.keyword(of: line) else { return nil }
            let word = String(line.prefix { $0.isLetter || $0.isNumber || $0 == "-" })
            return (keyword, word, offset + 1, frontMatter)
        }
        return nil
    }

    /// `source` with the given lines emptied, so parsers skip them and line numbers still match.
    private static func blanking(_ lines: Range<Int>, in source: String) -> String {
        source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated()
            .map { lines.contains($0.offset) ? "" : String($0.element) }
            .joined(separator: "\n")
    }
}

/// A Mermaid diagram: a header bar like a code block's (kind, Diagram/Source, Copy, Expand) above
/// the native drawing. Invalid sources show the Mermaid as code with the parse error below it.
@MainActor
final class AgentResponseDiagram: AgentResponseSection {
    override var kind: Int { 7 }
    static let headerHeight: CGFloat = 38
    static let inset: CGFloat = 16
    static let sourceLineHeight: CGFloat = 17.875

    let titleLabel = makeLabel("", font: AppFont.mono(11))
    let diagramButton = PillButton("Diagram", style: .plain)
    let sourceButton = PillButton("Source", style: .plain)
    let copy = PillButton("", style: .plain)
    let expand = PillButton("", style: .plain)
    let scroll = AgentPassThroughScrollView()
    let canvas = AgentDiagramCanvas()
    let text = AgentRichTextView(frame: .zero)
    let errorLabel = makeLabel("", font: AppFont.system(11))
    /// The cache this section parses and lays out through.
    var cache = AgentDiagramCache.shared
    /// Where Copy writes through the conversation actions; unset, it uses the general pasteboard.
    weak var services: AgentConversationLinkServices?
    private(set) var source = ""
    private(set) var showsSource = false
    private(set) var parse: AgentDiagramParse?
    private var theme: AppTheme = .shared
    private var style = AgentDiagramStyle()
    private var layout: AgentDiagramLayout?
    private var layoutWidth: CGFloat?
    private var sourceHeight: CGFloat = 0
    private var copyReset: Task<Void, Never>?
    private var toggleBackground: NSColor = .clear
    private static var preview: AgentMediaPreviewWindow?

    /// The parse failure shown, if the source can't be drawn.
    var error: AgentDiagramError? {
        if case .failure(let error) = parse { return error }
        return nil
    }

    /// Whether the drawing (not the source) is on screen.
    var showsDiagram: Bool { !showsSource && error == nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.documentView = canvas
        for child in [titleLabel, diagramButton, sourceButton, copy, expand, scroll, text, errorLabel] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = true
            addSubview(child)
        }
        titleLabel.lineBreakMode = .byTruncatingTail
        errorLabel.lineBreakMode = .byTruncatingTail
        for button in [diagramButton, sourceButton] {
            button.font = AppFont.footnote
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
        }
        diagramButton.setAccessibilityLabel("Show diagram")
        sourceButton.setAccessibilityLabel("Show source")
        diagramButton.onPress = { [weak self] in self?.toggle(source: false) }
        sourceButton.onPress = { [weak self] in self?.toggle(source: true) }
        for button in [copy, expand] {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
        }
        expand.image = AppIcon.maximize.image(size: 12, scale: AppIcon.inlineScale)
        expand.toolTip = "Expand diagram"
        expand.setAccessibilityLabel("Expand diagram")
        expand.onPress = { [weak self] in self?.expandDiagram() }
        copy.onPress = { [weak self] in self?.copySource() }
        resetCopyAction()
        text.textContainer?.lineFragmentPadding = 0
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func captureState() -> AgentResponseState { AgentResponseState(showsSource: showsSource) }
    override func restoreState(_ state: AgentResponseState) { if let showsSource = state.showsSource { setShowsSource(showsSource) } }

    /// Silent state restoration; only the toggle buttons invoke `onHeightChanged`.
    @discardableResult
    func setShowsSource(_ value: Bool) -> Bool {
        guard showsSource != value else { return false }
        showsSource = value
        refreshMode()
        invalidateMeasurement()
        return true
    }

    private func toggle(source: Bool) {
        guard setShowsSource(source) else { return }
        superview?.needsLayout = true
        superview?.invalidateIntrinsicContentSize()
        window?.contentView?.needsLayout = true
        onHeightChanged?()
    }

    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        guard case .diagram(let source) = part else { return }
        if self.source != source {
            copyReset?.cancel()
            resetCopyAction()
        }
        self.source = source
        self.theme = theme
        style = Self.style(theme: theme)
        parse = cache.parse(source)
        layout = nil
        layoutWidth = nil
        switch parse {
        case .document(_, let label, _):
            titleLabel.stringValue = label
            setAccessibilityLabel(label)
        default:
            titleLabel.stringValue = "mermaid"
            setAccessibilityLabel("Mermaid diagram")
        }
        if let error, error.unsupported {
            // Not the author's mistake: a neutral note, not an error.
            errorLabel.stringValue = error.message
        } else if let error {
            errorLabel.stringValue = "Diagram error" + (error.line.map { ", line \($0)" } ?? "") + ": " + error.message
        } else { errorLabel.stringValue = "" }
        errorLabel.toolTip = errorLabel.stringValue
        errorLabel.textColor = error?.unsupported == true ? theme.fgMuted : theme.danger
        titleLabel.textColor = theme.fgMuted
        let muted = theme.fgMuted
        for button in [diagramButton, sourceButton, copy, expand] { button.contentTintColor = muted }
        toggleBackground = theme.fg.withAlphaComponent(0.08)
        text.setContent(Self.highlightedSource(source, theme: theme))
        text.delegate = delegate
        text.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        canvas.layout = nil
        canvas.needsDisplay = true
        layer?.backgroundColor = theme.fg.withAlphaComponent(0.04).cgColor
        layer?.borderColor = theme.border.withAlphaComponent(0.65).cgColor
        refreshMode()
    }

    private func refreshMode() {
        let drawing = showsDiagram
        let failed = error != nil
        scroll.isHidden = !drawing
        text.isHidden = drawing
        errorLabel.isHidden = !failed
        diagramButton.isHidden = failed
        sourceButton.isHidden = failed
        expand.isHidden = !drawing
        diagramButton.layer?.backgroundColor = (drawing ? toggleBackground : .clear).cgColor
        sourceButton.layer?.backgroundColor = (!drawing && !failed ? toggleBackground : .clear).cgColor
        diagramButton.setAccessibilityValue(drawing ? 1 : 0)
        sourceButton.setAccessibilityValue(drawing ? 0 : 1)
    }

    /// The layout for the content width, from the section or the shared cache.
    func diagramLayout(contentWidth: CGFloat) -> AgentDiagramLayout? {
        if let layout, layoutWidth == contentWidth { return layout }
        layout = cache.layout(source, maxWidth: contentWidth, style: style)
        layoutWidth = contentWidth
        return layout
    }

    override func height(for width: CGFloat) -> CGFloat {
        let contentWidth = max(1, width - Self.inset * 2)
        if showsDiagram, let layout = diagramLayout(contentWidth: contentWidth) {
            let overflow = ceil(layout.size.width) > contentWidth
            return Self.headerHeight + 8 + ceil(layout.size.height) + Self.inset + (overflow ? 10 : 0)
        }
        sourceHeight = text.height(for: contentWidth)
        if source.hasSuffix("\n"), let manager = text.layoutManager, manager.extraLineFragmentTextContainer != nil {
            sourceHeight = min(sourceHeight, manager.extraLineFragmentRect.minY)
        }
        sourceHeight = max(Self.sourceLineHeight, sourceHeight)
        return Self.headerHeight + 8 + sourceHeight + (error != nil ? 8 + 16 : 0) + Self.inset - 2
    }

    override func layoutSection(width: CGFloat) {
        let side: CGFloat = 24
        expand.frame = NSRect(x: max(0, width - 7 - side), y: 7, width: side, height: side)
        copy.frame = NSRect(x: max(0, (expand.isHidden ? width - 7 : expand.frame.minX - 2) - side), y: 7, width: side, height: side)
        let sourceWidth = ceil(sourceButton.intrinsicContentSize.width) + 4
        let diagramWidth = ceil(diagramButton.intrinsicContentSize.width) + 4
        sourceButton.frame = NSRect(x: max(0, copy.frame.minX - 6 - sourceWidth), y: 7, width: sourceWidth, height: side)
        diagramButton.frame = NSRect(x: max(0, sourceButton.frame.minX - 2 - diagramWidth), y: 7, width: diagramWidth, height: side)
        let titleEnd = sourceButton.isHidden ? copy.frame.minX : diagramButton.frame.minX
        titleLabel.frame = NSRect(x: 13, y: 11, width: max(0, titleEnd - 13 - 8), height: 16)
        let contentWidth = max(1, width - Self.inset * 2)
        let top = Self.headerHeight + 8
        if showsDiagram, let layout = diagramLayout(contentWidth: contentWidth) {
            scroll.frame = NSRect(x: Self.inset, y: top, width: contentWidth, height: max(0, bounds.height - top - Self.inset))
            canvas.layout = layout
            canvas.frame = NSRect(x: 0, y: 0, width: max(contentWidth, ceil(layout.size.width)), height: ceil(layout.size.height))
            canvas.needsDisplay = true
        } else {
            text.frame = NSRect(x: Self.inset, y: top, width: contentWidth, height: sourceHeight)
            errorLabel.frame = NSRect(x: Self.inset, y: text.frame.maxY + 8, width: contentWidth, height: 16)
        }
    }

    // MARK: Actions

    private func resetCopyAction() {
        copy.image = AppIcon.copy.image(size: 12, scale: AppIcon.inlineScale)
        copy.toolTip = "Copy diagram source"
        copy.setAccessibilityLabel("Copy diagram source")
    }

    /// Copies the Mermaid source.
    func copySource() {
        let copied: Bool
        if let services { copied = services.copy(source) } else {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(source, forType: .string)
        }
        copy.image = (copied ? AppIcon.check : .triangleAlert).image(size: 12, scale: AppIcon.inlineScale)
        copy.toolTip = copied ? "Copied" : "Copy failed"
        copy.setAccessibilityLabel(copy.toolTip)
        copyReset?.cancel()
        copyReset = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.resetCopyAction()
        }
    }

    /// The most pixels an exported diagram image may hold (48 megapixels).
    static let maxImagePixels = 48_000_000

    /// The diagram drawn at `scale` on the theme's background, for the expanded viewer.
    func renderedImage(scale: CGFloat = 2) -> NSImage? {
        guard let layout = diagramLayout(contentWidth: layoutWidth ?? max(1, bounds.width - Self.inset * 2)) else { return nil }
        return Self.image(of: layout, theme: theme, scale: scale)
    }

    /// The scale to draw `size` points at: `requested`, lowered (below 1 if need be) so the image stays within `maxImagePixels`.
    static func clampedScale(for size: CGSize, requested: CGFloat) -> CGFloat {
        let area = Double(size.width) * Double(size.height)
        guard area > 0 else { return requested }
        let limit = (Double(maxImagePixels) / area).squareRoot()
        return min(requested, CGFloat(limit))
    }

    /// `layout` drawn on the theme's background, never allocating more than `maxImagePixels`.
    static func image(of layout: AgentDiagramLayout, theme: AppTheme, scale requested: CGFloat) -> NSImage? {
        let padding: CGFloat = 24
        let size = CGSize(width: ceil(layout.size.width) + padding * 2, height: ceil(layout.size.height) + padding * 2)
        let scale = clampedScale(for: size, requested: requested)
        let pixelWidth = Int(size.width * scale), pixelHeight = Int(size.height * scale)
        guard pixelWidth > 0, pixelHeight > 0, pixelWidth * pixelHeight <= maxImagePixels,
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(theme.bg.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: padding, y: padding)
        layout.draw(context)
        guard let image = context.makeImage() else { return nil }
        let representation = NSBitmapImageRep(cgImage: image)
        representation.size = size
        let result = NSImage(size: size)
        result.addRepresentation(representation)
        return result
    }

    /// Opens the diagram in the zoomable media viewer; Escape closes it.
    func expandDiagram() {
        guard let image = renderedImage(),
              let representation = image.representations.first as? NSBitmapImageRep,
              let data = representation.representation(using: .png, properties: [:]) else { return }
        let name = (titleLabel.stringValue.isEmpty ? "Diagram" : titleLabel.stringValue) + ".png"
        let attachment = AgentChatAttachmentDescriptor(id: "diagram", name: name, mimeType: "image/png", byteCount: data.count)
        Self.preview?.close()
        let preview = AgentMediaPreviewWindow(item: "diagram", attachments: [attachment], index: 0,
                                              fetch: { _, _ in data }, theme: theme)
        Self.preview = preview
        preview.present(in: window)
    }

    // MARK: Style

    static func style(theme: AppTheme) -> AgentDiagramStyle {
        var style = AgentDiagramStyle()
        style.foreground = theme.fg
        style.muted = theme.fgMuted
        style.surface = theme.surface
        style.border = theme.border
        style.accent = theme.accent
        style.accentSoft = theme.accentSoft
        style.warning = theme.warning
        style.danger = theme.danger
        style.series = [theme.accent] + style.series.dropFirst()
        return style
    }

    private static let keywords: Set<String> = [
        "subgraph", "end", "direction", "participant", "actor", "note", "loop", "alt", "else", "opt", "par", "and",
        "rect", "critical", "break", "activate", "deactivate", "autonumber", "over", "as", "section", "title",
        "dateformat", "axisformat", "excludes", "todaymarker", "class", "classdef", "state", "style", "linkstyle",
        "click", "x-axis", "y-axis", "bar", "line", "showdata", "left", "right", "of",
    ]
    private static let tokenExpression = try? NSRegularExpression(
        pattern: #"(%%.*$)|("[^"\n]*")|((?:<<|<)?[-=.]{2,}(?:>>|>|x|o|\))?|-[>)x]|=>)|(\b\d+(?:\.\d+)?\b)|([A-Za-z][\w-]*)"#,
        options: [.anchorsMatchLines])

    /// The Mermaid source with comments, strings, arrows, numbers and keywords colored.
    static func highlightedSource(_ source: String, theme: AppTheme) -> NSAttributedString {
        let font = AppFont.mono(13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = sourceLineHeight
        paragraph.maximumLineHeight = sourceLineHeight
        paragraph.lineBreakMode = .byWordWrapping
        let result = NSMutableAttributedString(string: source, attributes: [.font: font, .foregroundColor: theme.fg, .paragraphStyle: paragraph])
        guard let expression = tokenExpression else { return result }
        let colors = theme.syntaxColors
        var headerSeen = false
        expression.enumerateMatches(in: source, range: NSRange(location: 0, length: (source as NSString).length)) { match, _, _ in
            guard let match else { return }
            let kinds: [TokenKind?] = [nil, .comment, .string, .punctuation, .number, nil]
            for group in 1...5 where match.range(at: group).location != NSNotFound {
                let range = match.range(at: group)
                if group == 5 {
                    let word = (source as NSString).substring(with: range).lowercased()
                    let header = !headerSeen
                    headerSeen = true
                    guard header || keywords.contains(word) else { return }
                    result.addAttributes(colors.attributes(.keyword, font: font), range: range)
                } else if let kind = kinds[group] {
                    if kind != .comment { headerSeen = true }
                    result.addAttributes(colors.attributes(kind, font: font), range: range)
                }
                return
            }
        }
        return result
    }
}

/// Draws a diagram layout centered in its width, in a flipped (top-left) context.
@MainActor
final class AgentDiagramCanvas: NSView {
    var layout: AgentDiagramLayout?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: max(0, ((bounds.width - layout.size.width) / 2).rounded()), y: 0)
        layout.draw(context)
        context.restoreGState()
    }
}

/// A scroll view inside the conversation: code blocks, diagrams and tool output. Scrolling
/// it can't use goes on to the conversation: vertical scrolling when it scrolls only
/// sideways or has reached its edge, and sideways scrolling when its content fits.
@MainActor
final class AgentPassThroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if Self.passes(event, scroll: self) { nextResponder?.scrollWheel(with: event); return }
        super.scrollWheel(with: event)
    }

    static func passes(_ event: NSEvent, scroll: NSScrollView) -> Bool {
        let document = scroll.documentView?.frame.size ?? .zero
        let visible = scroll.contentView.bounds
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            guard scroll.hasVerticalScroller, document.height > scroll.contentSize.height + 0.5 else { return true }
            let flipped = scroll.documentView?.isFlipped ?? true
            let atTop = flipped ? visible.minY <= 0.5 : visible.maxY >= document.height - 0.5
            let atBottom = flipped ? visible.maxY >= document.height - 0.5 : visible.minY <= 0.5
            // Positive deltas move toward the top.
            return (event.scrollingDeltaY > 0 && atTop) || (event.scrollingDeltaY < 0 && atBottom)
        }
        return document.width <= scroll.contentSize.width + 0.5
    }
}
