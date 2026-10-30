import Foundation

/// Native block parsing for the response surface. Open fences and unfinished table rows remain
/// visible during streaming; completed block indices stay stable as the last block grows.
@MainActor
enum AgentResponseParser {
    static func parse(_ source: String) -> [AgentMarkdown.Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [AgentMarkdown.Block] = []
        var paragraph: [String] = []
        var listIndents: [Int] = []
        var i = 0
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph.removeAll(keepingCapacity: true)
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); i += 1; continue }
            if let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix { $0 == first }.count
                if count >= 3 {
                    flush()
                    let info = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
                    var code: [String] = []
                    var closed = false
                    i += 1
                    while i < lines.count {
                        let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                        let closeCount = candidate.prefix { $0 == first }.count
                        if closeCount >= count && candidate.dropFirst(closeCount).trimmingCharacters(in: .whitespaces).isEmpty {
                            closed = true
                            i += 1
                            break
                        }
                        code.append(lines[i])
                        i += 1
                    }
                    var content = code.joined(separator: "\n")
                    if closed && !code.isEmpty { content += "\n" }
                    result.append(.code(info, content))
                    continue
                }
            }
            if i + 1 < lines.count, line.contains("|"), let alignments = tableSeparator(lines[i + 1]) {
                let headers = cells(line)
                if headers.count == alignments.count {
                    flush()
                    var rows: [[String]] = []
                    i += 2
                    while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, lines[i].contains("|") {
                        var row = Array(cells(lines[i]).prefix(headers.count))
                        row += Array(repeating: "", count: max(0, headers.count - row.count))
                        rows.append(row)
                        i += 1
                    }
                    result.append(.table(headers, rows, alignments))
                    continue
                }
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flush()
                var title = String(trimmed.dropFirst(hashes + 1))
                if let closing = title.range(of: #"\s+#+\s*$"#, options: .regularExpression) { title.removeSubrange(closing) }
                result.append(.heading(hashes, title))
            } else if i + 1 < lines.count, let level = setextLevel(lines[i + 1]), list(line) == nil {
                flush()
                result.append(.heading(level, trimmed))
                i += 1
            } else if isRule(trimmed) {
                flush()
                result.append(.divider)
            } else if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix(">") else { break }
                    let stripped = next.dropFirst()
                    quoted.append(String(stripped.first == " " ? stripped.dropFirst() : stripped))
                    i += 1
                }
                result.append(.quote(quoted.joined(separator: "\n")))
                continue
            } else if let entry = list(line) {
                flush()
                while let last = listIndents.last, last > entry.indent { listIndents.removeLast() }
                if listIndents.last != entry.indent { listIndents.append(entry.indent) }
                let depth = max(0, listIndents.count - 1)
                var content = entry.text
                while i + 1 < lines.count, !lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty,
                      indentation(lines[i + 1]) > entry.indent, list(lines[i + 1]) == nil,
                      !lines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    i += 1
                    content += "\n" + lines[i].trimmingCharacters(in: .whitespaces)
                }
                var marker = entry.marker
                if marker == "•" { marker = ["•", "◦", "▪"][min(depth, 2)] }
                if let number = entry.number, depth > 0 {
                    if depth % 3 == 1, (1...26).contains(number), let scalar = UnicodeScalar(96 + number) { marker = String(scalar) + "." }
                    else if depth % 3 == 2, (1...3999).contains(number) { marker = roman(number) + "." }
                }
                if content.hasPrefix("[ ] ") { marker = "☐"; content = String(content.dropFirst(4)) }
                if content.lowercased().hasPrefix("[x] ") { marker = "☑"; content = String(content.dropFirst(4)) }
                result.append(.list(marker, content, depth))
            } else {
                if paragraph.isEmpty { listIndents.removeAll(keepingCapacity: true) }
                paragraph.append(line)
            }
            i += 1
        }
        flush()
        return result
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func list(_ line: String) -> (indent: Int, marker: String, number: Int?, text: String)? {
        let value = line.drop { $0 == " " || $0 == "\t" }
        if let first = value.first, "-*+".contains(first), value.dropFirst().first == " " {
            return (indentation(line), "•", nil, String(value.dropFirst(2)))
        }
        let digits = value.prefix { $0.isNumber }
        let rest = value.dropFirst(digits.count)
        if !digits.isEmpty, digits.count < 10, let delimiter = rest.first, ".)".contains(delimiter), rest.dropFirst().first == " " {
            return (indentation(line), String(digits) + ".", Int(digits), String(rest.dropFirst(2)))
        }
        return nil
    }

    private static func isRule(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        return compact.count >= 3 && ["-", "*", "_"].contains(String(compact.prefix(1))) && Set(compact).count == 1
    }

    private static func setextLevel(_ line: String) -> Int? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3, Set(text).count == 1 else { return nil }
        return text.first == "=" ? 1 : text.first == "-" ? 2 : nil
    }

    static func cells(_ line: String) -> [String] {
        var source = line.trimmingCharacters(in: .whitespaces)
        if source.first == "|" { source.removeFirst() }
        if source.last == "|", !source.hasSuffix("\\|") { source.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var ticks = 0
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if escaped { cell.append(character); escaped = false }
            else if character == "\\" {
                let next = source.index(after: index)
                if next < source.endIndex, source[next] == "|" { escaped = true }
                else { cell.append(character) }
            } else if character == "`" {
                let run = source[index...].prefix { $0 == "`" }.count
                if ticks == 0 { ticks = run } else if ticks == run { ticks = 0 }
                cell += String(repeating: "`", count: run)
                index = source.index(index, offsetBy: run - 1)
            } else if character == "|", ticks == 0 {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else { cell.append(character) }
            index = source.index(after: index)
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func tableSeparator(_ line: String) -> [AgentMarkdown.TableAlignment]? {
        let parts = cells(line)
        guard !parts.isEmpty, parts.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) else { return nil }
        return parts.map { part in
            if part.hasPrefix(":"), part.hasSuffix(":") { return .center }
            return part.hasSuffix(":") ? .right : .left
        }
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
