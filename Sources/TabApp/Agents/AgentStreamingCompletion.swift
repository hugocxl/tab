import Foundation

/// Completes unclosed inline Markdown at the end of a streaming response, like the removed web
/// renderer: an unfinished `**bold`, `_italic`, `~~strike` or `` `code `` renders styled up to the
/// cursor, an unfinished `[label](partial` shows its label as plain text and an unfinished image
/// is hidden. Only the last block of a streaming message is repaired; completed messages render
/// their source unchanged.
enum AgentStreamingCompletion {
    /// Blocks longer than this are left as they are.
    static let maximumBlock = 50_000

    /// `source` without a last line that could still turn into structure: a lone `-` that
    /// would make the sentence above a heading, `#`, `>`, `1.`, one or two backticks, or a
    /// table whose separator row hasn't arrived. They render once the next text decides.
    static func holdingBackAmbiguousTail(_ source: String) -> String {
        guard !source.isEmpty, !source.hasSuffix("\n\n") else { return source }
        var lines = source.components(separatedBy: "\n")
        let endsLine = lines.last == ""
        if endsLine { lines.removeLast() }
        guard let last = lines.last else { return source }
        let trimmed = last.trimmingCharacters(in: .whitespaces)
        // Inside an open code fence, nothing is structure.
        let fences = lines.dropLast().filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count
        guard fences % 2 == 0 else { return source }
        if isTableLine(trimmed) {
            var start = lines.count - 1
            while start > 0, isTableLine(lines[start - 1].trimmingCharacters(in: .whitespaces)) { start -= 1 }
            let run = lines[start...].map { $0.trimmingCharacters(in: .whitespaces) }
            if run.count < 2 || !isSeparatorRow(run[run.startIndex + 1], columns: cells(run[run.startIndex]).count) {
                return lines[..<start].joined(separator: "\n") + (start > 0 ? "\n" : "")
            }
            return source
        }
        // A finished line has decided what it is.
        guard !endsLine, isAmbiguous(trimmed) else { return source }
        return lines.dropLast().joined(separator: "\n") + (lines.count > 1 ? "\n" : "")
    }

    private static func isAmbiguous(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 8 else { return false }
        if line.allSatisfy({ $0 == "-" }) || line.allSatisfy({ $0 == "=" }) || line.allSatisfy({ $0 == "#" }) { return true }
        if ["*", "+", ">", "`", "``"].contains(line) { return true }
        // A list number with nothing after it yet: `1.` or `12)`.
        if let mark = line.last, ".)".contains(mark), line.dropLast().allSatisfy(\.isNumber), line.count > 1 { return true }
        return false
    }

    private static func isTableLine(_ line: String) -> Bool { line.hasPrefix("|") }

    private static func cells(_ line: String) -> [String] {
        line.split(separator: "|", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A complete separator row: one dash cell for each of the header's columns.
    private static func isSeparatorRow(_ line: String, columns: Int) -> Bool {
        let cells = cells(line)
        return cells.count == columns && cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { "-:".contains($0) } && cell.contains("-")
        }
    }

    /// `blocks` with the last paragraph, heading or list item completed.
    static func completingLastBlock(_ blocks: [AgentMarkdown.Block]) -> [AgentMarkdown.Block] {
        guard let last = blocks.last else { return blocks }
        let repaired: AgentMarkdown.Block
        switch last {
        case .paragraph(let text): repaired = .paragraph(complete(text))
        case .heading(let level, let text): repaired = .heading(level, complete(text))
        case .list(let marker, let text, let depth, let structure): repaired = .list(marker, complete(text), depth, structure: structure)
        default: return blocks
        }
        guard repaired != last else { return blocks }
        var result = blocks
        result[result.count - 1] = repaired
        return result
    }

    private struct Delimiter {
        let character: Character
        var count: Int
        let index: Int
    }

    /// `text` with its trailing unclosed inline syntax completed or removed.
    static func complete(_ text: String) -> String {
        guard text.count <= maximumBlock, text.contains(where: { "*_~`[".contains($0) }) else { return text }
        let characters = Array(text)
        var delimiters: [Delimiter] = []
        var brackets: [(index: Int, image: Bool)] = []
        /// Characters to drop: dangling markers with nothing after them.
        var removals: [Range<Int>] = []
        var openCode: (index: Int, count: Int)?
        var partialLink: (open: Int, image: Bool, close: Int)?
        var index = 0
        scan: while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                index += 2
            case "`":
                let start = index
                while index < characters.count, characters[index] == "`" { index += 1 }
                let count = index - start
                guard let end = closingRun(of: count, in: characters, from: index) else {
                    openCode = (start, count)
                    break scan
                }
                index = end
            case "$":
                // Closed inline math is opaque; an unclosed dollar is ordinary text.
                var cursor = index + 1
                while cursor < characters.count, characters[cursor] != "$", !characters[cursor].isNewline {
                    if characters[cursor] == "\\" { cursor += 1 }
                    cursor += 1
                }
                index = cursor < characters.count && characters[cursor] == "$" ? cursor + 1 : index + 1
            case "<":
                // Tags and autolinks keep their attributes and URLs out of emphasis.
                var cursor = index + 1
                if cursor < characters.count, characters[cursor].isLetter || characters[cursor] == "/" {
                    while cursor < characters.count, characters[cursor] != ">", !characters[cursor].isNewline, characters[cursor] != "<" { cursor += 1 }
                    if cursor < characters.count, characters[cursor] == ">" { index = cursor + 1; continue }
                }
                index += 1
            case "h" where isURLStart(characters, at: index):
                while index < characters.count, !characters[index].isWhitespace { index += 1 }
            case "!" where index + 1 < characters.count && characters[index + 1] == "[":
                brackets.append((index, true))
                index += 2
            case "[":
                brackets.append((index, false))
                index += 1
            case "]":
                guard let opener = brackets.popLast() else { index += 1; continue }
                guard index + 1 < characters.count, characters[index + 1] == "(" else { index += 1; continue }
                guard let end = destinationEnd(characters, from: index + 2) else {
                    partialLink = (opener.index, opener.image, index)
                    break scan
                }
                index = end
            case "*", "_", "~":
                let start = index
                while index < characters.count, characters[index] == character { index += 1 }
                var count = index - start
                if character == "~" {
                    guard count >= 2 else { continue }
                    count = 2
                }
                let before: Character? = start > 0 ? characters[start - 1] : nil
                let after: Character? = index < characters.count ? characters[index] : nil
                let followedBySpace = after.map { $0.isWhitespace } ?? true
                let precededBySpace = before.map { $0.isWhitespace } ?? true
                var canOpen = !followedBySpace
                var canClose = !precededBySpace
                if character == "_" {
                    let alphanumericBefore = before.map { $0.isLetter || $0.isNumber } ?? false
                    let alphanumericAfter = after.map { $0.isLetter || $0.isNumber } ?? false
                    canOpen = canOpen && !alphanumericBefore
                    canClose = canClose && !alphanumericAfter
                }
                if canClose, let match = delimiters.lastIndex(where: { $0.character == character }) {
                    let used = min(count, delimiters[match].count)
                    delimiters[match].count -= used
                    count -= used
                    // Unclosed delimiters inside a closed span stay literal, as in CommonMark.
                    delimiters.removeSubrange((delimiters[match].count == 0 ? match : match + 1)...)
                }
                if count > 0, canOpen {
                    delimiters.append(Delimiter(character: character, count: count, index: index - count))
                } else if count > 0, after == nil, precededBySpace {
                    // A marker just streamed in, with no content yet.
                    removals.append(start..<index)
                }
            default:
                index += 1
            }
        }
        var end = characters.count
        var tail = ""
        if let link = partialLink {
            end = link.open
            if !link.image { tail = String(characters[(link.open + 1)..<link.close]) }
            delimiters.removeAll { $0.index >= link.open && link.image }
        } else if let code = openCode {
            let content = String(characters[(code.index + code.count)...])
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                end = code.index
            } else {
                end = code.index
                let fence = String(repeating: "`", count: code.count)
                tail = fence + content + fence
            }
        } else if let bracket = brackets.last {
            // `[label` without its closing bracket shows the label alone; an image waits.
            end = bracket.index
            if !bracket.image { tail = String(characters[(bracket.index + 1)...]) }
            if bracket.image { delimiters.removeAll { $0.index >= bracket.index } }
        }
        var output = ""
        var cursor = 0
        // Openers with nothing after them are removed instead of closed.
        var dropped: [Range<Int>] = removals
        var closers: [Delimiter] = []
        for delimiter in delimiters {
            let contentStart = delimiter.index + delimiter.count
            let following = contentStart < end ? String(characters[contentStart..<end]) : ""
            let hasContent = following.contains { !$0.isWhitespace && !"*_~".contains($0) } || !tail.trimmingCharacters(in: .whitespaces).isEmpty
            if hasContent { closers.append(delimiter) } else { dropped.append(delimiter.index..<contentStart) }
        }
        for range in dropped.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= cursor && range.lowerBound < end {
            output += String(characters[cursor..<range.lowerBound])
            cursor = min(range.upperBound, end)
        }
        if cursor < end { output += String(characters[cursor..<end]) }
        output += tail
        guard !closers.isEmpty else { return output }
        // Closing delimiters must follow a non-space character to close.
        while let last = output.last, last.isWhitespace { output.removeLast() }
        for delimiter in closers.reversed() { output += String(repeating: delimiter.character, count: delimiter.count) }
        return output
    }

    private static func closingRun(of count: Int, in characters: [Character], from start: Int) -> Int? {
        var index = start
        while index < characters.count {
            guard characters[index] == "`" else { index += 1; continue }
            let run = index
            while index < characters.count, characters[index] == "`" { index += 1 }
            if index - run == count { return index }
        }
        return nil
    }

    /// The index after a link destination's closing parenthesis, or nil while it is unfinished.
    private static func destinationEnd(_ characters: [Character], from start: Int) -> Int? {
        var depth = 1
        var index = start
        while index < characters.count {
            if characters[index] == "\\" { index += 2; continue }
            if characters[index] == "(" { depth += 1 }
            if characters[index] == ")" { depth -= 1; if depth == 0 { return index + 1 } }
            index += 1
        }
        return nil
    }

    private static func isURLStart(_ characters: [Character], at index: Int) -> Bool {
        guard index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber) else { return false }
        let prefix = String(characters[index..<min(characters.count, index + 8)]).lowercased()
        return prefix.hasPrefix("http://") || prefix.hasPrefix("https://")
    }
}
