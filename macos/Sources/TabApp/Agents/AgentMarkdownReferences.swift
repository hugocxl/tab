import Foundation

/// Document definitions are collected before rendering any section, so a definition streamed at
/// the end can resolve earlier prose, table cells, and nested containers without touching code.
@MainActor
enum AgentMarkdownReferences {
    static func label(_ source: String) -> String {
        source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    static func definition(in lines: [String], at index: Int) -> (label: String, destination: String, count: Int)? {
        guard lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[") else { return nil }
        let pattern = #"^ {0,3}\[([^\]\n]{1,999})\]:[ \t]*(?:\n[ \t]*)?(<[^<>\n]*>|(?:\\.|[^ \t\n])+)(?:(?:[ \t]+|\n[ \t]+)(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?[ \t]*(?:\n|$)"#
        let candidate = lines[index..<min(lines.count, index + 3)].joined(separator: "\n")
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
              let full = Range(match.range, in: candidate), let name = Range(match.range(at: 1), in: candidate) else { return nil }
        let definition = String(candidate[full]).trimmingCharacters(in: .newlines)
        let nameValue = String(candidate[name])
        guard !nameValue.hasPrefix("^"), !label(nameValue).isEmpty,
              let parsed = try? AttributedString(markdown: "[reference][\(nameValue)]\n\n" + definition),
              String(parsed.characters) == "reference",
              let destination = parsed.runs.first?.link?.relativeString else { return nil }
        return (label(nameValue), destination, definition.components(separatedBy: "\n").count)
    }

    static func collect(_ blocks: [AgentMarkdown.Block], parseRawHTML: Bool) -> [String: String] {
        var result: [String: String] = [:]
        func visit(_ blocks: [AgentMarkdown.Block]) {
            for block in blocks {
                switch block {
                case .reference(let label, let destination):
                    if result[label] == nil { result[label] = destination }
                case .quote(let source), .listBlock(_, let source, _, _), .details(_, let source, _), .footnoteDefinition(_, let source):
                    visit(AgentResponseParser.parse(source, parseRawHTML: parseRawHTML))
                default: break
                }
            }
        }
        visit(blocks)
        return result
    }

    static func resolve(_ source: String, definitions: [String: String]) -> String {
        guard !definitions.isEmpty, source.contains("[") else { return source }
        let characters = Array(source)
        var output = ""
        var i = 0
        func closingBracket(_ start: Int) -> Int? {
            var depth = 1
            var cursor = start + 1
            while cursor < characters.count {
                if characters[cursor] == "\\" { cursor += 2; continue }
                if characters[cursor] == "[" { depth += 1 }
                if characters[cursor] == "]" { depth -= 1; if depth == 0 { return cursor } }
                cursor += 1
            }
            return nil
        }
        while i < characters.count {
            let start = i
            if characters[i] == "\\" {
                i = min(characters.count, i + 2)
                output += String(characters[start..<i]); continue
            }
            if characters[i] == "`" {
                while i < characters.count && characters[i] == "`" { i += 1 }
                let count = i - start
                var cursor = i
                var end: Int?
                while cursor < characters.count {
                    if characters[cursor] != "`" { cursor += 1; continue }
                    let run = cursor
                    while cursor < characters.count && characters[cursor] == "`" { cursor += 1 }
                    if cursor - run == count { end = cursor; break }
                }
                if let end { i = end }
                output += String(characters[start..<i]); continue
            }
            guard characters[i] == "[", let close = closingBracket(i) else {
                output.append(characters[i]); i += 1; continue
            }
            let text = String(characters[(i + 1)..<close])
            var end = close + 1
            if end < characters.count && characters[end] == "(" {
                // An existing inline link takes precedence; keep its destination untouched.
                var depth = 1
                end += 1
                while end < characters.count && depth > 0 {
                    if characters[end] == "\\" { end = min(characters.count, end + 2); continue }
                    if characters[end] == "(" { depth += 1 }
                    if characters[end] == ")" { depth -= 1 }
                    end += 1
                }
                output += String(characters[i..<end]); i = end; continue
            }
            var key = text
            if end < characters.count && characters[end] == "[", let referenceEnd = closingBracket(end) {
                let explicit = String(characters[(end + 1)..<referenceEnd])
                key = explicit.isEmpty ? text : explicit
                end = referenceEnd + 1
            }
            if let destination = definitions[label(key)] {
                output += "[" + text + "](<" + destination + ">)"
            } else { output += String(characters[i..<end]) }
            i = end
        }
        return output
    }
}
