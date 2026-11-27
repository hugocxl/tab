import Foundation

/// Line-oriented formats: INI files, unified diffs, logs and HTTP messages.
extension Tokenizer {
    // MARK: INI

    /// `[section]` headers, `key = value` pairs and `;`, `#` comments, for
    /// INI, properties, editorconfig and gitconfig files.
    static func ini(_ line: [UInt16], _ state: LineState) -> ([TokenRange], LineState) {
        var s = LineScanner(line)
        s.skipWhitespace()
        guard !s.atEnd else { return ([], state) }
        let first = s.current
        if first == Ch.semicolon || first == Ch.hash || first == Ch.bang {
            s.add(s.index, line.count, .comment)
            return (s.tokens, state)
        }
        if first == Ch.bracket {
            let start = s.index
            _ = s.skip(past: [Ch.closeBracket], escapes: false)
            s.add(start, s.index, .type)
        } else if let separator = line[s.index...].firstIndex(where: { $0 == Ch.equals || $0 == Ch.colon }),
                  separator > s.index
        {
            var end = separator
            while end > s.index, Ch.isSpace(line[end - 1]) { end -= 1 }
            s.add(s.index, end, .attribute)
            s.add(separator, separator + 1, .punctuation)
            s.index = separator + 1
        }
        while !s.atEnd {
            let start = s.index
            let char = s.current
            if Ch.isSpace(char) {
                s.index += 1
            } else if (char == Ch.semicolon || char == Ch.hash) && (start == 0 || Ch.isSpace(line[start - 1])) {
                s.add(start, line.count, .comment)
                break
            } else if char == Ch.quote || char == Ch.apostrophe {
                s.index += 1
                _ = s.skip(past: [char], escapes: char == Ch.quote)
                s.add(start, s.index, .string)
            } else {
                while !s.atEnd, !Ch.isSpace(s.current) { s.index += 1 }
                let word = s.text(start, s.index)
                if ["true", "false", "yes", "no", "on", "off"].contains(word.lowercased()) {
                    s.add(start, s.index, .keyword)
                } else if isNumeric(word) {
                    s.add(start, s.index, .number)
                }
            }
        }
        return (s.tokens, state)
    }

    private static func isNumeric(_ word: String) -> Bool {
        guard let first = word.utf16.first, Ch.isDigit(first) || first == Ch.dash else { return false }
        return word.utf16.dropFirst().allSatisfy { Ch.isIdentifier($0) || $0 == Ch.dot }
            && (word.utf16.count > 1 || Ch.isDigit(first))
    }

    // MARK: Diff

    /// A unified diff: added lines are strings, removed lines keywords, hunk
    /// headers numbers and file headers comments.
    static func diff(_ line: [UInt16], _ state: LineState) -> ([TokenRange], LineState) {
        guard let first = line.first else { return ([], state) }
        let kind: TokenKind?
        switch first {
        case utf16Unit("+"):
            kind = hasPrefix(line, "+++") ? .comment : .string
        case Ch.dash:
            kind = hasPrefix(line, "---") && (line.count == 3 || Ch.isSpace(line[3])) ? .comment : .keyword
        case Ch.at:
            kind = hasPrefix(line, "@@") ? .number : nil
        case utf16Unit("d"):
            kind = hasPrefix(line, "diff ") ? .comment : nil
        case utf16Unit("i"):
            kind = hasPrefix(line, "index ") ? .comment : nil
        case utf16Unit("n"):
            kind = hasPrefix(line, "new file") || hasPrefix(line, "new mode") ? .comment : nil
        case utf16Unit("o"):
            kind = hasPrefix(line, "old mode") ? .comment : nil
        case utf16Unit("r"):
            kind = hasPrefix(line, "rename ") ? .comment : nil
        case utf16Unit("s"):
            kind = hasPrefix(line, "similarity ") ? .comment : nil
        case utf16Unit("B"):
            kind = hasPrefix(line, "Binary files") ? .comment : nil
        case Ch.backslash:
            kind = hasPrefix(line, "\\ No newline") ? .comment : nil
        default:
            kind = nil
        }
        guard let kind else { return ([], state) }
        return ([TokenRange(location: 0, length: line.count, kind: kind)], state)
    }

    private static func hasPrefix(_ line: [UInt16], _ prefix: StaticString) -> Bool {
        var index = 0
        var matched = true
        prefix.withUTF8Buffer { buffer in
            guard line.count >= buffer.count else {
                matched = false
                return
            }
            for byte in buffer {
                if line[index] != UInt16(byte) {
                    matched = false
                    return
                }
                index += 1
            }
        }
        return matched
    }

    // MARK: Log

    /// Timestamps and numbers, log levels and quoted strings.
    static func log(_ line: [UInt16], _ state: LineState) -> ([TokenRange], LineState) {
        var s = LineScanner(line)
        while !s.atEnd {
            let start = s.index
            let char = s.current
            if char == Ch.quote {
                s.index += 1
                _ = s.skip(past: [Ch.quote], escapes: true)
                s.add(start, s.index, .string)
            } else if Ch.isDigit(char) {
                while !s.atEnd, Ch.isIdentifier(s.current) || ":-./+,".utf16.contains(s.current) { s.index += 1 }
                var end = s.index
                while end > start, ",.:-/+".utf16.contains(line[end - 1]) { end -= 1 }
                s.add(start, end, .number)
                s.index = max(end, start + 1)
            } else if Ch.isIdentifierStart(char) {
                let end = s.identifier()
                switch s.text(start, end).uppercased() {
                case "ERROR", "ERR", "FATAL", "CRITICAL", "SEVERE", "PANIC", "FAILED", "FAILURE", "EXCEPTION":
                    s.add(start, end, .keyword)
                case "WARN", "WARNING":
                    s.add(start, end, .attribute)
                case "INFO", "NOTICE", "DEBUG", "TRACE":
                    s.add(start, end, .comment)
                case "TRUE", "FALSE", "NULL", "NONE", "NIL":
                    s.add(start, end, .number)
                default:
                    break
                }
            } else {
                s.index += 1
            }
        }
        return (s.tokens, state)
    }

    // MARK: HTTP

    private static let httpMethods: Set<String> = [
        "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE", "CONNECT",
    ]

    /// A request line or status line, headers, and a JSON-ish body after the
    /// blank line.
    static func http(_ line: [UInt16], _ state: LineState) -> ([TokenRange], LineState) {
        var s = LineScanner(line)
        s.skipWhitespace()
        if s.atEnd {
            // The blank line after the headers starts the body.
            return ([], state.depth > 0 ? LineState(mode: .fence, depth: 1) : state)
        }
        if s.current == Ch.hash || s.matches(Array("//".utf16)) {
            let isSeparator = s.matches(Array("###".utf16))
            s.add(s.index, line.count, .comment)
            return (s.tokens, isSeparator ? .start : state)
        }
        if state.mode == .fence {
            let (tokens, _) = json(line, .start)
            return (tokens, state)
        }
        let start = s.index
        let end = s.identifier(extra: [Ch.slash, Ch.dot, Ch.dash])
        let word = s.text(start, end)
        if word.hasPrefix("HTTP/") {
            s.add(start, end, .type)
            s.skipWhitespace()
            let code = s.index
            while !s.atEnd, Ch.isDigit(s.current) { s.index += 1 }
            s.add(code, s.index, .number)
            return (s.tokens, LineState(mode: .normal, depth: 1))
        }
        if httpMethods.contains(word), s.peek().map(Ch.isSpace) ?? false {
            s.add(start, end, .keyword)
            s.skipWhitespace()
            let url = s.index
            while !s.atEnd, !Ch.isSpace(s.current) { s.index += 1 }
            s.add(url, s.index, .string)
            s.skipWhitespace()
            let version = s.index
            while !s.atEnd, !Ch.isSpace(s.current) { s.index += 1 }
            if s.text(version, s.index).hasPrefix("HTTP/") { s.add(version, s.index, .type) }
            return (s.tokens, LineState(mode: .normal, depth: 1))
        }
        // A header: `Name: value`.
        if end > start, end < line.count, line[end] == Ch.colon {
            s.add(start, end, .attribute)
            s.add(end, end + 1, .punctuation)
            s.index = end + 1
            s.skipWhitespace()
            let value = s.index
            var valueEnd = line.count
            while valueEnd > value, Ch.isSpace(line[valueEnd - 1]) { valueEnd -= 1 }
            if valueEnd > value {
                let isNumber = line[value..<valueEnd].allSatisfy { Ch.isDigit($0) || $0 == Ch.dot }
                s.add(value, valueEnd, isNumber ? .number : .string)
            }
        }
        return (s.tokens, state)
    }
}
