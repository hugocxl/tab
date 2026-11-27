import Foundation

/// Native block parsing for the response surface. Open fences and unfinished table rows remain
/// visible during streaming; completed block indices stay stable as the last block grows.
@MainActor
enum AgentResponseParser {
    static func parse(_ source: String, parseRawHTML: Bool = true, listAncestors: [Bool] = []) -> [AgentMarkdown.Block] {
        parseInternal(source, parseRawHTML: parseRawHTML, listAncestors: listAncestors, lineOffset: 0, captureCommit: false).blocks
    }

    struct StreamParseResult {
        let blocks: [AgentMarkdown.Block]
        let commitLine: Int?
        let commitUTF8Offset: Int
        let commitBlockCount: Int
    }

    static func parseForStreaming(_ source: String, parseRawHTML: Bool, lineOffset: Int, captureCommit: Bool) -> StreamParseResult {
        parseInternal(source, parseRawHTML: parseRawHTML, listAncestors: [], lineOffset: lineOffset, captureCommit: captureCommit)
    }

    private static func parseInternal(_ source: String, parseRawHTML: Bool, listAncestors: [Bool], lineOffset: Int, captureCommit: Bool) -> StreamParseResult {
        let input = AgentMarkdownSource(source)
        let lines = input.lines
        var result: [AgentMarkdown.Block] = []
        var paragraph: [String] = []
        var paragraphStart = 0
        var listContexts: [ListContext] = []
        var looseLists: Set<Int> = []
        var lastNumbers: [Int: Int] = [:]
        var blankBefore = false
        var commitLine: Int?
        var commitBlockCount = 0
        var i = 0
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(input.join(paragraph, startingAt: paragraphStart))) }
            paragraph.removeAll(keepingCapacity: true)
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); blankBefore = true; i += 1; continue }
            if list(line) == nil { listContexts.removeAll(keepingCapacity: true) }
            // After a blank line, a completed non-indented line outside any active list
            // guarantees every earlier block is final and cannot be altered by later chunks.
            if captureCommit, blankBefore, paragraph.isEmpty, listContexts.isEmpty,
               indentation(line) < 4, i > 0, i < lines.count - 1, !result.isEmpty {
                commitLine = i
                commitBlockCount = result.count
            }
            if paragraph.isEmpty, indentation(line) >= 4, listContexts.isEmpty || list(line) == nil {
                let start = i
                var code: [String] = []
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).isEmpty { code.append("") }
                    else if indentation(lines[i]) >= 4 { code.append(removingIndent(lines[i], columns: 4)) }
                    else { break }
                    i += 1
                }
                while code.last == "" { code.removeLast() }
                result.append(.code("", input.join(code, startingAt: start) + "\n", closed: true))
                continue
            }
            if paragraph.isEmpty, let note = AgentMarkdownFootnotes.definition(in: lines, at: i, source: input) {
                result.append(.footnoteDefinition(note.label, note.body))
                i += note.count
                continue
            }
            if paragraph.isEmpty, let definition = AgentMarkdownReferences.definition(in: lines, at: i) {
                result.append(.reference(definition.label, definition.destination))
                i += definition.count
                continue
            }
            if parseRawHTML, trimmed.range(of: #"^<details(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                flush()
                var body: [String] = []
                let bodyStart = i
                var balance = 0
                var detailFence: Fence?
                repeat {
                    let current = lines[i]
                    if let fence = detailFence {
                        if closesFence(current, fence: fence) { detailFence = nil }
                        body.append(current); i += 1; continue
                    }
                    if let fence = openingFence(current) {
                        detailFence = fence
                        body.append(current); i += 1; continue
                    }
                    let opens = matches(#"(?i)<details(?:\s[^>]*)?>"#, in: current)
                    let closes = matches(#"(?i)</details\s*>"#, in: current)
                    balance += opens - closes
                    body.append(current)
                    i += 1
                } while i < lines.count && balance > 0
                var source = input.join(body, startingAt: bodyStart)
                let openingEnd = source.firstIndex(of: ">")
                let opening = openingEnd.map { String(source[...$0]) } ?? ""
                if let openingEnd { source = String(source[source.index(after: openingEnd)...]) }
                if balance == 0, let expression = try? NSRegularExpression(pattern: #"</details\s*>"#, options: .caseInsensitive),
                   let match = expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).last,
                   let end = Range(match.range, in: source) {
                    source.removeSubrange(end)
                }
                var summary = "Details"
                if let match = source.range(of: #"(?is)<summary\b[^>]*>.*?</summary\s*>"#, options: .regularExpression) {
                    summary = String(source[match]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    source.removeSubrange(match)
                }
                result.append(.details(summary, source.trimmingCharacters(in: .newlines),
                    opening.range(of: #"\sopen(?:\s|=|>)"#, options: [.regularExpression, .caseInsensitive]) != nil))
                continue
            }
            if parseRawHTML, trimmed.hasPrefix("<"), let html = AgentInlineHTML.block(in: lines, at: i) {
                flush()
                result.append(contentsOf: parse(html.markdown, parseRawHTML: true, listAncestors: listAncestors))
                i += html.count
                continue
            }
            if let fence = openingFence(line) {
                flush()
                var code: [String] = []
                var closed = false
                i += 1
                let codeStart = i
                while i < lines.count {
                    if closesFence(lines[i], fence: fence) {
                        closed = true
                        i += 1
                        break
                    }
                    code.append(removingIndent(lines[i], columns: fence.indent))
                    i += 1
                }
                // The final empty source line represents EOF, not an additional code line.
                if !closed, code.last == "", lines.last == "" { code.removeLast() }
                var content = input.join(code, startingAt: codeStart)
                if !content.isEmpty { content += "\n" }
                // Math and diagrams render once their fence closes; until then they stream as code.
                let language = AgentMarkdownMath.fenceLanguage(fence.info)
                if closed, AgentMarkdownMath.fenceLanguages.contains(language),
                   !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.math(content.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else if closed, language == "mermaid", !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.diagram(content))
                } else {
                    result.append(.code(fence.info, content, closed: closed))
                }
                continue
            }
            if let math = AgentMarkdownMath.displayBlock(in: lines, at: i) {
                flush()
                result.append(.math(math.latex))
                i += math.count
                continue
            }
            if parseRawHTML, paragraph.isEmpty, trimmed.lowercased().hasPrefix("<table"), let table = htmlTable(lines, from: i) {
                flush()
                result.append(.table(table.headers, table.rows, Array(repeating: .left, count: table.headers.count)))
                i = table.end
                continue
            }
            if i + 1 < lines.count, line.contains("|"), !startsTableBoundary(line), let alignments = tableSeparator(lines[i + 1]) {
                let headers = cells(line)
                if headers.count == alignments.count {
                    flush()
                    var rows: [[String]] = []
                    i += 2
                    while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !startsTableBoundary(lines[i]) {
                        var row = Array(cells(lines[i]).prefix(headers.count))
                        row += Array(repeating: "", count: max(0, headers.count - row.count))
                        rows.append(row)
                        i += 1
                    }
                    result.append(.table(headers, rows, alignments))
                    continue
                }
            }
            if let heading = atxHeading(line) {
                flush()
                result.append(.heading(heading.level, heading.title))
            } else if !paragraph.isEmpty, let level = setextLevel(line) {
                let title = input.join(paragraph, startingAt: paragraphStart)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                result.append(.heading(level, title))
                paragraph.removeAll(keepingCapacity: true)
            } else if isRule(trimmed) {
                flush()
                result.append(.divider)
            } else if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                let quoteStart = i
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix(">") else { break }
                    let stripped = next.dropFirst()
                    quoted.append(String(stripped.first == " " ? stripped.dropFirst() : stripped))
                    i += 1
                }
                result.append(.quote(input.join(quoted, startingAt: quoteStart)))
                continue
            } else if let entry = list(line), paragraph.isEmpty || (!entry.text.isEmpty && (entry.number == nil || entry.number == 1)) {
                flush()
                while let last = listContexts.last, last.indent > entry.indent { listContexts.removeLast() }
                if listContexts.last?.indent == entry.indent, listContexts.last?.kind != entry.kind { listContexts.removeLast() }
                if listContexts.last?.indent != entry.indent {
                    listContexts.append(ListContext(id: lineOffset + i, parentID: listContexts.last?.id, indent: entry.indent, kind: entry.kind, start: entry.number, nextNumber: entry.number))
                }
                let depth = max(0, listContexts.count - 1)
                let context = listContexts[depth]
                if blankBefore, context.id != lineOffset + i { looseLists.insert(context.id) }
                blankBefore = false
                let number = listContexts[depth].nextNumber
                if let number { listContexts[depth].nextNumber = number + 1; lastNumbers[context.id] = number }
                var content = entry.text
                let contentIndent = entry.contentIndent
                var candidate = [entry.text]
                var end = i + 1
                while end < lines.count {
                    if lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
                        var next = end + 1
                        while next < lines.count && lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                        guard next < lines.count, indentation(lines[next]) >= contentIndent else { break }
                        candidate.append("")
                    } else {
                        guard indentation(lines[end]) >= contentIndent else { break }
                        candidate.append(removingIndent(lines[end], columns: contentIndent))
                    }
                    end += 1
                }
                // Blank code lines belong to the fenced block, not to the list's
                // paragraph separation. Only blanks outside fences can loosen an item.
                var itemFence: Fence?
                var outsideBlanks: Set<Int> = []
                for (index, line) in candidate.enumerated() {
                    if let fence = itemFence {
                        if closesFence(line, fence: fence) { itemFence = nil }
                        continue
                    }
                    if let fence = openingFence(line) { itemFence = fence; continue }
                    if line.isEmpty, index + 1 < candidate.count { outsideBlanks.insert(index) }
                }
                let hasLooseParagraph = candidate.indices.contains { index in
                    index > 0 && outsideBlanks.contains(index - 1) && !candidate[index].isEmpty && list(candidate[index]) == nil
                }
                let rich = hasLooseParagraph || candidate.contains { line in
                    let value = line.trimmingCharacters(in: .whitespaces)
                    return value.hasPrefix("```") || value.hasPrefix("~~~") || value.hasPrefix(">") || value.hasPrefix("<details")
                        || value.hasPrefix("$$") || value.hasPrefix("\\[")
                } || zip(candidate, candidate.dropFirst()).contains { pair in
                    pair.0.contains("|") && tableSeparator(pair.1) != nil
                }
                if rich {
                    if !outsideBlanks.isEmpty { looseLists.insert(context.id) }
                    content = input.join(candidate, startingAt: i); i = end - 1
                }

                while !rich, i + 1 < lines.count, !lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty,
                      continuesListParagraph(lines[i + 1], parentIndent: entry.indent) {
                    content += input.ending(after: i) + lines[i + 1].trimmingCharacters(in: .whitespaces)
                    i += 1
                }
                let sameKindDepth = listAncestors.filter { $0 == (number != nil) }.count + listContexts.filter { ($0.nextNumber != nil) == (number != nil) }.count - 1
                var marker = ["•", "◦", "▪"][min(sameKindDepth, 2)]
                if let number {
                    marker = String(number) + "."
                    if sameKindDepth == 1, number > 0 { marker = alphabetic(number) + "." }
                    else if sameKindDepth >= 2, (1...3999).contains(number) { marker = roman(number) + "." }
                }
                if content.hasPrefix("[ ] ") { marker = "☐"; content = String(content.dropFirst(4)) }
                if content.lowercased().hasPrefix("[x] ") { marker = "☑"; content = String(content.dropFirst(4)) }
                let structure = AgentListItemStructure(id: context.id, parentID: context.parentID, delimiter: context.kind, start: context.start, number: number, ancestors: listAncestors + listContexts.dropLast().map { $0.start != nil })
                result.append(rich ? .listBlock(marker, content, depth, structure: structure) : .list(marker, content, depth, structure: structure))
            } else {
                if paragraph.isEmpty { listContexts.removeAll(keepingCapacity: true); paragraphStart = i }
                paragraph.append(line)
            }
            i += 1
        }
        flush()
        let finalized: [AgentMarkdown.Block] = result.map { block in
            guard var structure = block.listStructure else { return block }
            structure.isLoose = looseLists.contains(structure.id)
            structure.lastNumber = lastNumbers[structure.id]
            switch block {
            case .list(let marker, let text, let depth, _): return .list(marker, text, depth, structure: structure)
            case .listBlock(let marker, let text, let depth, _): return .listBlock(marker, text, depth, structure: structure)
            default: return block
            }
        }
        return StreamParseResult(
            blocks: finalized,
            commitLine: commitLine,
            commitUTF8Offset: commitLine.map(input.utf8Offset(ofLine:)) ?? 0,
            commitBlockCount: commitBlockCount
        )
    }

    private static func matches(_ expression: String, in source: String) -> Int {
        (try? NSRegularExpression(pattern: expression))?.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)) ?? 0
    }

    private typealias Fence = AgentMarkdownFence

    private static func openingFence(_ line: String) -> Fence? { AgentMarkdownFence.opening(line) }

    private static func closesFence(_ line: String, fence: Fence) -> Bool { fence.isClosed(by: line) }

    private static func removingIndent(_ line: String, columns: Int) -> String {
        var column = 0
        var index = line.startIndex
        while index < line.endIndex, column < columns, line[index] == " " || line[index] == "\t" {
            column += line[index] == "\t" ? 4 - column % 4 : 1
            index = line.index(after: index)
        }
        return String(repeating: " ", count: max(0, column - columns)) + line[index...]
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 - $0 % 4 : 1) }
    }

    private struct ListContext {
        let id: Int
        let parentID: Int?
        let indent: Int
        let kind: Character
        let start: Int?
        var nextNumber: Int?
    }

    private static func list(_ line: String) -> (indent: Int, kind: Character, number: Int?, text: String, contentIndent: Int)? {
        let value = line.drop { $0 == " " || $0 == "\t" }
        let indent = indentation(line)
        let number: Int?
        let kind: Character
        let markerLength: Int
        if let first = value.first, "-*+".contains(first) {
            number = nil; kind = first; markerLength = 1
        } else {
            let digits = value.prefix { $0 >= "0" && $0 <= "9" }
            guard !digits.isEmpty, digits.count < 10, let parsed = Int(digits),
                  let delimiter = value.dropFirst(digits.count).first, ".)".contains(delimiter) else { return nil }
            number = parsed; kind = delimiter; markerLength = digits.count + 1
        }
        let rest = value.dropFirst(markerLength)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let startColumn = indent + markerLength
        var column = startColumn
        var end = rest.startIndex
        while end < rest.endIndex, rest[end] == " " || rest[end] == "\t" {
            column += rest[end] == "\t" ? 4 - column % 4 : 1
            end = rest.index(after: end)
        }
        let padding = column - startColumn
        if padding > 4 {
            let first = rest.first == "\t" ? 4 - startColumn % 4 : 1
            let text = String(repeating: " ", count: first - 1) + rest.dropFirst()
            return (indent, kind, number, text, startColumn + 1)
        }
        return (indent, kind, number, String(rest[end...]), startColumn + max(1, padding))
    }

    private static func alphabetic(_ number: Int) -> String {
        var number = number
        var result = ""
        while number > 0 {
            number -= 1
            if let scalar = UnicodeScalar(97 + number % 26) { result.insert(Character(scalar), at: result.startIndex) }
            number /= 26
        }
        return result
    }

    private static func continuesListParagraph(_ line: String, parentIndent: Int) -> Bool {
        if let candidate = list(line) {
            return candidate.indent > parentIndent
                && (candidate.text.isEmpty || (candidate.number != nil && candidate.number != 1))
        }
        return !startsTableBoundary(line, includeIndentedCode: false)
    }

    private static func isRule(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        return compact.count >= 3 && ["-", "*", "_"].contains(String(compact.prefix(1))) && Set(compact).count == 1
    }

    private static func setextLevel(_ line: String) -> Int? {
        guard indentation(line) < 4 else { return nil }
        let text = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !text.isEmpty, Set(text).count == 1 else { return nil }
        return text.first == "=" ? 1 : text.first == "-" ? 2 : nil
    }

    private static func atxHeading(_ line: String) -> (level: Int, title: String)? {
        guard indentation(line) < 4 else { return nil }
        let text = line.drop { $0 == " " || $0 == "\t" }
        let count = text.prefix { $0 == "#" }.count
        guard (1...6).contains(count) else { return nil }
        let rest = text.dropFirst(count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var title = String(rest).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        if !title.isEmpty, title.allSatisfy({ $0 == "#" }) { title = "" }
        else if let closing = title.range(of: #"[ \t]+#+$"#, options: .regularExpression) {
            title.removeSubrange(closing)
        }
        return (count, title)
    }

    private static func startsTableBoundary(_ line: String, includeIndentedCode: Bool = true) -> Bool {
        if includeIndentedCode, indentation(line) >= 4 { return true }
        let text = line.trimmingCharacters(in: .whitespaces)
        return atxHeading(line) != nil || openingFence(line) != nil || list(line) != nil
            || text.hasPrefix(">") || isRule(text) || text.hasPrefix("<details")
    }

    static func cells(_ line: String) -> [String] {
        var source = line.trimmingCharacters(in: .whitespaces)
        if source.first == "|" { source.removeFirst() }
        if source.last == "|" {
            let slashes = source.dropLast().reversed().prefix { $0 == "\\" }.count
            if slashes % 2 == 0 { source.removeLast() }
        }
        var cells: [String] = []
        var cell = ""
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "\\" {
                let next = source.index(after: index)
                if next < source.endIndex, source[next] == "|" || source[next] == "\\" {
                    if source[next] == "\\" { cell.append("\\") }
                    cell.append(source[next])
                    index = source.index(after: next)
                    continue
                }
                cell.append(character)
            } else if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else { cell.append(character) }
            index = source.index(after: index)
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func tableSeparator(_ line: String) -> [AgentMarkdown.TableAlignment]? {
        guard !startsTableBoundary(line) else { return nil }
        let parts = cells(line)
        guard !parts.isEmpty, parts.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }) else { return nil }
        return parts.map { part in
            if part.hasPrefix(":"), part.hasSuffix(":") { return .center }
            return part.hasSuffix(":") ? .right : .left
        }
    }

    private static let htmlRow = try? NSRegularExpression(pattern: "<tr\\b[^>]*>(.*?)</tr\\s*>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let htmlCell = try? NSRegularExpression(pattern: "<t([hd])\\b[^>]*>(.*?)</t[hd]\\s*>", options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// A whole `<table>` an assistant wrote as HTML, as a table's header and rows; nil until
    /// its closing tag arrives or when it has no rows. `end` is the line after it.
    static func htmlTable(_ lines: [String], from start: Int) -> (headers: [String], rows: [[String]], end: Int)? {
        var end = start
        while end < lines.count, end - start < 2000 {
            defer { end += 1 }
            guard lines[end].range(of: "</table", options: .caseInsensitive) != nil else { continue }
            let html = lines[start...end].joined(separator: "\n") as NSString
            guard let rowPattern = htmlRow, let cellPattern = htmlCell else { return nil }
            var headerRow: [String]?
            var rows: [[String]] = []
            for row in rowPattern.matches(in: html as String, range: NSRange(location: 0, length: html.length)) {
                let body = html.substring(with: row.range(at: 1)) as NSString
                let cells = cellPattern.matches(in: body as String, range: NSRange(location: 0, length: body.length))
                let texts = cells.map { body.substring(with: $0.range(at: 2)).split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                let isHeader = !cells.isEmpty && cells.allSatisfy { body.substring(with: $0.range(at: 1)).lowercased() == "h" }
                if headerRow == nil, rows.isEmpty, isHeader { headerRow = texts } else if !texts.isEmpty { rows.append(texts) }
            }
            let headers = headerRow ?? (rows.isEmpty ? [] : rows.removeFirst())
            guard !headers.isEmpty else { return nil }
            let width = max(headers.count, rows.map(\.count).max() ?? 0)
            func padded(_ row: [String]) -> [String] { row + Array(repeating: "", count: width - row.count) }
            return (padded(headers), rows.map(padded), end + 1)
        }
        return nil
    }

    private static func roman(_ number: Int) -> String {
        var remaining = number
        var result = ""
        for (value, letters) in [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")] {
            while remaining >= value { result += letters; remaining -= value }
        }
        return result
    }
}

/// Checkpointed streaming parser: remembers finalized leading blocks across append-only
/// updates so only the uncommitted tail is scanned, held back, and parsed on each chunk.
@MainActor
final class AgentStreamingParser {
    private var parseRawHTML = true
    private var lastSource = ""
    private var committedUTF8Count = 0
    private var committedLineCount = 0
    private var committedBlocks: [AgentMarkdown.Block] = []
    private var committedReferences: [String: String] = [:]
    private var committedHasFootnotes = false
    /// Count of updates that reused a committed prefix instead of parsing from byte zero.
    private(set) var tailParseCount = 0
    /// Byte length of the tail parsed on the most recent update.
    private(set) var lastParsedTailBytes = 0

    func reset() {
        lastSource = ""
        committedUTF8Count = 0
        committedLineCount = 0
        committedBlocks.removeAll(keepingCapacity: true)
        committedReferences.removeAll(keepingCapacity: true)
        committedHasFootnotes = false
    }

    func parse(_ source: String, isStreaming: Bool, parseRawHTML: Bool) -> (blocks: [AgentMarkdown.Block], references: [String: String], completedTail: Bool) {
        if self.parseRawHTML != parseRawHTML || !matchesCommittedPrefix(source) {
            self.parseRawHTML = parseRawHTML
            reset()
        }
        lastSource = source
        let usedCheckpoint = committedUTF8Count > 0
        let tailStart = source.utf8.index(source.utf8.startIndex, offsetBy: committedUTF8Count)
        let rawTail = usedCheckpoint ? String(source[tailStart...]) : source
        let heldTail = isStreaming ? AgentStreamingCompletion.holdingBackAmbiguousTail(rawTail) : rawTail
        lastParsedTailBytes = heldTail.utf8.count
        if usedCheckpoint { tailParseCount += 1 }
        let canCommit = isStreaming && !rawTail.utf8.contains(0)
        let parsed = AgentResponseParser.parseForStreaming(heldTail, parseRawHTML: parseRawHTML, lineOffset: committedLineCount, captureCommit: canCommit)

        var tailBlocks = parsed.blocks
        if canCommit, let commitLine = parsed.commitLine, commitLine > 0, parsed.commitBlockCount > 0, parsed.commitUTF8Offset > 0 {
            let newlyCommitted = Array(parsed.blocks[..<parsed.commitBlockCount])
            committedBlocks.append(contentsOf: newlyCommitted)
            let newRefs = AgentMarkdownReferences.collect(newlyCommitted, parseRawHTML: parseRawHTML)
            for (key, value) in newRefs where committedReferences[key] == nil {
                committedReferences[key] = value
            }
            if !committedHasFootnotes {
                committedHasFootnotes = Self.containsFootnoteDefinition(newlyCommitted, parseRawHTML: parseRawHTML)
            }
            committedLineCount += commitLine
            committedUTF8Count += parsed.commitUTF8Offset
            tailBlocks = Array(parsed.blocks[parsed.commitBlockCount...])
        }

        var completedTail = false
        if isStreaming {
            let completed = AgentStreamingCompletion.completingLastBlock(tailBlocks)
            completedTail = completed != tailBlocks || heldTail != rawTail
            tailBlocks = completed
        }

        var references = committedReferences
        let tailRefs = AgentMarkdownReferences.collect(tailBlocks, parseRawHTML: parseRawHTML)
        for (key, value) in tailRefs where references[key] == nil {
            references[key] = value
        }

        var allBlocks: [AgentMarkdown.Block]
        if committedBlocks.isEmpty {
            allBlocks = tailBlocks
        } else {
            allBlocks = []
            allBlocks.reserveCapacity(committedBlocks.count + tailBlocks.count)
            allBlocks.append(contentsOf: committedBlocks)
            allBlocks.append(contentsOf: tailBlocks)
        }

        if committedHasFootnotes || Self.containsFootnoteDefinition(tailBlocks, parseRawHTML: parseRawHTML) {
            allBlocks = AgentMarkdownFootnotes.prepare(allBlocks, parseRawHTML: parseRawHTML)
        }
        return (allBlocks, references, completedTail)
    }

    private func matchesCommittedPrefix(_ source: String) -> Bool {
        guard committedUTF8Count > 0 else { return true }
        guard source.utf8.count >= committedUTF8Count, lastSource.utf8.count >= committedUTF8Count else { return false }
        return source.utf8.prefix(committedUTF8Count).elementsEqual(lastSource.utf8.prefix(committedUTF8Count))
    }

    private static func containsFootnoteDefinition(_ blocks: [AgentMarkdown.Block], parseRawHTML: Bool) -> Bool {
        for block in blocks {
            switch block {
            case .footnoteDefinition:
                return true
            case .quote(let source), .listBlock(_, let source, _, _), .details(_, let source, _):
                if containsFootnoteDefinition(AgentResponseParser.parse(source, parseRawHTML: parseRawHTML), parseRawHTML: parseRawHTML) {
                    return true
                }
            default:
                break
            }
        }
        return false
    }
}
