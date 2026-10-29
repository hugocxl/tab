import Foundation

/// Scans one line of UTF-16 code units, collecting tokens with offsets
/// relative to the line start.
struct LineScanner {
    let chars: [UInt16]
    var index = 0
    var tokens: [TokenRange] = []

    init(_ chars: [UInt16]) { self.chars = chars }

    var atEnd: Bool { index >= chars.count }
    var current: UInt16 { chars[index] }

    func peek(_ offset: Int = 0) -> UInt16? {
        let position = index + offset
        return position < chars.count ? chars[position] : nil
    }

    func matches(_ text: [UInt16], at position: Int? = nil) -> Bool {
        let start = position ?? index
        guard !text.isEmpty, start + text.count <= chars.count else { return false }
        for offset in 0..<text.count where chars[start + offset] != text[offset] { return false }
        return true
    }

    mutating func add(_ start: Int, _ end: Int, _ kind: TokenKind) {
        guard end > start else { return }
        if let last = tokens.last, last.kind == kind, kind == .punctuation, NSMaxRange(last.range) == start {
            tokens[tokens.count - 1].range.length += end - start
            return
        }
        tokens.append(TokenRange(location: start, length: end - start, kind: kind))
    }

    func text(_ start: Int, _ end: Int) -> String {
        String(utf16CodeUnits: Array(chars[start..<end]), count: end - start)
    }

    /// Skips to just after `close`, honoring backslash escapes. Returns
    /// whether it was found on this line.
    mutating func skip(past close: [UInt16], escapes: Bool) -> Bool {
        while index < chars.count {
            if escapes && chars[index] == Ch.backslash {
                index += 2
                continue
            }
            if matches(close) {
                index += close.count
                return true
            }
            index += 1
        }
        index = chars.count
        return false
    }

    mutating func skipWhitespace() {
        while index < chars.count, Ch.isSpace(chars[index]) { index += 1 }
    }

    /// Skips an identifier, returning its end.
    mutating func identifier(extra: Set<UInt16> = []) -> Int {
        while index < chars.count, Ch.isIdentifier(chars[index]) || extra.contains(chars[index]) { index += 1 }
        return index
    }

    /// Skips a number literal: digits, hex, underscores, a fraction and an
    /// exponent.
    mutating func number() {
        while index < chars.count {
            let char = chars[index]
            if Ch.isIdentifier(char) || char == Ch.dot && (peek(1).map(Ch.isDigit) ?? false) {
                let isExponent = (char == utf16Unit("e") || char == utf16Unit("E"))
                index += 1
                if isExponent, let sign = peek(), sign == utf16Unit("+") || sign == utf16Unit("-") { index += 1 }
            } else {
                break
            }
        }
    }

    /// The next non-space character from `position`.
    func nextSignificant(from position: Int) -> UInt16? {
        var position = position
        while position < chars.count, Ch.isSpace(chars[position]) { position += 1 }
        return position < chars.count ? chars[position] : nil
    }

    /// The previous non-space character before `position`.
    func previousSignificant(before position: Int) -> UInt16? {
        var position = position - 1
        while position >= 0, Ch.isSpace(chars[position]) { position -= 1 }
        return position >= 0 ? chars[position] : nil
    }
}

/// Character classes over UTF-16 code units.
enum Ch {
    static let backslash = utf16Unit("\\")
    static let dot = utf16Unit(".")
    static let quote = utf16Unit("\"")
    static let apostrophe = utf16Unit("'")
    static let hash = utf16Unit("#")
    static let colon = utf16Unit(":")
    static let dollar = utf16Unit("$")
    static let paren = utf16Unit("(")
    static let less = utf16Unit("<")
    static let greater = utf16Unit(">")
    static let slash = utf16Unit("/")
    static let equals = utf16Unit("=")
    static let bracket = utf16Unit("[")
    static let closeBracket = utf16Unit("]")
    static let brace = utf16Unit("{")
    static let closeBrace = utf16Unit("}")
    static let dash = utf16Unit("-")
    static let bang = utf16Unit("!")
    static let star = utf16Unit("*")
    static let underscore = utf16Unit("_")
    static let backtick = utf16Unit("`")
    static let at = utf16Unit("@")
    static let semicolon = utf16Unit(";")

    static func isSpace(_ char: UInt16) -> Bool { char == 0x20 || char == 0x09 || char == 0x0D }
    static func isDigit(_ char: UInt16) -> Bool { char >= 0x30 && char <= 0x39 }
    static func isUpper(_ char: UInt16) -> Bool { char >= 0x41 && char <= 0x5A }
    static func isLetter(_ char: UInt16) -> Bool { (char | 0x20) >= 0x61 && (char | 0x20) <= 0x7A || char >= 0x80 }
    static func isIdentifierStart(_ char: UInt16) -> Bool { isLetter(char) || char == underscore }
    static func isIdentifier(_ char: UInt16) -> Bool { isIdentifierStart(char) || isDigit(char) }
    static let punctuation: Set<UInt16> = Set("{}[]().,;:+-*/%=<>!&|^~?".utf16)
}

/// Tokenizers per language family. Each takes one line and the state the
/// previous line ended in, and returns the line's tokens and its end state.
enum Tokenizer {
    static func tokenize(_ line: [UInt16], state: LineState, language: SyntaxLanguage) -> ([TokenRange], LineState) {
        if let grammar = Grammars.grammar(language) { return code(line, state, grammar) }
        switch language {
        case .json: return json(line, state)
        case .yaml: return yaml(line, state)
        case .toml: return toml(line, state)
        case .markdown: return markdown(line, state)
        case .html, .xml: return markup(line, state)
        case .css: return css(line, state)
        case .makefile: return makefile(line, state)
        default: return ([], state)
        }
    }

    // MARK: C-like code

    static func code(_ line: [UInt16], _ state: LineState, _ grammar: Grammar) -> ([TokenRange], LineState) {
        var s = LineScanner(line)
        var state = state
        let blockOpen = grammar.blockComment.map { Array($0.open.utf16) } ?? []
        let blockClose = grammar.blockComment.map { Array($0.close.utf16) } ?? []
        let lineComments = grammar.lineComments.map { Array($0.utf16) }

        // Finish what the previous line left open.
        switch state.mode {
        case .comment:
            let end = closeComment(&s, &state, open: blockOpen, close: blockClose, nested: grammar.nestedComments)
            s.add(0, end, .comment)
            if state.mode == .comment { return (s.tokens, state) }
        case .string(let rule):
            let found = s.skip(past: grammar.strings[rule].close, escapes: grammar.strings[rule].escapes)
            s.add(0, s.index, .string)
            if !found { return (s.tokens, state) }
            state.mode = .normal
        default:
            state.mode = .normal
        }

        if !grammar.lineInstructions.isEmpty {
            s.skipWhitespace()
            let start = s.index
            let end = s.identifier()
            if end > start, grammar.lineInstructions.contains(s.text(start, end).lowercased()) {
                s.add(start, end, .keyword)
            } else {
                s.index = start
            }
        }
        if grammar.preprocessor {
            s.skipWhitespace()
            if !s.atEnd, s.current == Ch.hash {
                let start = s.index
                s.index += 1
                s.skipWhitespace()
                let end = s.identifier()
                s.add(start, end, .attribute)
                if s.text(start, end).hasSuffix("include") || s.text(start, end).hasSuffix("import") {
                    s.skipWhitespace()
                    if !s.atEnd, s.current == Ch.less {
                        let open = s.index
                        _ = s.skip(past: [Ch.greater], escapes: false)
                        s.add(open, s.index, .string)
                    }
                }
            }
        }

        loop: while !s.atEnd {
            let start = s.index
            let char = s.current

            if Ch.isSpace(char) {
                s.index += 1
                continue
            }
            if let comment = lineComments.first(where: { s.matches($0) }) {
                let boundary = !grammar.hashCommentNeedsBoundary || start == 0 || Ch.isSpace(line[start - 1])
                if boundary || comment != [Ch.hash] {
                    s.add(start, line.count, .comment)
                    s.index = line.count
                    break loop
                }
            }
            if !blockOpen.isEmpty, s.matches(blockOpen) {
                s.index += blockOpen.count
                state.mode = .comment
                state.depth = 1
                let end = closeComment(&s, &state, open: blockOpen, close: blockClose, nested: grammar.nestedComments)
                s.add(start, end, .comment)
                continue
            }
            if let ruleIndex = grammar.strings.firstIndex(where: { s.matches($0.open) }) {
                let rule = grammar.strings[ruleIndex]
                if grammar.rustMacros && rule.open == [Ch.apostrophe] {
                    // handled below as char literal or lifetime
                } else {
                    s.index += rule.open.count
                    let found = s.skip(past: rule.close, escapes: rule.escapes)
                    s.add(start, s.index, .string)
                    if !found && rule.multiline { state.mode = .string(ruleIndex) }
                    continue
                }
            }
            if grammar.rustMacros && char == Ch.apostrophe {
                // A char literal closes within a few units; otherwise a lifetime.
                if let close = (start + 2...min(start + 10, line.count)).first(where: { $0 - 1 < line.count && line[$0 - 1] == Ch.apostrophe && $0 - 1 > start }),
                   line[start + 1] == Ch.backslash || close == start + 3
                {
                    s.index = close
                    s.add(start, close, .string)
                } else {
                    s.index += 1
                    let end = s.identifier()
                    s.add(start, end, .type)
                }
                continue
            }
            if Ch.isDigit(char) || (char == Ch.dot && (s.peek(1).map(Ch.isDigit) ?? false)) {
                s.number()
                s.add(start, s.index, .number)
                continue
            }
            if grammar.attributePrefixes.contains(char), let next = s.peek(1), Ch.isIdentifierStart(next) {
                s.index += 1
                let end = s.identifier()
                s.add(start, end, grammar.rubySymbols ? .attribute : (s.text(start + 1, end) == "interface" || s.text(start + 1, end) == "end" ? .keyword : .attribute))
                continue
            }
            if grammar.rubySymbols {
                if char == Ch.at, let next = s.peek(1), Ch.isIdentifierStart(next) || next == Ch.at {
                    s.index += next == Ch.at ? 2 : 1
                    s.add(start, s.identifier(), .attribute)
                    continue
                }
                if char == Ch.colon, let next = s.peek(1), Ch.isIdentifierStart(next), start == 0 || line[start - 1] != Ch.colon {
                    s.index += 1
                    s.add(start, s.identifier(), .attribute)
                    continue
                }
            }
            if grammar.bracketAttributes && char == Ch.hash && (s.peek(1) == Ch.bracket || s.peek(1) == Ch.bang && s.peek(2) == Ch.bracket) {
                var depth = 0
                while !s.atEnd {
                    if s.current == Ch.bracket { depth += 1 }
                    if s.current == Ch.closeBracket {
                        depth -= 1
                        if depth == 0 {
                            s.index += 1
                            break
                        }
                    }
                    s.index += 1
                }
                s.add(start, s.index, .attribute)
                continue
            }
            if grammar.hashKeywords && char == Ch.hash, let next = s.peek(1), Ch.isIdentifierStart(next) {
                s.index += 1
                s.add(start, s.identifier(), .keyword)
                continue
            }
            if grammar.dollarVariables && char == Ch.dollar {
                s.index += 1
                if s.peek() == Ch.brace {
                    _ = s.skip(past: [Ch.closeBrace], escapes: false)
                } else if s.peek() == Ch.paren {
                    s.add(start, s.index + 1, .attribute)
                    s.index += 1
                    continue
                } else if let next = s.peek(), Ch.isIdentifierStart(next) {
                    _ = s.identifier()
                } else if !s.atEnd {
                    s.index += 1
                }
                s.add(start, s.index, .attribute)
                continue
            }
            if grammar.jsxTags && char == Ch.less, let tag = jsxTagStart(s, start) {
                s.add(start, tag, .punctuation)
                s.index = tag
                let nameStart = s.index
                let nameEnd = s.identifier(extra: [Ch.dot])
                s.add(nameStart, nameEnd, (s.peek().map { _ in true } ?? true) && Ch.isUpper(line[nameStart]) ? .type : .keyword)
                continue
            }
            if Ch.isIdentifierStart(char) || (grammar.dollarInIdentifiers && char == Ch.dollar) {
                let extra: Set<UInt16> = grammar.dollarInIdentifiers ? [Ch.dollar] : (grammar.rubySymbols ? [utf16Unit("?"), Ch.bang] : [])
                let end = s.identifier(extra: extra)
                let word = s.text(start, end)
                let key = grammar.caseInsensitive ? word.lowercased() : word
                if grammar.rustMacros && s.peek() == Ch.bang && s.peek(1) != Ch.equals {
                    s.index += 1
                    s.add(start, s.index, .function)
                } else if grammar.keywords.contains(key) {
                    s.add(start, end, .keyword)
                } else if grammar.literals.contains(key) {
                    s.add(start, end, .number)
                } else if grammar.types.contains(key) {
                    s.add(start, end, .type)
                } else if s.nextSignificant(from: end) == Ch.paren {
                    s.add(start, end, .function)
                } else if grammar.capitalizedTypes && Ch.isUpper(char) {
                    s.add(start, end, .type)
                }
                continue
            }
            if Ch.punctuation.contains(char) {
                s.index += 1
                s.add(start, s.index, .punctuation)
                continue
            }
            s.index += 1
        }
        return (s.tokens, state)
    }

    /// Where a JSX tag's name starts, if `<` at `start` opens one.
    private static func jsxTagStart(_ s: LineScanner, _ start: Int) -> Int? {
        var name = start + 1
        if name < s.chars.count, s.chars[name] == Ch.slash { name += 1 }
        guard name < s.chars.count, Ch.isLetter(s.chars[name]) else { return nil }
        guard let previous = s.previousSignificant(before: start) else { return name }
        let openers: Set<UInt16> = Set("(=,:?&|{}[;>".utf16)
        if openers.contains(previous) { return name }
        let word = s.text(max(0, start - 7), start).trimmingCharacters(in: .whitespaces)
        return word.hasSuffix("return") ? name : nil
    }

    /// Advances through a block comment, tracking nesting. Returns where the
    /// comment ends on this line.
    private static func closeComment(_ s: inout LineScanner, _ state: inout LineState, open: [UInt16], close: [UInt16], nested: Bool) -> Int {
        while !s.atEnd {
            if nested && s.matches(open) {
                state.depth += 1
                s.index += open.count
            } else if s.matches(close) {
                s.index += close.count
                state.depth -= 1
                if state.depth <= 0 {
                    state = LineState()
                    return s.index
                }
            } else {
                s.index += 1
            }
        }
        return s.index
    }

    // MARK: Data formats

    static func json(_ line: [UInt16], _ state: LineState) -> ([TokenRange], LineState) {
        var s = LineScanner(line)
        var state = state
        if state.mode == .comment {
            let end = closeComment(&s, &state, open: Array("/*".utf16), close: Array("*/".utf16), nested: false)
            s.add(0, end, .comment)
            if state.mode == .comment { return (s.tokens, state) }
        }
        while !s.atEnd {
            let start = s.index
            let char = s.current
            if char == Ch.quote {
                s.index += 1
                _ = s.skip(past: [Ch.quote], escapes: true)
                s.add(start, s.index, s.nextSignificant(from: s.index) == Ch.colon ? .attribute : .string)
            } else if s.matches(Array("//".utf16)) {
                s.add(start, line.count, .comment)
                break
            } else if s.matches(Array("/*".utf16)) {
                s.index += 2
                state.mode = .comment
                state.depth = 1
                s.add(start, closeComment(&s, &state, open: Array("/*".utf16), close: Array("*/".utf16), nested: false), .comment)
            } else if Ch.isDigit(char) || char == Ch.dash {
                s.index += 1
                s.number()
                s.add(start, s.index, .number)
            } else if Ch.isIdentifierStart(char) {
                let end = s.identifier()
                if ["true", "false", "null"].contains(s.text(start, end)) { s.add(start, end, .keyword) }
            } else {
                if Ch.punctuation.contains(char) { s.add(start, start + 1, .punctuation) }
                s.index += 1
            }
        }
        return (s.tokens, state)
    }

    static func yaml(_ line: [UInt16], _ state: LineState) -> ([TokenRange], LineState) {
        var s = LineScanner(line)
        s.skipWhitespace()
        if s.matches(Array("---".utf16)) || s.matches(Array("...".utf16)) {
            s.add(s.index, line.count, .punctuation)
            return (s.tokens, state)
        }
        while !s.atEnd, s.current == Ch.dash, s.peek(1).map(Ch.isSpace) ?? true {
            s.add(s.index, s.index + 1, .punctuation)
            s.index += 1
            s.skipWhitespace()
        }
        // A key before `: `.
        let keyStart = s.index
        if let colon = findKeyColon(line, from: keyStart) {
            s.add(keyStart, colon, .attribute)
            s.add(colon, colon + 1, .punctuation)
            s.index = colon + 1
        }
        while !s.atEnd {
            let start = s.index
            let char = s.current
            if char == Ch.hash && (start == 0 || Ch.isSpace(line[start - 1])) {
                s.add(start, line.count, .comment)
                break
            }
            if char == Ch.quote || char == Ch.apostrophe {
                s.index += 1
                _ = s.skip(past: [char], escapes: char == Ch.quote)
                s.add(start, s.index, .string)
            } else if char == utf16Unit("&") || char == Ch.star {
                s.index += 1
                s.add(start, s.identifier(extra: [Ch.dash]), .type)
            } else if char == utf16Unit("!") {
                s.index += 1
                s.add(start, s.identifier(extra: [Ch.bang]), .type)
            } else if Ch.isSpace(char) || Ch.punctuation.contains(char) && char != Ch.dash && char != Ch.dot {
                if "[]{},|>".utf16.contains(char) { s.add(start, start + 1, .punctuation) }
                s.index += 1
            } else {
                // A plain scalar up to a comment.
                var end = start
                while end < line.count, !(line[end] == Ch.hash && end > start && Ch.isSpace(line[end - 1])), !"[]{},".utf16.contains(line[end]) { end += 1 }
                var trimmed = end
                while trimmed > start, Ch.isSpace(line[trimmed - 1]) { trimmed -= 1 }
                let word = s.text(start, trimmed)
                if ["true", "false", "yes", "no", "on", "off", "null", "~"].contains(word.lowercased()) {
                    s.add(start, trimmed, .keyword)
                } else if Double(word) != nil {
                    s.add(start, trimmed, .number)
                } else {
                    s.add(start, trimmed, .string)
                }
                s.index = end
            }
        }
        return (s.tokens, state)
    }

    /// The colon after a YAML or TOML key on this line, if the line starts
    /// with one.
    private static func findKeyColon(_ line: [UInt16], from start: Int) -> Int? {
        var index = start
        if index < line.count, line[index] == Ch.quote || line[index] == Ch.apostrophe {
            let quote = line[index]
            index += 1
            while index < line.count, line[index] != quote { index += 1 }
            index += 1
        }
        while index < line.count {
            let char = line[index]
            if char == Ch.colon && (index + 1 == line.count || Ch.isSpace(line[index + 1])) { return index > start ? index : nil }
            if char == Ch.hash || char == Ch.quote || char == Ch.apostrophe || char == Ch.brace || char == Ch.bracket { return nil }
            index += 1
        }
        return nil
    }

    static func toml(_ line: [UInt16], _ state: LineState) -> ([TokenRange], LineState) {
        var s = LineScanner(line)
        var state = state
        let multiline = [Array("\"\"\"".utf16), Array("'''".utf16)]
        if case .string(let rule) = state.mode {
            let found = s.skip(past: multiline[rule], escapes: rule == 0)
            s.add(0, s.index, .string)
            if !found { return (s.tokens, state) }
            state.mode = .normal
        }
        s.skipWhitespace()
        if !s.atEnd, s.current == Ch.bracket, state.mode == .normal, s.index == line.firstIndex(where: { !Ch.isSpace($0) }) {
            let start = s.index
            _ = s.skip(past: [Ch.closeBracket], escapes: false)
            if s.peek() == Ch.closeBracket { s.index += 1 }
            s.add(start, s.index, .type)
        } else if let equals = tomlKeyEnd(line, from: s.index) {
            var end = equals
            while end > s.index, Ch.isSpace(line[end - 1]) { end -= 1 }
            s.add(s.index, end, .attribute)
            s.add(equals, equals + 1, .punctuation)
            s.index = equals + 1
        }
        while !s.atEnd {
            let start = s.index
            let char = s.current
            if char == Ch.hash {
                s.add(start, line.count, .comment)
                break
            }
            if let rule = multiline.firstIndex(where: { s.matches($0) }) {
                s.index += 3
                let found = s.skip(past: multiline[rule], escapes: rule == 0)
                s.add(start, s.index, .string)
                if !found { state.mode = .string(rule) }
            } else if char == Ch.quote || char == Ch.apostrophe {
                s.index += 1
                _ = s.skip(past: [char], escapes: char == Ch.quote)
                s.add(start, s.index, .string)
            } else if Ch.isDigit(char) || (char == Ch.dash || char == utf16Unit("+")) && (s.peek(1).map(Ch.isDigit) ?? false) {
                s.index += 1
                while !s.atEnd, Ch.isIdentifier(s.current) || "-:.+".utf16.contains(s.current) { s.index += 1 }
                s.add(start, s.index, .number)
            } else if Ch.isIdentifierStart(char) {
                let end = s.identifier()
                if ["true", "false", "inf", "nan"].contains(s.text(start, end)) { s.add(start, end, .keyword) }
            } else {
                if Ch.punctuation.contains(char) { s.add(start, start + 1, .punctuation) }
                s.index += 1
            }
        }
        return (s.tokens, state)
    }

    private static func tomlKeyEnd(_ line: [UInt16], from start: Int) -> Int? {
        var index = start
        while index < line.count {
            let char = line[index]
            if char == Ch.equals { return index > start ? index : nil }
            if char == Ch.quote || char == Ch.apostrophe {
                index += 1
                while index < line.count, line[index] != char { index += 1 }
            } else if !(Ch.isIdentifier(char) || char == Ch.dash || char == Ch.dot || Ch.isSpace(char)) {
                return nil
            }
            index += 1
        }
        return nil
    }

    // MARK: Markdown

    static func markdown(_ line: [UInt16], _ state: LineState) -> ([TokenRange], LineState) {
        var s = LineScanner(line)
        var state = state
        let trimmedStart = line.firstIndex(where: { !Ch.isSpace($0) }) ?? line.count
        let fence = Array("```".utf16)
        let tildeFence = Array("~~~".utf16)
        if s.matches(fence, at: trimmedStart) || s.matches(tildeFence, at: trimmedStart) {
            s.add(trimmedStart, line.count, .string)
            state.mode = state.mode == .fence ? .normal : .fence
            return (s.tokens, state)
        }
        if state.mode == .fence {
            s.add(0, line.count, .string)
            return (s.tokens, state)
        }
        s.index = trimmedStart
        if !s.atEnd, s.current == Ch.hash {
            s.add(trimmedStart, line.count, .keyword)
            return (s.tokens, state)
        }
        if !s.atEnd, s.current == Ch.greater {
            s.add(trimmedStart, line.count, .comment)
            return (s.tokens, state)
        }
        if !s.atEnd, "-*+".utf16.contains(s.current), s.peek(1).map(Ch.isSpace) ?? false {
            s.add(s.index, s.index + 1, .punctuation)
            s.index += 1
        } else {
            let start = s.index
            while !s.atEnd, Ch.isDigit(s.current) { s.index += 1 }
            if s.index > start, !s.atEnd, s.current == Ch.dot || s.current == utf16Unit(")") {
                s.index += 1
                s.add(start, s.index, .punctuation)
            } else {
                s.index = start
            }
        }
        while !s.atEnd {
            let start = s.index
            let char = s.current
            if char == Ch.backtick {
                s.index += 1
                _ = s.skip(past: [Ch.backtick], escapes: false)
                s.add(start, s.index, .string)
            } else if (char == Ch.star || char == Ch.underscore), let close = emphasisEnd(line, start) {
                s.add(start, close, .type)
                s.index = close
            } else if char == Ch.bracket || (char == Ch.bang && s.peek(1) == Ch.bracket) {
                let textStart = char == Ch.bang ? start + 1 : start
                s.index = textStart + 1
                guard s.skip(past: [Ch.closeBracket], escapes: true) else { continue }
                if s.peek() == Ch.paren {
                    s.add(start, s.index, .function)
                    let urlStart = s.index
                    _ = s.skip(past: [utf16Unit(")")], escapes: false)
                    s.add(urlStart, s.index, .string)
                }
            } else if char == Ch.less, let next = s.peek(1), Ch.isLetter(next) || next == Ch.slash {
                _ = s.skip(past: [Ch.greater], escapes: false)
                s.add(start, s.index, .keyword)
            } else {
                s.index += 1
            }
        }
        return (s.tokens, state)
    }

    private static func emphasisEnd(_ line: [UInt16], _ start: Int) -> Int? {
        let marker = line[start]
        var count = 0
        while start + count < line.count, line[start + count] == marker { count += 1 }
        guard count <= 3, start + count < line.count, !Ch.isSpace(line[start + count]) else { return nil }
        var index = start + count
        while index + count <= line.count {
            if (0..<count).allSatisfy({ line[index + $0] == marker }) && !Ch.isSpace(line[index - 1]) {
                return index + count
            }
            index += 1
        }
        return nil
    }

    // MARK: Markup

    static func markup(_ line: [UInt16], _ state: LineState) -> ([TokenRange], LineState) {
        var s = LineScanner(line)
        var state = state
        let commentOpen = Array("<!--".utf16)
        let commentClose = Array("-->".utf16)
        if state.mode == .comment {
            let found = s.skip(past: commentClose, escapes: false)
            s.add(0, s.index, .comment)
            if !found { return (s.tokens, state) }
            state.mode = .normal
        }
        if state.mode == .tag {
            state.mode = tagBody(&s) ? .normal : .tag
        }
        while !s.atEnd {
            let start = s.index
            if s.matches(commentOpen) {
                s.index += commentOpen.count
                let found = s.skip(past: commentClose, escapes: false)
                s.add(start, s.index, .comment)
                if !found { state.mode = .comment }
                continue
            }
            let char = s.current
            if char == Ch.less, let next = s.peek(1), Ch.isLetter(next) || next == Ch.slash || next == Ch.bang || next == utf16Unit("?") {
                s.index += 1
                if !s.atEnd, "/!?".utf16.contains(s.current) { s.index += 1 }
                s.add(start, s.index, .punctuation)
                let nameStart = s.index
                let nameEnd = s.identifier(extra: [Ch.dash, Ch.colon, Ch.dot])
                s.add(nameStart, nameEnd, .keyword)
                if !tagBody(&s) { state.mode = .tag }
                continue
            }
            if char == utf16Unit("&") {
                let end = line[start...].prefix(12).firstIndex(of: Ch.semicolon)
                if let end {
                    s.add(start, end + 1, .number)
                    s.index = end + 1
                    continue
                }
            }
            s.index += 1
        }
        return (s.tokens, state)
    }

    /// Scans attributes up to `>`; returns whether the tag closed.
    private static func tagBody(_ s: inout LineScanner) -> Bool {
        while !s.atEnd {
            let start = s.index
            let char = s.current
            if char == Ch.greater || (char == Ch.slash || char == utf16Unit("?")) && s.peek(1) == Ch.greater {
                s.index += char == Ch.greater ? 1 : 2
                s.add(start, s.index, .punctuation)
                return true
            }
            if char == Ch.quote || char == Ch.apostrophe {
                s.index += 1
                _ = s.skip(past: [char], escapes: false)
                s.add(start, s.index, .string)
            } else if Ch.isIdentifierStart(char) {
                s.add(start, s.identifier(extra: [Ch.dash, Ch.colon, Ch.dot]), .attribute)
            } else {
                if char == Ch.equals { s.add(start, start + 1, .punctuation) }
                s.index += 1
            }
        }
        return false
    }

    // MARK: CSS

    static func css(_ line: [UInt16], _ state: LineState) -> ([TokenRange], LineState) {
        var s = LineScanner(line)
        var state = state
        let open = Array("/*".utf16)
        let close = Array("*/".utf16)
        if state.mode == .comment {
            let found = s.skip(past: close, escapes: false)
            s.add(0, s.index, .comment)
            if !found { return (s.tokens, state) }
            state.mode = .normal
        }
        while !s.atEnd {
            let start = s.index
            let char = s.current
            if s.matches(open) {
                s.index += 2
                let found = s.skip(past: close, escapes: false)
                s.add(start, s.index, .comment)
                if !found { state.mode = .comment }
            } else if s.matches(Array("//".utf16)) {
                s.add(start, line.count, .comment)
                break
            } else if char == Ch.brace || char == Ch.closeBrace {
                state.depth = max(0, state.depth + (char == Ch.brace ? 1 : -1))
                s.add(start, start + 1, .punctuation)
                s.index += 1
            } else if char == Ch.quote || char == Ch.apostrophe {
                s.index += 1
                _ = s.skip(past: [char], escapes: true)
                s.add(start, s.index, .string)
            } else if char == Ch.at {
                s.index += 1
                s.add(start, s.identifier(extra: [Ch.dash]), .keyword)
            } else if char == Ch.hash && state.depth > 0 {
                s.index += 1
                s.add(start, s.identifier(), .number)
            } else if Ch.isDigit(char) || char == Ch.dot && (s.peek(1).map(Ch.isDigit) ?? false) {
                s.number()
                if !s.atEnd, s.current == utf16Unit("%") { s.index += 1 }
                s.add(start, s.index, .number)
            } else if Ch.isIdentifierStart(char) || char == Ch.dash || char == Ch.dollar {
                s.index += 1
                let end = s.identifier(extra: [Ch.dash])
                if state.depth > 0 && s.nextSignificant(from: end) == Ch.colon && !isSelectorContinuation(s, end) {
                    s.add(start, end, .attribute)
                } else if s.peek() == Ch.paren {
                    s.add(start, end, .function)
                } else if state.depth == 0 || s.previousSignificant(before: start) != Ch.colon && isSelectorContinuation(s, end) {
                    s.add(start, end, .type)
                } else if char == Ch.dollar {
                    s.add(start, end, .attribute)
                }
            } else if state.depth == 0 && (char == Ch.dot || char == Ch.hash || char == Ch.colon) {
                s.index += 1
                if char == Ch.colon, s.peek() == Ch.colon { s.index += 1 }
                s.add(start, s.identifier(extra: [Ch.dash]), char == Ch.colon ? .keyword : .function)
            } else {
                if Ch.punctuation.contains(char) { s.add(start, start + 1, .punctuation) }
                s.index += 1
            }
        }
        return (s.tokens, state)
    }

    /// In nested rules, `a:hover {` is a selector, not a property.
    private static func isSelectorContinuation(_ s: LineScanner, _ end: Int) -> Bool {
        var index = end
        while index < s.chars.count {
            let char = s.chars[index]
            if char == Ch.semicolon || char == Ch.closeBrace { return false }
            if char == Ch.brace { return true }
            index += 1
        }
        return false
    }

    // MARK: Makefile

    static func makefile(_ line: [UInt16], _ state: LineState) -> ([TokenRange], LineState) {
        var s = LineScanner(line)
        let keywords: Set<String> = [
            "ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "-include", "sinclude", "define", "endef",
            "export", "unexport", "override", "private", "vpath",
        ]
        let recipe = line.first == 0x09
        if !recipe {
            let start = line.firstIndex(where: { !Ch.isSpace($0) }) ?? line.count
            s.index = start
            let end = s.identifier(extra: [Ch.dash, Ch.dot, Ch.slash, utf16Unit("%")])
            let word = s.text(start, end)
            if keywords.contains(word) {
                s.add(start, end, .keyword)
            } else if end > start {
                let next = s.nextSignificant(from: end)
                let after = line.firstIndex(where: { $0 == Ch.colon || $0 == Ch.equals }) ?? line.count
                if next == Ch.colon, after + 1 < line.count ? line[after + 1] != Ch.equals : true {
                    s.add(start, end, .function)
                } else if next == Ch.equals || "?+:".utf16.contains(next ?? 0) && after < line.count && line[after] == Ch.equals || line.indices.contains(after + 1) && line[after + 1] == Ch.equals {
                    s.add(start, end, .attribute)
                } else {
                    s.index = start
                }
            }
        }
        while !s.atEnd {
            let start = s.index
            let char = s.current
            if char == Ch.hash {
                s.add(start, line.count, .comment)
                break
            }
            if char == Ch.dollar {
                s.index += 1
                if let next = s.peek(), next == Ch.paren || next == Ch.brace {
                    let close = next == Ch.paren ? utf16Unit(")") : Ch.closeBrace
                    s.index += 1
                    _ = s.skip(past: [close], escapes: false)
                } else if !s.atEnd {
                    s.index += 1
                }
                s.add(start, s.index, .attribute)
            } else if char == Ch.quote || char == Ch.apostrophe {
                s.index += 1
                _ = s.skip(past: [char], escapes: char == Ch.quote)
                s.add(start, s.index, .string)
            } else {
                s.index += 1
            }
        }
        return (s.tokens, state)
    }
}
