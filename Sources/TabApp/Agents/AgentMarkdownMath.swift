import AppKit

/// LaTeX math in Markdown, following remark-math: `$…$` and `\(…\)` inline, `$$…$$` and
/// `\[…\]` as display math, plus ```` ```math ````, `latex` and `katex` fences. Code spans,
/// link destinations and escaped dollars stay literal, and an unclosed delimiter stays text
/// while a response streams.
@MainActor
enum AgentMarkdownMath {
    /// One math span cut out of inline source.
    struct Span: Equatable {
        var latex: String
        /// `$$…$$` and `\[…\]`: typeset in display style.
        var display: Bool
    }

    /// Fence languages rendered as a display equation instead of code.
    static let fenceLanguages: Set<String> = ["math", "latex", "katex"]

    /// The fence info's language, lowercased.
    static func fenceLanguage(_ info: String) -> String {
        info.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" }).first.map { $0.lowercased() } ?? ""
    }

    // MARK: Display blocks

    /// A display equation starting at `lines[index]`: `$$…$$` or `\[…\]` on one line, or an
    /// opening line, body lines and a closing line. Returns nil while the closing delimiter is
    /// missing, when text follows it, or when a blank line comes first, so the source renders as
    /// text until the equation is complete.
    static func displayBlock(in lines: [String], at index: Int) -> (latex: String, count: Int)? {
        let line = lines[index]
        guard line.prefix(while: { $0 == " " }).count < 4 else { return nil }
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        let delimiters: (open: String, close: String)
        if trimmed.hasPrefix("$$") { delimiters = ("$$", "$$") }
        else if trimmed.hasPrefix("\\[") { delimiters = ("\\[", "\\]") }
        else { return nil }
        let rest = String(trimmed.dropFirst(delimiters.open.count))
        if let close = rest.range(of: delimiters.close) {
            guard close.upperBound == rest.endIndex else { return nil }
            let latex = String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !latex.isEmpty, !(delimiters.open == "$$" && latex.hasPrefix("$")) else { return nil }
            return (latex, 1)
        }
        var body: [String] = rest.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [rest]
        var end = index + 1
        while end < lines.count {
            let next = lines[end].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if next.isEmpty { return nil }
            if let close = next.range(of: delimiters.close) {
                guard close.upperBound == next.endIndex else { return nil }
                let head = String(next[..<close.lowerBound])
                if !head.trimmingCharacters(in: .whitespaces).isEmpty { body.append(head) }
                let latex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !latex.isEmpty else { return nil }
                return (latex, end - index + 1)
            }
            body.append(lines[end])
            end += 1
        }
        return nil
    }

    // MARK: Inline spans

    /// Replaces each inline math span in `text` with one private-use placeholder character that
    /// Foundation's Markdown parser passes through, so emphasis, links and whitespace handling see
    /// a single opaque glyph. `spans` maps each placeholder back to its math.
    static func extract(_ text: String) -> (text: String, spans: [Character: Span]) {
        guard text.contains("$") || text.contains("\\(") || text.contains("\\[") else { return (text, [:]) }
        let characters = Array(text)
        let used = Set(text.unicodeScalars.filter { (0xE000...0xF8FF).contains($0.value) }.map(\.value))
        var nextPlaceholder: UInt32 = 0xE000
        var spans: [Character: Span] = [:]
        var output = ""
        func placeholder(for span: Span) -> Character? {
            while used.contains(nextPlaceholder) { nextPlaceholder += 1 }
            guard nextPlaceholder <= 0xF8FF, let scalar = UnicodeScalar(nextPlaceholder) else { return nil }
            nextPlaceholder += 1
            let character = Character(scalar)
            spans[character] = span
            return character
        }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                let next = characters[index + 1]
                if next == "(" || next == "[",
                   let close = find(next == "(" ? ["\\", ")"] : ["\\", "]"], in: characters, from: index + 2),
                   let latex = content(characters, index + 2, close), let mark = placeholder(for: Span(latex: latex, display: next == "[")) {
                    output.append(mark)
                    index = close + 2
                    continue
                }
                output.append(character)
                output.append(next)
                index += 2
                continue
            }
            if character == "`" {
                let end = codeSpanEnd(characters, from: index)
                output += String(characters[index..<end])
                index = end
                continue
            }
            if character == "]", index + 1 < characters.count, characters[index + 1] == "(" {
                let end = destinationEnd(characters, from: index + 2)
                output += String(characters[index..<end])
                index = end
                continue
            }
            if character == "<", let end = autolinkEnd(characters, from: index) {
                output += String(characters[index..<end])
                index = end
                continue
            }
            guard character == "$" else { output.append(character); index += 1; continue }
            var run = index
            while run < characters.count, characters[run] == "$" { run += 1 }
            let count = run - index
            if count == 2, let close = find(["$", "$"], in: characters, from: run),
               let latex = content(characters, run, close), let mark = placeholder(for: Span(latex: latex, display: true)) {
                output.append(mark)
                index = close + 2
                continue
            }
            if count == 1, let close = singleDollarClose(characters, from: run),
               let latex = content(characters, run, close), let mark = placeholder(for: Span(latex: latex, display: false)) {
                output.append(mark)
                index = close + 1
                continue
            }
            output += String(characters[index..<run])
            index = run
        }
        return (output, spans)
    }

    /// Swaps the placeholders `extract` left in `result` for typeset attachments, in place: each
    /// placeholder and its attachment character are one UTF-16 unit, so other ranges stay valid.
    static func substitute(_ spans: [Character: Span], in result: NSMutableAttributedString, theme: AppTheme) {
        guard !spans.isEmpty else { return }
        let string = result.string as NSString
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var location = 0
        while location < string.length {
            let unit = string.character(at: location)
            guard (0xE000...0xF8FF).contains(unit), let scalar = UnicodeScalar(unit),
                  let span = spans[Character(scalar)] else { location += 1; continue }
            var attributes = result.attributes(at: location, effectiveRange: nil)
            let font = attributes[.font] as? NSFont ?? AppFont.system(14)
            let color = attributes[.foregroundColor] as? NSColor ?? theme.fg
            attributes[.attachment] = attachment(span, fontSize: font.pointSize, color: color, errorColor: theme.danger, scale: scale)
            attributes[.toolTip] = span.latex
            attributes[.agentMathSource] = span.latex
            result.replaceCharacters(in: NSRange(location: location, length: 1),
                                     with: NSAttributedString(string: "\u{FFFC}", attributes: attributes))
            location += 1
        }
    }

    // MARK: Attachments

    private struct AttachmentKey: Hashable {
        var span: String
        var display: Bool
        var fontSize: CGFloat
        var color: NSColor
        var errorColor: NSColor
        var scale: CGFloat
    }

    private static var attachments: [AttachmentKey: NSTextAttachment] = [:]
    private static let attachmentCapacity = 512

    /// The math size relative to its surrounding text, as KaTeX renders it (1.21em).
    static let relativeSize: CGFloat = 1.21

    /// A cached image attachment whose bounds put the math baseline on the text baseline.
    /// Reusing the same attachment for identical math and colors keeps attributed strings equal
    /// across streaming updates, so unchanged prose is not laid out again.
    static func attachment(_ span: Span, fontSize: CGFloat, color: NSColor, errorColor: NSColor, scale: CGFloat) -> NSTextAttachment {
        let key = AttachmentKey(span: span.latex, display: span.display, fontSize: fontSize, color: color, errorColor: errorColor, scale: scale)
        if let cached = attachments[key] { return cached }
        let options = AgentMathTypesetter.Options(displayMode: span.display, fontSize: (fontSize * relativeSize).rounded(),
                                                  color: color, errorColor: errorColor)
        let rendered = AgentMathTypesetter.image(span.latex, options: options, scale: scale)
        let attachment = NSTextAttachment()
        attachment.image = rendered.image
        attachment.bounds = CGRect(x: 0, y: rendered.baselineOffset, width: rendered.image.size.width, height: rendered.image.size.height)
        if attachments.count >= attachmentCapacity { attachments.removeAll(keepingCapacity: true) }
        attachments[key] = attachment
        return attachment
    }

    // MARK: Scanning

    private static func content(_ characters: [Character], _ start: Int, _ end: Int) -> String? {
        guard start < end else { return nil }
        let latex = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return latex.isEmpty ? nil : latex
    }

    /// The index of `needle` after `start`, skipping escaped characters; math never spans code.
    private static func find(_ needle: [Character], in characters: [Character], from start: Int) -> Int? {
        var index = start
        while index + needle.count <= characters.count {
            if Array(characters[index..<index + needle.count]) == needle { return index }
            if characters[index] == "`" { return nil }
            index += characters[index] == "\\" && needle.first != "\\" ? 2 : 1
        }
        return nil
    }

    /// remark-math's single-dollar rule: the opening `$` is not followed by whitespace and the
    /// closing `$` is neither preceded by whitespace nor followed by a digit, so prices such as
    /// "$5 and $6" stay text.
    private static func singleDollarClose(_ characters: [Character], from start: Int) -> Int? {
        guard start < characters.count, !characters[start].isWhitespace else { return nil }
        var index = start
        while index < characters.count {
            let character = characters[index]
            if character == "\\" { index += 2; continue }
            if character == "`" { return nil }
            if character == "$" {
                let double = index + 1 < characters.count && characters[index + 1] == "$"
                let digit = index + 1 < characters.count && characters[index + 1].isNumber
                if index > start, !characters[index - 1].isWhitespace, !double, !digit { return index }
                if double { return nil }
            }
            index += 1
        }
        return nil
    }

    private static func codeSpanEnd(_ characters: [Character], from start: Int) -> Int {
        var index = start
        while index < characters.count, characters[index] == "`" { index += 1 }
        let count = index - start
        var cursor = index
        while cursor < characters.count {
            guard characters[cursor] == "`" else { cursor += 1; continue }
            let run = cursor
            while cursor < characters.count, characters[cursor] == "`" { cursor += 1 }
            if cursor - run == count { return cursor }
        }
        return index
    }

    private static func destinationEnd(_ characters: [Character], from start: Int) -> Int {
        var index = start
        var depth = 1
        while index < characters.count, depth > 0 {
            if characters[index] == "\\" { index = min(characters.count, index + 2); continue }
            if characters[index] == "(" { depth += 1 }
            if characters[index] == ")" { depth -= 1 }
            index += 1
        }
        return index
    }

    private static func autolinkEnd(_ characters: [Character], from start: Int) -> Int? {
        guard start + 1 < characters.count, characters[start + 1].isLetter else { return nil }
        var index = start + 1
        while index < characters.count {
            if characters[index] == ">" { return index + 1 }
            if characters[index].isWhitespace || characters[index] == "<" { return nil }
            index += 1
        }
        return nil
    }
}

extension NSAttributedString.Key {
    /// The LaTeX source an inline math attachment shows.
    static let agentMathSource = NSAttributedString.Key("TabAgentMathSource")
}
