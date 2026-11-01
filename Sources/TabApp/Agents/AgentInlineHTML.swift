import AppKit

/// The safe inline-HTML subset of assistant Markdown, matching the removed web renderer's
/// sanitizer. One linear scan cuts tags out of inline source: formatting tags become pairs of
/// private-use placeholder characters that Foundation's Markdown parser passes through, links and
/// images become their Markdown forms, `<code>` becomes a code span and `<br>` a hard break.
/// After rendering, `apply` styles each placeholder pair's range and removes the placeholders.
/// `<script>` and `<style>` lose their content; every other unknown tag keeps only its text.
@MainActor
enum AgentInlineHTML {
    /// Inline source larger than this is rendered without the HTML pass.
    static let maximumSource = 200_000
    /// Placeholders live in Supplementary Private Use Area-A, away from math's BMP placeholders.
    private static let placeholderBase: UInt32 = 0xF0000
    private static let maximumPairs = 30_000

    /// A presentation applied to the text between one placeholder pair.
    enum Style: Equatable {
        case bold, italic, strikethrough, underline, lowered, raised, highlight, small
        /// A fragment target for `[text](#id)`.
        case anchor(String)
        /// Bidirectional text; `override` forces the direction like `<bdo>`.
        case direction(NSWritingDirection, override: Bool)
    }

    /// Source with HTML removed, and the styles of its placeholder pairs.
    struct Extraction: Equatable {
        var text: String
        /// Styles of pair `n`, whose opening placeholder is `placeholderBase + 2n`.
        var pairs: [[Style]] = []
    }

    struct Tag: Equatable {
        /// Lowercased element name.
        var name: String
        var closing: Bool
        var selfClosing: Bool
        /// Lowercased attribute names with entity-decoded values.
        var attributes: [String: String]
        var raw: String
    }

    private static let voidElements: Set<String> = ["br", "hr", "img", "wbr", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "param"]
    private static let rawTextElements: Set<String> = ["script", "style", "textarea", "title", "noscript", "template"]
    private static let codeElements: Set<String> = ["code", "kbd", "samp", "tt"]
    private static let tableElements: Set<String> = ["table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption", "colgroup", "col"]

    // MARK: Inline extraction

    /// Replaces the supported inline HTML in `text` (already cut free of math) with Markdown and
    /// placeholders. Text without `<` is returned unchanged.
    static func extract(_ text: String) -> Extraction {
        guard text.contains("<"), text.utf8.count <= maximumSource,
              !text.unicodeScalars.contains(where: { $0.value >= placeholderBase }) else { return Extraction(text: text) }
        let (tokens, removed) = tokenize(Array(text))
        guard removed || tokens.contains(where: { if case .text = $0 { return false }; return true }) else { return Extraction(text: text) }
        return emit(tokens)
    }

    private enum Token {
        case text(String)
        case tag(Tag)
        /// A `<code>`/`<kbd>` element's decoded text content.
        case code(String)
    }

    /// Tokens of `characters`, and whether comments or raw-text elements were removed.
    private static func tokenize(_ characters: [Character]) -> ([Token], Bool) {
        var tokens: [Token] = []
        var removed = false
        var buffer = ""
        let ticks = BacktickRuns(characters)
        func flush() { if !buffer.isEmpty { tokens.append(.text(buffer)); buffer = "" } }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                buffer.append(character); buffer.append(characters[index + 1]); index += 2; continue
            }
            if character == "`" {
                let end = ticks.spanEnd(from: index, in: characters)
                buffer += String(characters[index..<end]); index = end; continue
            }
            if character == "]", index + 1 < characters.count, characters[index + 1] == "(" {
                let end = destinationEnd(characters, from: index + 2)
                buffer += String(characters[index..<end]); index = end; continue
            }
            guard character == "<" else { buffer.append(character); index += 1; continue }
            if let end = commentEnd(characters, from: index) { flush(); removed = true; index = end; continue }
            guard let (tag, end) = parseTag(characters, at: index) else { buffer.append(character); index += 1; continue }
            flush()
            if !tag.closing, !tag.selfClosing, rawTextElements.contains(tag.name) {
                index = closingTagRange(tag.name, in: characters, from: end)?.upperBound ?? characters.count
                removed = true
                continue
            }
            if !tag.closing, !tag.selfClosing, codeElements.contains(tag.name),
               let close = closingTagRange(tag.name, in: characters, from: end) {
                tokens.append(.code(decodeEntities(strippingTags(Array(characters[end..<close.lowerBound])))))
                index = close.upperBound
                continue
            }
            tokens.append(.tag(tag))
            index = end
        }
        flush()
        return (tokens, removed)
    }

    private static func emit(_ tokens: [Token]) -> Extraction {
        // Pair each opening tag with its closing tag; unmatched tags are dropped.
        var partner: [Int: Int] = [:]
        var stack: [(name: String, index: Int)] = []
        for (index, token) in tokens.enumerated() {
            guard case .tag(let tag) = token, !voidElements.contains(tag.name), !tag.selfClosing else { continue }
            if !tag.closing { stack.append((tag.name, index)); continue }
            guard let match = stack.lastIndex(where: { $0.name == tag.name }) else { continue }
            partner[stack[match].index] = index
            partner[index] = stack[match].index
            stack.removeSubrange(match...)
        }
        var output = ""
        var pairs: [[Style]] = []
        var closers: [Int: String] = [:]
        func placeholders(_ styles: [Style]) -> (open: String, close: String)? {
            guard !styles.isEmpty, pairs.count < maximumPairs,
                  let open = UnicodeScalar(placeholderBase + UInt32(pairs.count * 2)),
                  let close = UnicodeScalar(placeholderBase + UInt32(pairs.count * 2 + 1)) else { return nil }
            pairs.append(styles)
            return (String(Character(open)), String(Character(close)))
        }
        for (index, token) in tokens.enumerated() {
            switch token {
            case .text(let text): output += text
            case .code(let code): output += codeSpan(code)
            case .tag(let tag):
                if tableElements.contains(tag.name) { output += tag.raw; continue }
                if tag.name == "br" { output += "\\\n"; continue }
                if tag.name == "img" { output += image(tag); continue }
                if tag.closing { output += closers[index] ?? ""; continue }
                let styles = styles(for: tag)
                guard let close = partner[index] else {
                    // `<a name="x">` without content is commonly left unclosed.
                    if let anchor = anchorID(tag), let marks = placeholders([.anchor(anchor)]) { output += marks.open + marks.close }
                    continue
                }
                let destination = tag.name == "a" ? linkDestination(tag.attributes["href"]) : nil
                let marks = placeholders(styles)
                output += (marks?.open ?? "") + (destination == nil ? "" : "[")
                closers[close] = (destination.map { "](<\($0)>)" } ?? "") + (marks?.close ?? "")
            }
        }
        // A trailing break would render its backslash literally.
        while output.hasSuffix("\\\n") { output.removeLast(2) }
        return Extraction(text: output, pairs: pairs)
    }

    private static func styles(for tag: Tag) -> [Style] {
        var styles: [Style] = []
        switch tag.name {
        case "b", "strong": styles.append(.bold)
        case "i", "em", "cite", "dfn", "var": styles.append(.italic)
        case "s", "del", "strike": styles.append(.strikethrough)
        case "u", "ins": styles.append(.underline)
        case "sub": styles.append(.lowered)
        case "sup": styles.append(.raised)
        case "mark": styles.append(.highlight)
        case "small": styles.append(.small)
        case "bdo": styles.append(.direction(direction(tag.attributes["dir"]) ?? .leftToRight, override: true))
        default: break
        }
        if tag.name != "bdo", let direction = direction(tag.attributes["dir"]) {
            styles.append(.direction(direction, override: false))
        }
        if let anchor = anchorID(tag) { styles.append(.anchor(anchor)) }
        return styles
    }

    private static func direction(_ value: String?) -> NSWritingDirection? {
        switch value?.lowercased() {
        case "rtl": return .rightToLeft
        case "ltr": return .leftToRight
        default: return nil
        }
    }

    private static func anchorID(_ tag: Tag) -> String? {
        let raw = tag.attributes["id"] ?? (tag.name == "a" ? tag.attributes["name"] : nil)
        return raw.flatMap(AgentMarkdownFragments.anchorID)
    }

    /// A Markdown destination for `href`, or nil when the link must stay plain text: only web,
    /// mail, file and fragment targets are linked, like Markdown links.
    static func linkDestination(_ href: String?) -> String? {
        guard let href = href?.trimmingCharacters(in: .whitespaces), !href.isEmpty,
              !href.contains(where: { $0 == "<" || $0 == ">" || $0.isNewline }),
              AgentResponseLink.parse(href) != nil else { return nil }
        return href
    }

    /// `<img src alt>` as the equivalent Markdown image, or its alternative text when the source
    /// is not a web, file or relative path.
    static func image(_ tag: Tag) -> String {
        let alt = tag.attributes["alt"] ?? ""
        guard let source = tag.attributes["src"]?.trimmingCharacters(in: .whitespaces), !source.isEmpty,
              !source.contains(where: { $0 == "<" || $0 == ">" || $0.isNewline }) else { return escaped(alt) }
        if let scheme = URL(string: source)?.scheme?.lowercased(), !["http", "https", "file"].contains(scheme) { return escaped(alt) }
        return "![\(escaped(alt))](<\(source)>)"
    }

    private static func escaped(_ text: String) -> String {
        var output = ""
        for character in text {
            if "\\`*_[]<>!#~$".contains(character) { output.append("\\") }
            output.append(character.isNewline ? " " : character)
        }
        return output
    }

    private static func codeSpan(_ code: String) -> String {
        let content = code.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        guard !content.isEmpty else { return "" }
        var longest = 0, run = 0
        for character in content {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let padding = content.hasPrefix("`") || content.hasSuffix("`") ? " " : ""
        return fence + padding + content + padding + fence
    }

    // MARK: Tags

    /// The tag starting at `characters[index] == "<"` and the index after its `>`. Autolinks such
    /// as `<https://…>`, comparisons such as `a <b` and anything without a valid name are not tags.
    static func parseTag(_ characters: [Character], at index: Int) -> (Tag, Int)? {
        let limit = min(characters.count, index + 4096)
        var cursor = index + 1
        guard cursor < limit else { return nil }
        let closing = characters[cursor] == "/"
        if closing { cursor += 1 }
        guard cursor < limit, characters[cursor].isASCII, characters[cursor].isLetter else { return nil }
        var name = ""
        while cursor < limit, characters[cursor].isASCII, characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "-" {
            name.append(characters[cursor]); cursor += 1
        }
        guard cursor < limit, characters[cursor].isWhitespace || characters[cursor] == ">" || characters[cursor] == "/" else { return nil }
        var attributes: [String: String] = [:]
        var selfClosing = false
        while cursor < limit {
            while cursor < limit, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < limit else { return nil }
            if characters[cursor] == ">" { cursor += 1; break }
            if characters[cursor] == "/", cursor + 1 < limit, characters[cursor + 1] == ">" { selfClosing = true; cursor += 2; break }
            guard !closing else { return nil }
            var attribute = ""
            while cursor < limit, !characters[cursor].isWhitespace, !"=>/\"'<".contains(characters[cursor]) {
                attribute.append(characters[cursor]); cursor += 1
            }
            guard !attribute.isEmpty else { return nil }
            var value = ""
            var probe = cursor
            while probe < limit, characters[probe].isWhitespace { probe += 1 }
            if probe < limit, characters[probe] == "=" {
                cursor = probe + 1
                while cursor < limit, characters[cursor].isWhitespace { cursor += 1 }
                guard cursor < limit else { return nil }
                if characters[cursor] == "\"" || characters[cursor] == "'" {
                    let quote = characters[cursor]
                    cursor += 1
                    while cursor < limit, characters[cursor] != quote { value.append(characters[cursor]); cursor += 1 }
                    guard cursor < limit else { return nil }
                    cursor += 1
                } else {
                    while cursor < limit, !characters[cursor].isWhitespace, !"\"'=<>`".contains(characters[cursor]) {
                        value.append(characters[cursor]); cursor += 1
                    }
                    guard !value.isEmpty else { return nil }
                }
            }
            if attributes[attribute.lowercased()] == nil { attributes[attribute.lowercased()] = decodeEntities(value) }
        }
        guard cursor <= limit, cursor > index, characters[cursor - 1] == ">" else { return nil }
        return (Tag(name: name.lowercased(), closing: closing, selfClosing: selfClosing, attributes: attributes,
                    raw: String(characters[index..<cursor])), cursor)
    }

    private static func commentEnd(_ characters: [Character], from index: Int) -> Int? {
        guard index + 3 < characters.count, characters[index + 1] == "!", characters[index + 2] == "-", characters[index + 3] == "-" else { return nil }
        var cursor = index + 4
        while cursor + 2 < characters.count {
            if characters[cursor] == "-", characters[cursor + 1] == "-", characters[cursor + 2] == ">" { return cursor + 3 }
            cursor += 1
        }
        return nil
    }

    /// The range of the first `</name>` at or after `start`, case-insensitively.
    static func closingTagRange(_ name: String, in characters: [Character], from start: Int) -> Range<Int>? {
        var cursor = start
        while cursor + 1 < characters.count {
            if characters[cursor] == "<", characters[cursor + 1] == "/",
               let (tag, end) = parseTag(characters, at: cursor), tag.closing, tag.name == name {
                return cursor..<end
            }
            cursor += 1
        }
        return nil
    }

    /// Text content of an HTML fragment: tags and comments removed, entities kept encoded.
    static func strippingTags(_ characters: [Character]) -> String {
        var output = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "<" {
                if let end = commentEnd(characters, from: index) { index = end; continue }
                if let (_, end) = parseTag(characters, at: index) { index = end; continue }
            }
            output.append(characters[index]); index += 1
        }
        return output
    }

    private static func destinationEnd(_ characters: [Character], from start: Int) -> Int {
        var depth = 1
        var index = start
        while index < characters.count, depth > 0 {
            if characters[index] == "\\" { index = min(characters.count, index + 2); continue }
            if characters[index] == "(" { depth += 1 }
            if characters[index] == ")" { depth -= 1 }
            if characters[index].isNewline { return index }
            index += 1
        }
        return index
    }

    /// Matching backtick runs found by binary search, so code spans are skipped in linear time.
    private struct BacktickRuns {
        private var runs: [Int: [Int]] = [:]

        init(_ characters: [Character]) {
            var index = 0
            while index < characters.count {
                guard characters[index] == "`" else { index += 1; continue }
                let start = index
                while index < characters.count, characters[index] == "`" { index += 1 }
                runs[index - start, default: []].append(start)
            }
        }

        /// The index after the code span opening at `start`, or after the bare run.
        func spanEnd(from start: Int, in characters: [Character]) -> Int {
            var end = start
            while end < characters.count, characters[end] == "`" { end += 1 }
            let count = end - start
            let candidates = runs[count] ?? []
            var low = 0, high = candidates.count
            while low < high {
                let middle = (low + high) / 2
                if candidates[middle] < end { low = middle + 1 } else { high = middle }
            }
            return low < candidates.count ? candidates[low] + count : end
        }
    }

    // MARK: Entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "larr": "←", "rarr": "→",
        "uarr": "↑", "darr": "↓", "times": "×", "divide": "÷", "middot": "·", "bull": "•",
        "deg": "°", "plusmn": "±", "ne": "≠", "le": "≤", "ge": "≥", "zwj": "\u{200D}", "zwnj": "\u{200C}",
        "lrm": "\u{200E}", "rlm": "\u{200F}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
    ]

    /// Decodes named and numeric character references; unknown references stay as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "&",
                  let semicolon = characters[(index + 1)..<min(characters.count, index + 34)].firstIndex(of: ";") else {
                output.append(characters[index]); index += 1; continue
            }
            let name = String(characters[(index + 1)..<semicolon])
            var decoded: String?
            if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let value, value != 0, let scalar = UnicodeScalar(value) { decoded = String(Character(scalar)) }
                else if value != nil { decoded = "\u{FFFD}" }
            } else { decoded = namedEntities[name] }
            guard let decoded else { output.append(characters[index]); index += 1; continue }
            output += decoded
            index = semicolon + 1
        }
        return output
    }

    // MARK: Rendering

    /// Styles each placeholder pair's range in `result`, then removes the placeholders.
    static func apply(_ pairs: [[Style]], to result: NSMutableAttributedString, theme: AppTheme) {
        guard !pairs.isEmpty else { return }
        let limit = placeholderBase + UInt32(pairs.count * 2)
        var opens: [Int: Int] = [:], closes: [Int: Int] = [:]
        var positions: [Int] = []
        var offset = 0
        for scalar in result.string.unicodeScalars {
            if scalar.value >= placeholderBase, scalar.value < limit {
                let pair = Int(scalar.value - placeholderBase) / 2
                if (scalar.value - placeholderBase) % 2 == 0 { opens[pair] = offset } else { closes[pair] = offset }
                positions.append(offset)
            }
            offset += scalar.utf16.count
        }
        guard !positions.isEmpty else { return }
        let placeholderSet = Set(positions)
        let length = result.length
        var orphanAnchor: String?
        for (pair, styles) in pairs.enumerated() {
            guard let open = opens[pair], let close = closes[pair], close > open else { continue }
            let range = NSRange(location: open + 2, length: close - open - 2)
            for style in styles where !apply(style, range: range, to: result, theme: theme, placeholders: placeholderSet, length: length) {
                if case .anchor(let id) = style, orphanAnchor == nil { orphanAnchor = id }
            }
        }
        let text = result.string as NSString
        for position in positions.reversed() {
            result.deleteCharacters(in: NSRange(location: position, length: 2))
            // HTML collapses the spaces on either side of a removed tag into one.
            if position > 0, position < result.length,
               text.character(at: position - 1) == 32, (result.string as NSString).character(at: position) == 32 {
                result.deleteCharacters(in: NSRange(location: position, length: 1))
            }
        }
        // A paragraph holding only an anchor keeps an invisible character to scroll to.
        if let orphanAnchor, result.length == 0 {
            result.append(NSAttributedString(string: "\u{200B}", attributes: [.agentMarkdownAnchor: orphanAnchor]))
        }
    }

    /// Applies one style; false when an anchor found no character to mark.
    @discardableResult
    private static func apply(_ style: Style, range: NSRange, to result: NSMutableAttributedString, theme: AppTheme,
                              placeholders: Set<Int>, length: Int) -> Bool {
        if case .anchor(let id) = style {
            // An empty anchor marks the next visible character, or the previous one at the end.
            var target = range
            if target.length == 0 {
                var after = NSMaxRange(range) + 2
                while placeholders.contains(after) { after += 2 }
                var before = range.location - 3
                while before >= 0, placeholders.contains(before - 1) { before -= 2 }
                if after < length { target = NSRange(location: after, length: 1) }
                else if before >= 0 { target = NSRange(location: before, length: 1) }
                else { return false }
                // Surrogate pairs are anchored whole.
                target = (result.string as NSString).rangeOfComposedCharacterSequence(at: target.location)
            }
            result.addAttribute(.agentMarkdownAnchor, value: id, range: target)
            return true
        }
        guard range.length > 0 else { return true }
        switch style {
        case .bold:
            transformFonts(in: range, of: result) { font in
                let descriptor = font.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue]])
                return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            }
        case .italic:
            transformFonts(in: range, of: result) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
        case .strikethrough:
            result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .underline:
            result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .lowered, .raised:
            let raised = style == .raised
            result.enumerateAttribute(.font, in: range) { value, span, _ in
                guard let font = value as? NSFont else { return }
                result.addAttributes([
                    .font: NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 0.75) ?? font,
                    .baselineOffset: raised ? font.pointSize * 0.35 : -font.pointSize * 0.2,
                ], range: span)
            }
        case .highlight:
            result.addAttribute(.backgroundColor, value: theme.accentSoft, range: range)
        case .small:
            transformFonts(in: range, of: result) { NSFont(descriptor: $0.fontDescriptor, size: $0.pointSize * 0.85) ?? $0 }
        case .direction(let direction, let override):
            let format: NSWritingDirectionFormatType = override ? .override : .embedding
            result.addAttributes([
                .writingDirection: [NSNumber(value: direction.rawValue | format.rawValue)],
                .agentMarkdownBaseDirection: direction.rawValue,
            ], range: range)
        case .anchor: break
        }
        return true
    }

    private static func transformFonts(in range: NSRange, of result: NSMutableAttributedString, _ transform: (NSFont) -> NSFont) {
        result.enumerateAttribute(.font, in: range) { value, span, _ in
            guard let font = value as? NSFont else { return }
            result.addAttribute(.font, value: transform(font), range: span)
        }
    }

    /// Gives every paragraph holding a `dir` run that run's base writing direction.
    static func applyBaseDirection(to text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        var paragraphs: [(NSRange, Int)] = []
        text.enumerateAttribute(.agentMarkdownBaseDirection, in: whole) { value, range, _ in
            guard let raw = value as? Int else { return }
            let paragraph = (text.string as NSString).paragraphRange(for: range)
            if paragraphs.last?.0 != paragraph { paragraphs.append((paragraph, raw)) }
        }
        for (paragraph, raw) in paragraphs {
            guard let direction = NSWritingDirection(rawValue: raw) else { continue }
            text.enumerateAttribute(.paragraphStyle, in: paragraph) { value, range, _ in
                let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.baseWritingDirection = direction
                text.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
    }

    // MARK: Blocks

    private static let blockElements: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "hr", "pre", "div", "table", "details"]

    /// A standalone HTML block starting at `lines[index]` converted to Markdown: `<p>`, `<h1>`–`<h6>`,
    /// `<ul>`/`<ol>` of plain `<li>` items, `<blockquote>`, `<hr>` and `<pre><code>`. Returns nil
    /// for anything else, nested or unclosed, so the text renders as it was written.
    static func block(in lines: [String], at index: Int) -> (markdown: String, count: Int)? {
        let first = lines[index].trimmingCharacters(in: .whitespaces)
        guard first.hasPrefix("<"), let (tag, _) = parseTag(Array(first), at: 0), !tag.closing,
              ["p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "hr", "pre"].contains(tag.name) else { return nil }
        var end = index
        var size = 0
        if tag.name == "pre" {
            while end < lines.count, lines[end].range(of: "</pre", options: .caseInsensitive) == nil {
                size += lines[end].utf8.count; end += 1
                if size > maximumSource || end - index > 4000 { return nil }
            }
            guard end < lines.count else { return nil }
            end += 1
        } else {
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
                size += lines[end].utf8.count; end += 1
                if size > maximumSource || end - index > 4000 { return nil }
            }
        }
        let source = lines[index..<end].joined(separator: "\n")
        guard let markdown = convert(Array(source.trimmingCharacters(in: .whitespacesAndNewlines))) else { return nil }
        return (markdown, end - index)
    }

    /// Markdown for a sequence of top-level block elements separated only by whitespace.
    private static func convert(_ characters: [Character]) -> String? {
        var parts: [String] = []
        var index = 0
        while index < characters.count {
            if characters[index].isWhitespace { index += 1; continue }
            guard characters[index] == "<", let (tag, openEnd) = parseTag(characters, at: index), !tag.closing else { return nil }
            if tag.name == "hr" { parts.append("***"); index = openEnd; continue }
            guard !tag.selfClosing, let close = matchingClose(tag.name, in: characters, from: openEnd) else { return nil }
            let inner = Array(characters[openEnd..<close.lowerBound])
            guard let part = convert(tag, inner: inner) else { return nil }
            parts.append(part)
            index = close.upperBound
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private static func convert(_ tag: Tag, inner: [Character]) -> String? {
        switch tag.name {
        case "p", "h1", "h2", "h3", "h4", "h5", "h6":
            guard !containsBlockTag(inner) else { return nil }
            var content = String(inner).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            content = wrapped(content, tag: tag)
            if tag.name == "p" { return content.isEmpty ? nil : content }
            return String(repeating: "#", count: Int(String(tag.name.dropFirst())) ?? 1) + " " + content
        case "ul", "ol":
            guard let items = listItems(inner), !items.isEmpty else { return nil }
            let start = tag.name == "ol" ? (tag.attributes["start"].flatMap { Int($0) } ?? 1) : 1
            return items.enumerated().map { offset, item in
                (tag.name == "ol" ? "\(start + offset). " : "- ") + item
            }.joined(separator: "\n")
        case "blockquote":
            let text = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !String(inner).lowercased().contains("<blockquote") else { return nil }
            let body = text.hasPrefix("<") ? (convert(Array(text)) ?? text) : text
            return body.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        case "pre":
            var body = inner
            var info = ""
            let trimmed = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("<code") {
                let code = Array(trimmed)
                guard let (codeTag, codeEnd) = parseTag(code, at: 0), codeTag.name == "code",
                      let close = closingTagRange("code", in: code, from: codeEnd),
                      String(code[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                body = Array(code[codeEnd..<close.lowerBound])
                let classes = (codeTag.attributes["class"] ?? "").split(separator: " ")
                if let language = classes.first(where: { $0.hasPrefix("language-") || $0.hasPrefix("lang-") }) {
                    info = String(language.split(separator: "-", maxSplits: 1).last ?? "")
                }
            }
            var content = decodeEntities(strippingTags(body))
            if content.hasPrefix("\n") { content.removeFirst() }
            while content.hasSuffix("\n") { content.removeLast() }
            var longest = 0, run = 0
            for character in content {
                run = character == "`" ? run + 1 : 0
                longest = max(longest, run)
            }
            let fence = String(repeating: "`", count: max(3, longest + 1))
            return fence + info + "\n" + content + "\n" + fence
        default:
            return nil
        }
    }

    /// Carries `id` and `dir` into the converted block through an inline `<span>`.
    private static func wrapped(_ content: String, tag: Tag) -> String {
        var attributes = ""
        if let id = tag.attributes["id"] { attributes += " id=\"\(id.replacingOccurrences(of: "\"", with: ""))\"" }
        if let dir = direction(tag.attributes["dir"]) { attributes += dir == .rightToLeft ? " dir=\"rtl\"" : " dir=\"ltr\"" }
        return attributes.isEmpty ? content : "<span\(attributes)>" + content + "</span>"
    }

    private static func listItems(_ inner: [Character]) -> [String]? {
        var items: [String] = []
        var index = 0
        while index < inner.count {
            if inner[index].isWhitespace { index += 1; continue }
            guard inner[index] == "<", let (tag, end) = parseTag(inner, at: index), tag.name == "li", !tag.closing,
                  let close = closingTagRange("li", in: inner, from: end) else { return nil }
            let content = Array(inner[end..<close.lowerBound])
            guard !containsBlockTag(content) else { return nil }
            items.append(wrapped(String(content).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "), tag: tag))
            index = close.upperBound
        }
        return items
    }

    private static func containsBlockTag(_ characters: [Character]) -> Bool {
        var index = 0
        while index < characters.count {
            if characters[index] == "<", let (tag, end) = parseTag(characters, at: index) {
                if blockElements.contains(tag.name) { return true }
                index = end
                continue
            }
            index += 1
        }
        return false
    }

    /// The closing tag matching an element opened before `start`, counting nested same-name tags.
    private static func matchingClose(_ name: String, in characters: [Character], from start: Int) -> Range<Int>? {
        var depth = 1
        var index = start
        while index < characters.count {
            if characters[index] == "<", let (tag, end) = parseTag(characters, at: index), tag.name == name {
                if tag.closing { depth -= 1; if depth == 0 { return index..<end } }
                else if !tag.selfClosing { depth += 1 }
                index = end
                continue
            }
            index += 1
        }
        return nil
    }
}

extension NSAttributedString.Key {
    /// The base writing direction a `dir` run gives its paragraph, as an `NSWritingDirection` raw value.
    static let agentMarkdownBaseDirection = NSAttributedString.Key("TabAgentMarkdownBaseDirection")
}
