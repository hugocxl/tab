import AppKit

/// Small native Markdown presentation layer. Foundation handles inline syntax; block structure
/// supplies readable typography without HTML, remote image fetches, or executable link schemes.
@MainActor
enum AgentMarkdown {
    enum TableAlignment: Equatable { case left, center, right }
    enum Block: Equatable {
        case paragraph(String)
        case reference(String, String)
        case footnoteDefinition(String, String)
        case nested(AgentResponsePart.Container, [Block])
        case footnotes([AgentMarkdownFootnote])
        case heading(Int, String)
        case list(String, String, Int, structure: AgentListItemStructure? = nil)
        case code(String, String, closed: Bool = true)
        case quote(String)
        case listBlock(String, String, Int, structure: AgentListItemStructure? = nil)
        case details(String, String, Bool)
        case divider
        case table([String], [[String]], [TableAlignment])
        /// A display equation: `$$…$$`, `\[…\]` or a closed `math`, `latex` or `katex` fence.
        case math(String)
        /// A closed `mermaid` fence's source.
        case diagram(String)

        /// Code fences and diagrams share the compatibility renderer's code surface.
        var isCodeLike: Bool {
            switch self {
            case .code, .diagram: return true
            default: return false
            }
        }
    }

    static func blocks(_ source: String) -> [Block] {
        AgentResponseParser.parse(source)
    }
    static func render(_ source: String, theme: AppTheme) -> NSAttributedString {
        let blocks = blocks(source)
        return render(AgentMarkdownFootnotes.prepare(blocks, parseRawHTML: true), theme: theme, references: AgentMarkdownReferences.collect(blocks, parseRawHTML: true), rawHTML: true)
    }

    /// Renders blocks as one attributed string. `rawHTML` enables the sanitized inline-HTML subset
    /// of assistant Markdown; user text keeps its tags literal.
    static func render(_ blocks: [Block], theme: AppTheme, fileLinks: Bool = false, references: [String: String] = [:], compact: Bool = false, lineBreaks: Bool = false, listIndents suppliedListIndents: [Int: CGFloat] = [:], rawHTML: Bool = false) -> NSAttributedString {
        let colors = AgentMarkdownPalette(theme: theme)
        let output = NSMutableAttributedString(string: "")
        let listIndents = AgentListLayout.indents(blocks, font: AppFont.system(compact ? 12 : 14, weight: .light)).merging(suppliedListIndents) { _, supplied in supplied }
        for (blockIndex, block) in blocks.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineBreaks ? 19 : (compact ? 19.5 : 22.75)
            paragraph.maximumLineHeight = paragraph.minimumLineHeight
            paragraph.paragraphSpacingBefore = blockIndex == 0 ? 0 : (compact ? 8 : AgentMarkdownLayout.blockGap)
            paragraph.paragraphSpacing = 0
            paragraph.lineBreakMode = .byWordWrapping
            let text: NSAttributedString
            switch block {
            case .reference, .footnoteDefinition: continue
            case .nested(_, let blocks): text = render(blocks, theme: theme, fileLinks: fileLinks, references: references, lineBreaks: lineBreaks, rawHTML: rawHTML)
            case .footnotes(let notes):
                let content = NSMutableAttributedString(string: "")
                for note in notes {
                    content.append(NSAttributedString(string: "\(note.number). ", attributes: [.font: AppFont.system(12), .foregroundColor: colors.muted]))
                    content.append(render(note.blocks, theme: theme, fileLinks: fileLinks, references: references, compact: true, lineBreaks: lineBreaks, rawHTML: rawHTML))
                }
                text = content
            case .paragraph(let content):
                text = inline(content, theme: theme, font: AppFont.system(compact ? 12 : 14, weight: .light), color: compact ? colors.muted : nil, fileLinks: fileLinks, references: references, lineBreaks: lineBreaks, rawHTML: rawHTML)
            case .heading(let level, let content):
                let size: CGFloat = level == 1 ? 20 : level == 2 ? 18 : level == 3 ? 16 : 14
                paragraph.paragraphSpacingBefore = blockIndex == 0 ? 0 : 20
                paragraph.minimumLineHeight = AgentMarkdownLayout.units(size * 1.3)
                paragraph.maximumLineHeight = AgentMarkdownLayout.units(size * 1.3)
                text = inline(content, theme: theme, font: AppFont.system(size, weight: .semibold), color: level == 6 ? colors.muted : colors.heading, fileLinks: fileLinks, references: references, lineBreaks: lineBreaks, rawHTML: rawHTML)
            case .list(let marker, let content, let depth, let structure):
                paragraph.headIndent = listIndents[blockIndex] ?? CGFloat(depth + 1) * 20
                let markerFont = marker.hasSuffix(".") ? NSFont.monospacedDigitSystemFont(ofSize: compact ? 12 : 14, weight: .light) : AppFont.system(compact ? 12 : 14, weight: .light)
                let markerWidth = ((marker + " ") as NSString).size(withAttributes: [.font: markerFont]).width
                paragraph.firstLineHeadIndent = paragraph.headIndent - markerWidth
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
                if blockIndex > 0, case .list(_, _, let previousDepth, let previousStructure) = blocks[blockIndex - 1], previousDepth == depth, structure?.id == previousStructure?.id {
                    paragraph.paragraphSpacingBefore = structure?.isLoose == true ? (compact ? 8 : AgentMarkdownLayout.blockGap) : (compact ? AgentMarkdownLayout.compactListGap : 4)
                }
                let item = NSMutableAttributedString(string: marker + "\t", attributes: [.font: markerFont, .foregroundColor: compact ? colors.muted : colors.body])
                if AgentListBullet.recognizes(marker) {
                    paragraph.firstLineHeadIndent = paragraph.headIndent - 20
                    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
                    item.addAttributes([.agentListBullet: compact ? colors.muted : colors.body, .foregroundColor: NSColor.clear], range: NSRange(location: 0, length: 1))
                }
                if let state = AgentTaskCheckbox.state(marker: marker, dark: !theme.palette.isLight) {
                    let gutter = AgentListLayout.gutter(structure: structure, blocks: blocks, font: markerFont)
                    paragraph.firstLineHeadIndent = paragraph.headIndent - gutter
                    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent - gutter + AgentTaskCheckbox.textInset(font: markerFont))]
                    // The checkbox is painted separately; its copyable Unicode character
                    // must not enlarge the line through a fallback symbol font.
                    item.addAttributes([.agentTaskCheckbox: state, .foregroundColor: NSColor.clear, .font: AppFont.system(1), .agentMarkdownLineFont: markerFont], range: NSRange(location: 0, length: 1))
                }
                item.append(inline(content, theme: theme, font: AppFont.system(compact ? 12 : 14, weight: .light), color: compact ? colors.muted : nil, fileLinks: fileLinks, references: references, lineBreaks: lineBreaks, rawHTML: rawHTML))
                text = item
            case .math(let latex):
                paragraph.alignment = .center
                paragraph.minimumLineHeight = 0
                paragraph.maximumLineHeight = 0
                let math = NSMutableAttributedString(string: "\u{E000}", attributes: [.font: AppFont.system(compact ? 12 : 14, weight: .light), .foregroundColor: colors.body])
                AgentMarkdownMath.substitute(["\u{E000}": AgentMarkdownMath.Span(latex: latex, display: true)], in: math, theme: theme)
                text = math
            case .code, .diagram:
                let language: String, content: String
                if case .code(let info, let body, _) = block { language = info; content = body }
                else if case .diagram(let source) = block { language = "mermaid"; content = source }
                else { continue }
                paragraph.lineSpacing = 4
                paragraph.paragraphSpacingBefore = 0
                paragraph.paragraphSpacing = 0
                paragraph.headIndent = 12
                paragraph.firstLineHeadIndent = 12
                let code = NSMutableAttributedString(string: "")
                if !language.isEmpty {
                    code.append(NSAttributedString(string: language + "\n", attributes: [.font: AppFont.mono(10), .foregroundColor: theme.fgDim]))
                }
                code.append(NSAttributedString(string: content.isEmpty ? " " : content,
                    attributes: [.font: AppFont.mono(12), .foregroundColor: theme.fg]))
                code.addAttribute(.agentCodeBackground, value: theme.fg.withAlphaComponent(0.045),
                                  range: NSRange(location: 0, length: code.length))
                text = code
            case .quote(let content):
                paragraph.headIndent = 16
                paragraph.firstLineHeadIndent = 16
                let quote = NSMutableAttributedString(attributedString: render(AgentResponseParser.parse(content, parseRawHTML: rawHTML), theme: theme, fileLinks: fileLinks, references: references, lineBreaks: lineBreaks, rawHTML: rawHTML))
                if quote.length > 0 {
                    quote.addAttribute(.agentQuoteBorder, value: colors.quoteRule, range: NSRange(location: 0, length: quote.length))
                }
                text = quote
            case .listBlock(let marker, let source, let depth, _):
                paragraph.firstLineHeadIndent = CGFloat(depth) * 18
                paragraph.headIndent = CGFloat(depth) * 18 + 20
                let nested = NSMutableAttributedString(string: marker + "  ", attributes: [.font: AppFont.system(14, weight: .light), .foregroundColor: colors.muted])
                nested.append(render(AgentResponseParser.parse(source, parseRawHTML: rawHTML), theme: theme, fileLinks: fileLinks, references: references, lineBreaks: lineBreaks, rawHTML: rawHTML))
                text = nested
            case .details(let summary, let source, _):
                let nested = NSMutableAttributedString(attributedString: inline(summary, theme: theme, fileLinks: fileLinks, references: references, lineBreaks: lineBreaks, rawHTML: rawHTML))
                nested.append(NSAttributedString(string: "\n"))
                nested.append(render(AgentResponseParser.parse(source, parseRawHTML: rawHTML), theme: theme, fileLinks: fileLinks, references: references, lineBreaks: lineBreaks, rawHTML: rawHTML))
                text = nested
            case .divider:
                paragraph.paragraphSpacingBefore = 4
                text = NSAttributedString(string: "────────────", attributes: [.foregroundColor: colors.border, .font: AppFont.small])
            case .table(let headers, let rows, _):
                // Compatibility renderer: the rich response view uses a real native column grid.
                let table = ([headers] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
                text = inline(table, theme: theme, fileLinks: fileLinks, references: references, lineBreaks: lineBreaks, rawHTML: rawHTML)
            }
            if lineBreaks { paragraph.paragraphSpacingBefore = 0 }
            let part = NSMutableAttributedString(attributedString: text)
            if case .heading = block, part.length > 0 {
                part.addAttribute(.agentMarkdownHeading, value: text.string, range: NSRange(location: 0, length: part.length))
            }
            part.append(NSAttributedString(string: "\n"))
            if case .quote = block {
                part.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: part.length)) { value, range, _ in
                    let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    style.headIndent += 16
                    style.firstLineHeadIndent += 16
                    part.addAttribute(.paragraphStyle, value: style, range: range)
                }
            } else {
                part.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: part.length))
            }
            if rawHTML { AgentInlineHTML.applyBaseDirection(to: part) }
            if block.isCodeLike {
                let first = (part.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                let firstStyle = paragraph.mutableCopy() as? NSMutableParagraphStyle ?? paragraph
                firstStyle.paragraphSpacingBefore = 10
                part.addAttribute(.paragraphStyle, value: firstStyle, range: first)
                let last = (part.string as NSString).paragraphRange(for: NSRange(location: max(0, part.length - 1), length: 0))
                let lastStyle = (part.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? paragraph
                lastStyle.paragraphSpacing = 16
                part.addAttribute(.paragraphStyle, value: lastStyle, range: last)
            }
            output.append(part)
        }
        if output.length > 0 { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
        return output
    }

    static func plain(_ source: String, theme: AppTheme, muted: Bool = false, monospaced: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = monospaced ? 3 : 5
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: source, attributes: [
            .font: monospaced ? AppFont.mono(12) : AppFont.system(14, weight: .light),
            .foregroundColor: muted ? theme.fgMuted : theme.fg, .paragraphStyle: paragraph,
        ])
    }

    static func inline(_ text: String, theme: AppTheme, font: NSFont = AppFont.system(14, weight: .light), color: NSColor? = nil,
                       fileLinks: Bool = false, references: [String: String] = [:], lineBreaks: Bool = false, normalizeWhitespace: Bool = true,
                       rawHTML: Bool = false) -> NSAttributedString {
        let colors = AgentMarkdownPalette(theme: theme)
        // Math is cut out first so references, escapes and emphasis never rewrite LaTeX.
        let math = AgentMarkdownMath.extract(text)
        // Assistant HTML becomes Markdown and placeholders before Foundation sees the source.
        let html = rawHTML ? AgentInlineHTML.extract(math.text) : AgentInlineHTML.Extraction(text: math.text)
        let text = AgentMarkdownSource.inlineSource(AgentMarkdownWhitespace.prepare(AgentMarkdownReferences.resolve(html.text, definitions: references)))
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.appliesSourcePositionAttributes = true
        let labels = AgentMarkdownSource.InlineLabels(text)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            let plain = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color ?? colors.body])
            AgentMarkdownMath.substitute(math.spans, in: plain, theme: theme)
            AgentInlineHTML.apply(html.pairs, to: plain, theme: theme)
            return plain
        }
        let result = NSMutableAttributedString(string: "")
        var lastThreadChip: String?
        for (runIndex, run) in parsed.runs.enumerated() {
            if let url = run.link, let thread = AgentThreadLink(url.absoluteString) {
                // One chip per link, even when emphasis splits its label into several runs.
                guard url.absoluteString != lastThreadChip else { continue }
                lastThreadChip = url.absoluteString
                let label = String(parsed[run.range].characters)
                result.append(AgentThreadLink.chip(thread, title: thread.chipTitle(label: label, knownTitle: nil), font: font,
                                                   color: colors.link, background: colors.link.withAlphaComponent(0.12), identity: "thread:\(runIndex)"))
                continue
            }
            lastThreadChip = nil
            let intent = run.inlinePresentationIntent ?? []
            let inheritedWeight = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? NSNumber
            var runFont = intent.contains(.code)
                ? AgentInlineCodeLayout.font(size: font.pointSize * 0.85, weight: NSFont.Weight(rawValue: inheritedWeight?.doubleValue ?? 0)) : font
            if intent.contains(.stronglyEmphasized) {
                if intent.contains(.code) { runFont = AgentInlineCodeLayout.font(size: runFont.pointSize, weight: .semibold) }
                else {
                    let descriptor = runFont.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue]])
                    runFont = NSFont(descriptor: descriptor, size: runFont.pointSize) ?? runFont
                }
            }
            if intent.contains(.emphasized) || font.fontDescriptor.symbolicTraits.contains(.italic) {
                runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color ?? colors.body]
            if intent.contains(.lineBreak) { attributes[.agentMarkdownHardBreak] = true }
            if intent.contains(.code) {
                attributes[.foregroundColor] = colors.heading
                attributes[.agentInlineCodeBackground] = colors.inlineCodeBackground
                attributes[.agentInlineCode] = true
                attributes[.agentInlineCodeIdentity] = String(runIndex)
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            // Inline images keep their alternative text; assistant prose swaps it for a thumbnail.
            if run.link == nil, let image = run.imageURL { attributes[.agentInlineMediaSource] = image.relativeString }
            let value = String(parsed[run.range].characters)
            let originalLabel = run.markdownSourcePosition.flatMap { labels.label(at: $0) } ?? value
            let protocolLabel = originalLabel.lowercased()
            let keepsProtocol = run.link != nil && (protocolLabel.hasPrefix("http://") || protocolLabel.hasPrefix("https://"))
            let target = run.link.flatMap { AgentResponseLink.parse($0.relativeString) }
                ?? (run.link == nil && intent.contains(.code) && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                    ? AgentResponseLink.inferredFile(value) : nil)
            if let target {
                switch target {
                case .fragment where run.link != nil:
                    attributes[.link] = target.attributeURL
                    attributes[.foregroundColor] = colors.link
                case .external(let url) where run.link != nil:
                    attributes[.link] = url
                    attributes[.foregroundColor] = colors.link
                case .file(let path, let line) where fileLinks:
                    let column = run.link.flatMap { AgentConversationFileTarget.parse($0.relativeString)?.column }
                    attributes[.link] = AgentResponseLink.fileURL(path: path, line: line, column: column)
                    attributes[.foregroundColor] = colors.link
                default: break
                }
            }
            if run.link != nil, let position = run.markdownSourcePosition {
                attributes[.agentExternalLinkIdentity] = labels.identity(at: position)
            }
            if let url = run.link, url.scheme == "tab-agent-footnote",
               let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                attributes[.link] = url
                attributes[.font] = AppFont.system(11, weight: .semibold)
                attributes[.foregroundColor] = colors.link
                if url.host == "reference" { attributes[.baselineOffset] = 4 }
                if let anchor = parts.queryItems?.first(where: { $0.name == "anchor" })?.value {
                    attributes[.agentMarkdownAnchor] = anchor
                }
            }
            if let url = run.link, url.scheme != "tab-agent-footnote",
               let position = run.markdownSourcePosition,
               let label = labels.label(at: position), label != text {
                let content = NSMutableAttributedString(attributedString: inline(label, theme: theme, font: runFont,
                    color: attributes[.foregroundColor] as? NSColor, fileLinks: false, lineBreaks: lineBreaks, normalizeWhitespace: false))
                let range = NSRange(location: 0, length: content.length)
                if let link = attributes[.link] { content.addAttribute(.link, value: link, range: range) }
                if let identity = attributes[.agentExternalLinkIdentity] { content.addAttribute(.agentExternalLinkIdentity, value: identity, range: range) }
                var codeIdentities: [(NSRange, String)] = []
                content.enumerateAttribute(.agentInlineCodeIdentity, in: range) { value, span, _ in
                    if let identity = value as? String { codeIdentities.append((span, "label:\(runIndex):\(identity)")) }
                }
                for (span, identity) in codeIdentities { content.addAttribute(.agentInlineCodeIdentity, value: identity, range: span) }
                if keepsProtocol, content.length > 0 { content.addAttribute(.agentExternalLinkProtocol, value: true, range: NSRange(location: 0, length: 1)) }
                if let strike = attributes[.strikethroughStyle] { content.addAttribute(.strikethroughStyle, value: strike, range: range) }
                result.append(content)
            } else {
                if keepsProtocol { attributes[.agentExternalLinkProtocol] = true }
                result.append(NSAttributedString(string: value, attributes: attributes))
            }
        }
        if normalizeWhitespace { result.setAttributedString(AgentMarkdownWhitespace.collapse(result, lineBreaks: lineBreaks)) }
        AgentMarkdownMath.substitute(math.spans, in: result, theme: theme)
        AgentInlineHTML.apply(html.pairs, to: result, theme: theme)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            detector.enumerateMatches(in: result.string, range: NSRange(location: 0, length: result.length)) { match, _, _ in
                guard let match, let url = match.url, match.range.length > 0,
                      result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil,
                      result.attribute(.agentInlineCode, at: match.range.location, effectiveRange: nil) == nil,
                      let target = AgentResponseLink.parse(url.absoluteString), case .external = target else { return }
                result.addAttributes([.link: url, .foregroundColor: colors.link, .agentExternalLinkProtocol: true, .agentExternalLinkIdentity: "detected:\(match.range.location):\(match.range.length)"], range: match.range)
            }
        }
        result.addAttribute(.agentMarkdownLineFont, value: font, range: NSRange(location: 0, length: result.length))
        if normalizeWhitespace {
            AgentExternalLinkLayout.mark(result, fontSize: font.pointSize, color: colors.link, theme: theme)
            AgentInlineCodeLayout.mark(result)
        }
        return result
    }
}

private extension NSAttributedString.Key {
    static let agentCodeBackground = NSAttributedString.Key("TabAgentCodeBackground")
    static let agentQuoteBorder = NSAttributedString.Key("TabAgentQuoteBorder")
    static let agentInlineCode = NSAttributedString.Key("TabAgentInlineCode")
}

extension NSAttributedString.Key {
    static let agentMarkdownLineFont = NSAttributedString.Key("TabAgentMarkdownLineFont")
    static let agentTerminalBackground = NSAttributedString.Key("TabAgentTerminalBackground")
    static let agentInlineCodeBackground = NSAttributedString.Key("TabAgentInlineCodeBackground")
    /// A layout-manager temporary attribute (an `NSColor`) that Find paints behind its
    /// matches. It has its own key so that other temporary backgrounds, such as a followed
    /// citation, never erase it or are erased by it.
    static let agentFindHighlight = NSAttributedString.Key("TabFindHighlight")
}

/// Draw a single full-width surface around each fenced block, including wrapped lines.
private final class AgentTextLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override init() {
        super.init()
        // Rich-text rows ensure layout when measured. Background TextKit work
        // would queue work for evicted rows and delay the main run loop.
        backgroundLayoutEnabled = false
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes indexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange range: NSRange) -> Int {
        guard let textStorage else { return 0 }
        var adjusted = Array(UnsafeBufferPointer(start: glyphs, count: range.length))
        var properties = Array(UnsafeBufferPointer(start: props, count: range.length))
        var changed = false
        for index in adjusted.indices {
            let key: NSAttributedString.Key = textStorage.attribute(.agentExternalLinkGroup, at: indexes[index], effectiveRange: nil) != nil ? .agentExternalLinkGroup : .agentInlineCodeBoundary
            guard textStorage.attribute(key, at: indexes[index], effectiveRange: nil) != nil else { continue }
            var character = NSRange()
            _ = textStorage.attribute(key, at: indexes[index], effectiveRange: &character)
            adjusted[index] = 0
            properties[index] = indexes[index] == character.location && (index == 0 || indexes[index - 1] != indexes[index]) ? .controlCharacter : .null
            changed = true
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(&adjusted, properties: &properties, characterIndexes: indexes, font: font, forGlyphRange: range)
        return range.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt index: Int) -> Bool {
        allowsLinkBreak(at: index)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByHyphenatingBeforeCharacterAt index: Int) -> Bool {
        allowsLinkBreak(at: index)
    }

    private func allowsLinkBreak(at index: Int) -> Bool {
        guard let textStorage, index < textStorage.length else { return true }
        var range = NSRange()
        guard textStorage.attribute(.agentExternalLinkNoBreak, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: textStorage.length)) != nil else { return true }
        return index == range.location
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let textStorage else { return false }
        let range = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var lineFont: NSFont?
        textStorage.enumerateAttribute(.agentMarkdownLineFont, in: range) { value, _, stop in
            if let font = value as? NSFont { lineFont = font; stop.pointee = true }
        }
        guard let font = lineFont,
              let paragraph = textStorage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
              paragraph.minimumLineHeight > 0, paragraph.minimumLineHeight == paragraph.maximumLineHeight else { return false }
        // Chromium rounds font ascent/descent, then floors half-leading. TextKit
        // places all extra leading above the baseline. Preserve table padding and
        // paragraph-before spacing already included in the supplied baseline.
        let ascent = font.ascender.rounded(), descent = (-font.descender).rounded()
        let lineHeight = paragraph.minimumLineHeight
        let browserBaseline = ascent + floor((lineHeight - ascent - descent) / 2)
        baselineOffset.pointee -= lineHeight - descent - browserBaseline
        return true
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt index: Int) -> NSLayoutManager.ControlCharacterAction {
        let hasBox = textStorage?.attribute(.agentExternalLinkFontSize, at: index, effectiveRange: nil) != nil || textStorage?.attribute(.agentInlineCodeBoundary, at: index, effectiveRange: nil) != nil
        return hasBox ? .whitespace : action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer, proposedLineFragment: NSRect, glyphPosition: NSPoint,
                       characterIndex: Int) -> NSRect {
        guard let textStorage else { return .zero }
        let size = textStorage.attribute(.agentExternalLinkFontSize, at: characterIndex, effectiveRange: nil) as? CGFloat
        let key: NSAttributedString.Key = size != nil ? .agentExternalLinkGroup : .agentInlineCodeBoundary
        var range = NSRange()
        guard textStorage.attribute(key, at: characterIndex, effectiveRange: &range) != nil else { return .zero }
        let label = textStorage.attributedSubstring(from: range)
        let codeWidth = AgentInlineCodeLayout.additionalWidth(label)
        return NSRect(x: 0, y: 0, width: label.size().width + (size.map { AgentExternalLinkLayout.inset(fontSize: $0) } ?? 0) + codeWidth, height: label.size().height)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for key in [NSAttributedString.Key.agentExternalLinkGroup, .agentInlineCodeBoundary] {
            textStorage.enumerateAttribute(key, in: visible) { value, visibleRange, _ in
                guard value != nil else { return }
                if key == .agentInlineCodeBoundary, textStorage.attribute(.agentExternalLinkGroup, at: visibleRange.location, effectiveRange: nil) != nil { return }
                var range = NSRange()
                _ = textStorage.attribute(key, at: visibleRange.location, effectiveRange: &range)
                let size = textStorage.attribute(.agentExternalLinkFontSize, at: range.location, effectiveRange: nil) as? CGFloat
                guard let font = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
                let glyph = self.glyphIndexForCharacter(at: range.location)
                let fragment = self.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let location = self.location(forGlyphAt: glyph)
                if let size, let url = textStorage.attribute(.link, at: range.location, effectiveRange: nil) as? URL {
                    let color = textStorage.attribute(.agentExternalLinkColor, at: range.location, effectiveRange: nil) as? NSColor ?? .linkColor
                    // Native text drawing runs on the UI actor; Foundation's enumeration
                    // callback does not carry that isolation in its signature.
                    let fileIcon = textStorage.attribute(.agentFileLinkImage, at: range.location, effectiveRange: nil) as? NSImage
                    let icon = fileIcon ?? MainActor.assumeIsolated { AgentLinkFavicon.shared.image(for: url, color: color, manager: self) }
                    if let image = icon {
                        let rect = NSRect(x: origin.x + fragment.minX + location.x + size * 0.25,
                            y: origin.y + fragment.minY + location.y - 14 + size * 0.125, width: 14, height: 14)
                        NSGraphicsContext.saveGraphicsState()
                        if fileIcon == nil && AgentLinkFavicon.host(for: url).flatMap(AgentLinkFavicon.brand(for:)) == nil {
                            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).addClip()
                        }
                        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                }
                let label = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
                label.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: label.length))
                label.removeAttribute(.link, range: NSRange(location: 0, length: label.length))
                let leading = textStorage.attribute(.agentInlineCodeLeading, at: range.location, effectiveRange: nil) as? CGFloat ?? 0
                label.draw(at: NSPoint(x: origin.x + fragment.minX + location.x + (size.map { AgentExternalLinkLayout.inset(fontSize: $0) } ?? 0) + leading,
                                       y: origin.y + fragment.minY + location.y - font.ascender))
            }
        }
        textStorage.enumerateAttribute(.agentListBullet, in: visible) { value, range, _ in
            guard let color = value as? NSColor,
                  let font = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont,
                  let style = textStorage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle else { return }
            let glyph = self.glyphIndexForCharacter(at: range.location)
            let fragment = self.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = origin.y + fragment.minY + self.location(forGlyphAt: glyph).y
            let rect = AgentListBullet.rect(textX: origin.x + fragment.minX + style.headIndent, baseline: baseline, font: font)
            AgentListBullet.draw((textStorage.string as NSString).substring(with: range), rect: rect, color: color)
        }
        textStorage.enumerateAttribute(.agentTaskCheckbox, in: visible) { value, range, _ in
            guard let state = value as? Int else { return }
            let glyph = self.glyphIndexForCharacter(at: range.location)
            let fragment = self.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = self.location(forGlyphAt: glyph)
            let style = textStorage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            MainActor.assumeIsolated {
                AgentTaskCheckbox.draw(state: state, in: NSRect(x: origin.x + fragment.minX + location.x,
                    y: origin.y + fragment.minY + (style?.paragraphSpacingBefore ?? 0) + AgentTaskCheckbox.top,
                    width: AgentTaskCheckbox.size, height: AgentTaskCheckbox.size))
            }
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let textStorage, let container = textContainers.first {
            let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            textStorage.enumerateAttribute(.agentInlineCodeIdentity, in: visible) { value, range, _ in
                guard value != nil, let color = textStorage.attribute(.agentInlineCodeBackground, at: range.location, effectiveRange: nil) as? NSColor,
                      let font = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
                let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                self.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
                    let part = NSIntersectionRange(glyphs, lineGlyphs)
                    guard part.length > 0 else { return }
                    let baseline = fragment.minY + self.location(forGlyphAt: part.location).y
                    let character = self.characterIndexForGlyph(at: part.location)
                    let linkSize = textStorage.attribute(.agentExternalLinkFontSize, at: character, effectiveRange: nil) as? CGFloat
                    let inset = linkSize.map { AgentExternalLinkLayout.inset(fontSize: $0) } ?? 0
                    let leadingClone = part.location > glyphs.location ? AgentInlineCodeLayout.inset(font: font) : 0
                    let trailingClone = NSMaxRange(part) < NSMaxRange(glyphs) ? AgentInlineCodeLayout.inset(font: font) : 0
                    let painted = trailingClone > 0 ? AgentInlineCodeLayout.visibleGlyphs(part, manager: self, storage: textStorage) : part
                    let used = self.boundingRect(forGlyphRange: painted, in: container)
                    let rect = AgentInlineCodeLayout.backgroundRect(x: origin.x + used.minX + inset - leadingClone,
                        width: used.width - inset + leadingClone + trailingClone, baseline: origin.y + baseline, font: font)
                    color.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                }
            }
            textStorage.enumerateAttribute(.agentTerminalBackground, in: visible) { value, range, _ in
                guard let color = value as? NSColor,
                      let font = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
                let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                color.setFill()
                self.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
                    let fragment = NSIntersectionRange(glyphs, lineGlyphs)
                    guard fragment.length > 0 else { return }
                    let used = self.boundingRect(forGlyphRange: fragment, in: container)
                    // CSS inline backgrounds cover the font box, not the full relaxed line height.
                    let height = floor(font.ascender - font.descender)
                    NSRect(x: origin.x + used.minX, y: origin.y + used.midY - height / 2,
                           width: used.width, height: height).fill()
                }
            }
            textStorage.enumerateAttribute(.agentQuoteBorder, in: visible) { value, range, _ in
                guard let color = value as? NSColor else { return }
                let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let used = self.boundingRect(forGlyphRange: glyphs, in: container)
                color.setFill()
                NSRect(x: origin.x + 2, y: origin.y + used.minY, width: 2, height: used.height).fill()
            }
            textStorage.enumerateAttribute(.agentCodeBackground, in: visible) { value, range, _ in
                guard let color = value as? NSColor else { return }
                var fullRange = NSRange()
                _ = textStorage.attribute(.agentCodeBackground, at: range.location,
                    longestEffectiveRange: &fullRange, in: NSRange(location: 0, length: textStorage.length))
                let glyphs = self.glyphRange(forCharacterRange: fullRange, actualCharacterRange: nil)
                let used = self.boundingRect(forGlyphRange: glyphs, in: container)
                let rect = NSRect(x: origin.x, y: origin.y + used.minY - 6,
                                  width: container.containerSize.width, height: used.height + 12)
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            }
            drawFindHighlights(in: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil), container: container, at: origin)
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Find's matches, above block backgrounds and below text, selection and citations.
    private func drawFindHighlights(in visible: NSRange, container: NSTextContainer, at origin: NSPoint) {
        var location = visible.location
        while location < NSMaxRange(visible) {
            var effective = NSRange()
            let color = temporaryAttribute(.agentFindHighlight, atCharacterIndex: location,
                                           longestEffectiveRange: &effective, in: visible) as? NSColor
            defer { location = max(location + 1, NSMaxRange(effective)) }
            guard let color, effective.length > 0 else { continue }
            color.setFill()
            let glyphs = glyphRange(forCharacterRange: effective, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                rect.offsetBy(dx: origin.x, dy: origin.y).fill()
            }
        }
    }
}

/// A noneditable, selectable TextKit view measured at its actual row width.
/// CSS nowrap can overflow a narrow line. Widen only the fragment starting
/// with that prefix, leaving subsequent lines at the requested container width.
private final class AgentTextContainer: NSTextContainer {
    var requestedWidth: CGFloat = 1 {
        didSet { if oldValue != requestedWidth { layoutManager?.textContainerChangedGeometry(self) } }
    }
    override var isSimpleRectangularTextContainer: Bool { false }

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var rect = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex,
                                          writingDirection: baseWritingDirection, remaining: remainingRect)
        rect.size.width = min(rect.width, max(0, requestedWidth - rect.minX))
        guard let storage = layoutManager?.textStorage, characterIndex < storage.length else { return rect }
        rect = AgentInlineCodeLayout.lineFragment(rect, storage: storage, at: characterIndex)
        var prefix = NSRange()
        guard storage.attribute(.agentExternalLinkNoBreak, at: characterIndex, longestEffectiveRange: &prefix, in: NSRange(location: 0, length: storage.length)) != nil,
              prefix.location == characterIndex,
              let fontSize = storage.attribute(.agentExternalLinkFontSize, at: characterIndex, effectiveRange: nil) as? CGFloat else { return rect }
        let label = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: prefix))
        label.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: label.length))
        rect.size.width = max(rect.width, label.size().width + AgentExternalLinkLayout.inset(fontSize: fontSize) + AgentInlineCodeLayout.additionalWidth(label) + lineFragmentPadding * 2)
        return rect
    }
}

@MainActor
final class AgentRichTextView: NSTextView {
    private let ownedStorage: NSTextStorage?
    /// Metadata tooltips over file links; nil unless a conversation supplies its services.
    private(set) var fileLinkHover: AgentFileLinkHover?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer? = nil) {
        let resolved: NSTextContainer
        if let container {
            ownedStorage = nil
            resolved = container
        } else {
            let storage = NSTextStorage()
            let manager = AgentTextLayoutManager()
            resolved = AgentTextContainer(containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(manager)
            manager.addTextContainer(resolved)
            ownedStorage = storage
        }
        super.init(frame: frameRect, textContainer: resolved)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        linkTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue]
        setAccessibilityRole(.textArea)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The nearest enclosing view that offers transcript selection actions.
    var textSelectionHost: AgentTextSelectionHost? {
        var ancestor = superview
        while let view = ancestor {
            if let host = view as? AgentTextSelectionHost { return host }
            ancestor = view.superview
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let host = textSelectionHost
        host?.textSelectionWillBegin(in: self, extending: !event.modifierFlags.intersection([.shift, .command]).isEmpty)
        // NSTextView tracks the drag until mouse-up before returning.
        super.mouseDown(with: event)
        host?.textSelectionDidEnd(in: self)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting, selectedRange().length == 0 else { return }
        textSelectionHost?.textSelectionDidCollapse(in: self)
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        textSelectionHost?.textSelectionDidCollapse(in: self)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, textSelectionHost?.transcriptDidPressEscape() == true { return }
        super.keyDown(with: event)
    }

    override func copy(_ sender: Any?) {
        if textSelectionHost?.copyTextSelection(from: self) == true { return }
        super.copy(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = selectionMenu(super.menu(for: event))
        let links = linkMenuItems(at: convert(event.locationInWindow, from: nil))
        guard !links.isEmpty else { return menu }
        // A right-clicked file or web link puts its own actions first.
        let result = menu ?? NSMenu()
        for (index, item) in links.enumerated() { result.insertItem(item, at: index) }
        if result.items.count > links.count { result.insertItem(.separator(), at: links.count) }
        return result
    }

    private func selectionMenu(_ menu: NSMenu?) -> NSMenu? {
        guard let menu, let items = textSelectionHost?.textSelectionMenuItems(for: self), !items.isEmpty else { return menu }
        // The transcript's Copy replaces the standard item; it adds HTML and a context fragment.
        for item in menu.items where item.action == #selector(NSText.copy(_:)) { menu.removeItem(item) }
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
        menu.insertItem(.separator(), at: items.count)
        return menu
    }

    /// The context-menu actions of the file or web link at `point`, when the conversation supplies them.
    func linkMenuItems(at point: NSPoint) -> [NSMenuItem] {
        guard let services = fileLinkHover?.services,
              let target = AgentLinkMenu.Target(link: AgentLinkMenu.link(at: point, in: self)) else { return [] }
        return AgentLinkMenu.menuItems(for: target, services: services)
    }

    func setContent(_ content: NSAttributedString) {
        guard textStorage?.isEqual(to: content) != true else { return }
        let selection = selectedRanges
        textStorage?.setAttributedString(content)
        let length = content.length
        selectedRanges = selection.map { value in
            let range = value.rangeValue
            return NSValue(range: NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location))))
        }
    }

    /// Enables file-link metadata tooltips backed by `services`, or removes them.
    func setFileLinkServices(_ services: AgentConversationLinkServices?, missingColor: NSColor, theme: AppTheme) {
        guard let services else {
            fileLinkHover?.cancelRequests()
            fileLinkHover?.uninstall()
            fileLinkHover = nil
            return
        }
        let hover = fileLinkHover ?? AgentFileLinkHover(text: self)
        hover.services = services
        hover.missingColor = missingColor
        hover.theme = theme
        fileLinkHover = hover
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { fileLinkHover?.cancelRequests() }
    }

    func height(for width: CGFloat) -> CGFloat {
        guard let textContainer, let layoutManager else { return 0 }
        let requested = max(1, width)
        if let container = textContainer as? AgentTextContainer {
            let prefixWidth = textStorage.map { AgentExternalLinkLayout.minimumPrefixWidth($0) } ?? 0
            container.requestedWidth = requested
            container.containerSize = NSSize(width: max(requested, ceil(prefixWidth)), height: .greatestFiniteMagnitude)
        } else { textContainer.containerSize = NSSize(width: requested, height: .greatestFiniteMagnitude) }
        layoutManager.ensureLayout(for: textContainer)
        return max(1, layoutManager.usedRect(for: textContainer).maxY)
    }
}
