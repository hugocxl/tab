import AppKit
import TabCore

/// Native assistant response surface. Completed text/code/table sections retain their view and
/// selection while the final section grows; file links are delegated to the owning project pane.
@MainActor
final class AgentResponseView: NSView, NSTextViewDelegate {
    var onOpenFile: ((String, Int?) -> Void)?
    /// Frame-measured transcript owners should remeasure their row when wrap controls change.
    var onHeightChanged: (() -> Void)?
    private var source: String?
    private var palette: ChromePalette?
    private var scheme: ColorScheme?
    private var sections: [AgentResponseSection] = []
    private var measuredWidth: CGFloat = 0
    private var retiredUpdateCount = 0
    private var retiredMeasurementCount = 0
    override var isFlipped: Bool { true }

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

    /// Cumulative actual work counters, including sections replaced during this view's lifetime.
    var sectionUpdateCount: Int { retiredUpdateCount + sections.reduce(0) { $0 + $1.updateCount } }
    var sectionMeasurementCount: Int { retiredMeasurementCount + sections.reduce(0) { $0 + $1.measurementCount } }

    func setContent(_ source: String, theme: AppTheme) {
        let themeChanged = palette != theme.palette || scheme != theme.scheme
        guard self.source != source || themeChanged else { return }
        self.source = source
        palette = theme.palette
        scheme = theme.scheme
        let parts = AgentResponsePart.partition(AgentMarkdown.blocks(source))
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
            section.apply(part, theme: theme, delegate: self)
        }
        while sections.count > parts.count {
            let section = sections.removeLast()
            retire(section)
            section.removeFromSuperview()
        }
        measuredWidth = 0
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    func height(for width: CGFloat) -> CGFloat {
        measuredWidth = max(1, width)
        var y: CGFloat = 0
        for (index, section) in sections.enumerated() {
            if index > 0 { y += 12 }
            let height = section.measuredHeight(for: measuredWidth)
            section.place(in: NSRect(x: 0, y: y, width: measuredWidth, height: height))
            y += height
        }
        return ceil(y)
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
        case .file(let path, let line):
            onOpenFile?(path, line)
            return true
        case .external:
            return false // AppKit opens normal web/mail links; no arbitrary schemes are forwarded.
        }
    }
}

enum AgentResponsePart: Equatable {
    case prose([AgentMarkdown.Block])
    case code(String, String)
    case table([String], [[String]], [AgentMarkdown.TableAlignment])

    var kind: Int {
        switch self { case .prose: return 0; case .code: return 1; case .table: return 2 }
    }

    static func partition(_ blocks: [AgentMarkdown.Block]) -> [Self] {
        var result: [Self] = []
        var prose: [AgentMarkdown.Block] = []
        func flush() {
            if !prose.isEmpty { result.append(.prose(prose)); prose.removeAll(keepingCapacity: true) }
        }
        for block in blocks {
            switch block {
            case .code(let info, let source): flush(); result.append(.code(info, source))
            case .table(let headers, let rows, let alignments): flush(); result.append(.table(headers, rows, alignments))
            default: prose.append(block)
            }
        }
        flush()
        return result
    }
}

@MainActor
class AgentResponseSection: NSView {
    var onHeightChanged: (() -> Void)?
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

    final func apply(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        guard self.part != part || palette != theme.palette || scheme != theme.scheme else { return }
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
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        guard case .prose(let blocks) = part else { return }
        text.delegate = delegate
        text.setContent(AgentMarkdown.render(blocks, theme: theme, fileLinks: true))
        text.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        text.linkTextAttributes = [.foregroundColor: theme.accent]
    }

    override func height(for width: CGFloat) -> CGFloat { text.height(for: width) }
    override func layoutSection(width: CGFloat) { text.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height) }
}

/// A real independently scrollable code block, not a paragraph with a shaded background.
@MainActor
final class AgentResponseCode: AgentResponseSection {
    override var kind: Int { 1 }
    let text = AgentRichTextView(frame: .zero)
    let scroll = NSScrollView()
    let copy = PillButton("Copy code", style: .plain)
    let wrap = PillButton("Wrap", style: .plain)
    private let titleLabel = makeLabel("", font: AppFont.mono(11))
    private var highlighter: SyntaxHighlighter?
    private(set) var code = ""
    private(set) var language = SyntaxLanguage.plain
    private(set) var wrapped = false
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
        for child in [scroll, titleLabel, wrap, copy] {
            child.translatesAutoresizingMaskIntoConstraints = true
            addSubview(child)
        }
        wrap.font = AppFont.footnote
        copy.font = AppFont.footnote
        wrap.setAccessibilityLabel("Toggle code line wrapping")
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

    /// Silent state restoration; only the actual wrap button action invokes `onHeightChanged`.
    @discardableResult
    func setWrapped(_ value: Bool) -> Bool {
        guard wrapped != value else { return false }
        wrapped = value
        wrap.title = wrapped ? "Unwrap" : "Wrap"
        scroll.contentView.scroll(to: .zero)
        invalidateMeasurement()
        return true
    }

    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        guard case .code(let info, let source) = part else { return }
        let metadata = AgentCodeFenceInfo(info)
        titleLabel.stringValue = metadata.title ?? (metadata.language.isEmpty ? "Plain text" : metadata.language)
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
            copy.title = "Copy code"
            longestCodeWidth = nil
        }
        code = source
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.lineBreakMode = .byWordWrapping
        let content = NSMutableAttributedString(string: source, attributes: [
            .font: AppFont.mono(12), .foregroundColor: theme.fg, .paragraphStyle: paragraph,
        ])
        for token in highlighter?.tokens ?? [] where NSMaxRange(token.range) <= content.length {
            content.addAttributes(theme.syntaxColors.attributes(token.kind, font: AppFont.mono(12)), range: token.range)
        }
        text.setContent(content)
        text.delegate = delegate
        text.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        layer?.backgroundColor = theme.fg.withAlphaComponent(0.04).cgColor
        layer?.borderColor = theme.border.withAlphaComponent(0.65).cgColor
    }

    override func height(for width: CGFloat) -> CGFloat {
        let available = max(1, width - 24)
        let font = AppFont.mono(12)
        if longestCodeWidth == nil || longestWidthFont != font {
            longestLineScanCount += 1
            longestCodeWidth = code.components(separatedBy: "\n").reduce(CGFloat.zero) { longest, line in
                max(longest, (line as NSString).size(withAttributes: [.font: font]).width)
            }
            longestWidthFont = font
        }
        let longest = longestCodeWidth ?? 0
        documentWidth = wrapped ? available : max(available, ceil(longest) + 2)
        documentHeight = max(18, text.height(for: documentWidth))
        return 34 + documentHeight + 24 + (documentWidth > available ? 10 : 0)
    }

    override func layoutSection(width: CGFloat) {
        let copyWidth: CGFloat = 72
        titleLabel.frame = NSRect(x: 12, y: 9, width: max(0, width - 150), height: 18)
        wrap.frame = NSRect(x: max(0, width - 132), y: 4, width: 52, height: 26)
        copy.frame = NSRect(x: max(0, width - 78), y: 4, width: copyWidth, height: 26)
        scroll.frame = NSRect(x: 12, y: 36, width: max(1, width - 24), height: max(0, bounds.height - 48))
        text.frame = NSRect(x: 0, y: 0, width: documentWidth, height: documentHeight)
    }

    func copyCode() {
        NSPasteboard.general.clearContents()
        copy.title = NSPasteboard.general.setString(code, forType: .string) ? "Copied" : "Copy failed"
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
