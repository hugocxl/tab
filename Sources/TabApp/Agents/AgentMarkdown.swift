import AppKit

/// Small native Markdown presentation layer. Foundation handles inline syntax; block structure
/// supplies readable typography without HTML, remote image fetches, or executable link schemes.
@MainActor
enum AgentMarkdown {
    enum TableAlignment: Equatable { case left, center, right }
    enum Block: Equatable {
        case paragraph(String)
        case heading(Int, String)
        case list(String, String, Int)
        case code(String, String)
        case quote(String)
        case divider
        case table([String], [[String]], [TableAlignment])
    }

    static func blocks(_ source: String) -> [Block] {
        AgentResponseParser.parse(source)
    }

    static func render(_ source: String, theme: AppTheme) -> NSAttributedString {
        render(blocks(source), theme: theme)
    }

    static func render(_ blocks: [Block], theme: AppTheme, fileLinks: Bool = false) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        for block in blocks {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            paragraph.paragraphSpacing = 12
            paragraph.lineBreakMode = .byWordWrapping
            let text: NSAttributedString
            switch block {
            case .paragraph(let content):
                text = inline(content, theme: theme, fileLinks: fileLinks)
            case .heading(let level, let content):
                let size: CGFloat = level == 1 ? 20 : level == 2 ? 18 : level == 3 ? 16 : 14
                paragraph.paragraphSpacingBefore = 8
                paragraph.paragraphSpacing = 10
                text = inline(content, theme: theme, font: AppFont.system(size, weight: .semibold), fileLinks: fileLinks)
            case .list(let marker, let content, let depth):
                paragraph.firstLineHeadIndent = CGFloat(depth) * 18
                paragraph.headIndent = CGFloat(depth) * 18 + max(20, (marker as NSString).size(withAttributes: [.font: AppFont.system(14)]).width + 7)
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
                paragraph.paragraphSpacing = 7
                let item = NSMutableAttributedString(string: marker + "\t", attributes: [.font: AppFont.system(14), .foregroundColor: theme.fgMuted])
                item.append(inline(content, theme: theme, fileLinks: fileLinks))
                text = item
            case .code(let language, let content):
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
                let quote = NSMutableAttributedString(attributedString: render(AgentResponseParser.parse(content), theme: theme, fileLinks: fileLinks))
                if quote.length > 0 {
                    quote.addAttribute(.agentQuoteBorder, value: theme.border, range: NSRange(location: 0, length: quote.length))
                }
                text = quote
            case .divider:
                paragraph.paragraphSpacingBefore = 4
                text = NSAttributedString(string: "────────────", attributes: [.foregroundColor: theme.border, .font: AppFont.small])
            case .table(let headers, let rows, _):
                // Compatibility renderer: the rich response view uses a real native column grid.
                let table = ([headers] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
                text = inline(table, theme: theme, fileLinks: fileLinks)
            }
            let part = NSMutableAttributedString(attributedString: text)
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
            if case .code = block {
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
            .font: monospaced ? AppFont.mono(12) : AppFont.system(14),
            .foregroundColor: muted ? theme.fgMuted : theme.fg, .paragraphStyle: paragraph,
        ])
    }

    static func inline(_ text: String, theme: AppTheme, font: NSFont = AppFont.system(14), color: NSColor? = nil,
                       fileLinks: Bool = false) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color ?? theme.fg])
        }
        let result = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var runFont = intent.contains(.code) ? AppFont.mono(12) : font
            if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color ?? theme.fg]
            if intent.contains(.code) {
                attributes[.backgroundColor] = theme.fg.withAlphaComponent(0.065)
                attributes[.agentInlineCode] = true
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let value = String(parsed[run.range].characters)
            let target = run.link.flatMap { AgentResponseLink.parse($0.relativeString) }
                ?? (run.link == nil && intent.contains(.code) && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                    ? AgentResponseLink.inferredFile(value) : nil)
            if let target {
                switch target {
                case .external(let url) where run.link != nil:
                    attributes[.link] = url
                    attributes[.foregroundColor] = theme.accent
                case .file where fileLinks:
                    attributes[.link] = target.attributeURL
                    attributes[.foregroundColor] = theme.accent
                default: break
                }
            }
            result.append(NSAttributedString(string: value, attributes: attributes))
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            detector.enumerateMatches(in: result.string, range: NSRange(location: 0, length: result.length)) { match, _, _ in
                guard let match, let url = match.url, match.range.length > 0,
                      result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil,
                      result.attribute(.agentInlineCode, at: match.range.location, effectiveRange: nil) == nil,
                      let target = AgentResponseLink.parse(url.absoluteString), case .external = target else { return }
                result.addAttributes([.link: url, .foregroundColor: theme.accent], range: match.range)
            }
        }
        return result
    }
}

private extension NSAttributedString.Key {
    static let agentCodeBackground = NSAttributedString.Key("TabAgentCodeBackground")
    static let agentQuoteBorder = NSAttributedString.Key("TabAgentQuoteBorder")
    static let agentInlineCode = NSAttributedString.Key("TabAgentInlineCode")
}

/// Draw a single full-width surface around each fenced block, including wrapped lines.
private final class AgentTextLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let textStorage, let container = textContainers.first {
            let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
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
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// A noneditable, selectable TextKit view measured at its actual row width.
@MainActor
final class AgentRichTextView: NSTextView {
    private let ownedStorage: NSTextStorage?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer? = nil) {
        let resolved: NSTextContainer
        if let container {
            ownedStorage = nil
            resolved = container
        } else {
            let storage = NSTextStorage()
            let manager = AgentTextLayoutManager()
            resolved = NSTextContainer(containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
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

    func height(for width: CGFloat) -> CGFloat {
        guard let textContainer, let layoutManager else { return 0 }
        textContainer.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return max(1, ceil(layoutManager.usedRect(for: textContainer).maxY))
    }
}
