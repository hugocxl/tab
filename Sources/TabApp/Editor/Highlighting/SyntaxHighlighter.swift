import AppKit
import TabCore

/// A tokenizer-based highlighter: it splits text into lines, tokenizes each
/// with the state the previous line ended in (an open comment or string),
/// and after an edit re-tokenizes only from the changed line until the line
/// states match what they were.
public final class SyntaxHighlighter {
    public let language: SyntaxLanguage
    /// UTF-16 offset of each line's start.
    private var lineStarts: [Int] = [0]
    /// The state each line starts in.
    private var lineStates: [LineState] = [.start]
    /// Each line's tokens, relative to its start.
    private var lineTokens: [[TokenRange]] = [[]]
    private var length = 0

    public init(language: SyntaxLanguage) {
        self.language = language
    }

    /// The tokens of `text`, in order.
    public static func highlight(_ text: String, language: SyntaxLanguage) -> [TokenRange] {
        let highlighter = SyntaxHighlighter(language: language)
        highlighter.setText(text)
        return highlighter.tokens
    }

    /// Highlights the whole text.
    public func setText(_ text: String) {
        let units = Array(text.utf16)
        length = units.count
        lineStarts = Self.lineStarts(units)
        lineStates = [.start]
        lineTokens = []
        lineStates.reserveCapacity(lineStarts.count)
        lineTokens.reserveCapacity(lineStarts.count)
        var state = LineState.start
        for line in lineStarts.indices {
            let (tokens, next) = Tokenizer.tokenize(Array(units[lineRange(line, units.count)]), state: state, language: language)
            lineTokens.append(tokens)
            if line + 1 < lineStarts.count { lineStates.append(next) }
            state = next
        }
    }

    /// Re-highlights after an edit that replaced text so that `editedRange`
    /// (in the new text) holds what was typed and the text's length changed
    /// by `changeInLength`. Returns the range of the new text whose tokens
    /// changed, to redraw.
    @discardableResult
    public func update(_ text: String, editedRange: NSRange, changeInLength: Int) -> NSRange {
        let units = Array(text.utf16)
        guard units.count - changeInLength == length, editedRange.location <= units.count else {
            setText(text)
            return NSRange(location: 0, length: units.count)
        }
        let oldStarts = lineStarts
        let oldStates = lineStates
        let oldTokens = lineTokens
        let newStarts = Self.lineStarts(units)
        let first = Self.line(containing: editedRange.location, in: newStarts)
        let lastEdited = Self.line(containing: NSMaxRange(editedRange), in: newStarts)
        let lineShift = newStarts.count - oldStarts.count

        var states = Array(oldStates.prefix(first + 1))
        var tokens = Array(oldTokens.prefix(first))
        var state = states[first]
        var line = first
        var resumedAt: Int?
        while line < newStarts.count {
            let (lineTokens, next) = Tokenizer.tokenize(Array(units[Self.range(line, newStarts, units.count)]), state: state, language: language)
            tokens.append(lineTokens)
            state = next
            line += 1
            guard line < newStarts.count else { break }
            states.append(next)
            let oldLine = line - lineShift
            if line > lastEdited, oldLine > 0, oldLine < oldStates.count, oldStates[oldLine] == next {
                resumedAt = oldLine
                break
            }
        }
        if let oldLine = resumedAt {
            tokens += oldTokens[oldLine...]
            states += oldStates[(oldLine + 1)...]
        }
        lineStarts = newStarts
        lineStates = states
        lineTokens = tokens
        length = units.count
        let end = line < newStarts.count ? newStarts[line] : units.count
        return NSRange(location: newStarts[first], length: end - newStarts[first])
    }

    /// Every token, with absolute offsets.
    public var tokens: [TokenRange] { tokens(in: NSRange(location: 0, length: length)) }

    /// The tokens of the lines that intersect `range`, with absolute offsets.
    public func tokens(in range: NSRange) -> [TokenRange] {
        guard !lineStarts.isEmpty else { return [] }
        let first = Self.line(containing: range.location, in: lineStarts)
        let last = Self.line(containing: NSMaxRange(range), in: lineStarts)
        var result: [TokenRange] = []
        for line in first...min(last, lineTokens.count - 1) {
            let start = lineStarts[line]
            for token in lineTokens[line] {
                result.append(TokenRange(location: token.range.location + start, length: token.range.length, kind: token.kind))
            }
        }
        return result
    }

    public var lineCount: Int { lineStarts.count }

    private func lineRange(_ line: Int, _ total: Int) -> Range<Int> {
        Self.range(line, lineStarts, total)
    }

    /// A line's units without its line break.
    private static func range(_ line: Int, _ starts: [Int], _ total: Int) -> Range<Int> {
        let start = starts[line]
        var end = line + 1 < starts.count ? starts[line + 1] - 1 : total
        end = max(end, start)
        return start..<end
    }

    private static func lineStarts(_ units: [UInt16]) -> [Int] {
        var starts = [0]
        for (index, unit) in units.enumerated() where unit == 0x0A { starts.append(index + 1) }
        return starts
    }

    private static func line(containing offset: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

/// The colors tokens draw in, from the theme's terminal palette so code
/// matches the terminal: magenta keywords, green strings, blue functions,
/// cyan types, yellow attributes, red numbers and dim comments.
public struct SyntaxColors: Sendable {
    private var colors: [TokenKind: TabCore.RGBColor]
    private var commentAlpha: Double
    public var foreground: TabCore.RGBColor

    public init(scheme: ColorScheme, palette: ChromePalette) {
        func color(_ index: Int, _ fallback: UInt32) -> TabCore.RGBColor { scheme.paletteColor(index) ?? TabCore.RGBColor(fallback) }
        let fg = scheme.foreground ?? TabCore.RGBColor(0xD5CEC7)
        foreground = fg
        colors = [
            .keyword: color(5, 0xC678DD),
            .string: color(2, 0x98C379),
            .number: color(1, 0xD19A66),
            .type: color(6, 0x56B6C2),
            .function: color(4, 0x61AFEF),
            .attribute: color(3, 0xE5C07B),
            .comment: fg,
            .punctuation: fg,
        ]
        commentAlpha = 0.5
    }

    /// The color for `kind`.
    public func color(_ kind: TokenKind) -> NSColor {
        let rgb = colors[kind] ?? foreground
        switch kind {
        case .comment: return rgb.nsColor.withAlphaComponent(commentAlpha)
        case .punctuation: return rgb.nsColor.withAlphaComponent(0.7)
        default: return rgb.nsColor
        }
    }

    /// The text attributes for `kind`; comments are italic.
    public func attributes(_ kind: TokenKind, font: NSFont) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color(kind)]
        if kind == .comment {
            attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return attributes
    }
}

extension AppTheme {
    /// Token colors for the current theme.
    public var syntaxColors: SyntaxColors { SyntaxColors(scheme: scheme, palette: palette) }
}

extension SyntaxHighlighter {
    /// Colors `range` of `storage` from the tokens, resetting it to the
    /// foreground first.
    public func apply(to storage: NSTextStorage, in range: NSRange, colors: SyntaxColors, font: NSFont) {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard range.length > 0 || storage.length == 0 else { return }
        storage.beginEditing()
        storage.addAttributes([.foregroundColor: colors.foreground.nsColor, .font: font], range: range)
        for token in tokens(in: range) {
            let clipped = NSIntersectionRange(token.range, range)
            guard clipped.length > 0 else { continue }
            storage.addAttributes(colors.attributes(token.kind, font: font), range: clipped)
        }
        storage.endEditing()
    }
}
