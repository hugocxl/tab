import Foundation

struct AgentMarkdownFootnote: Equatable {
    let id: String
    let number: Int
    let blocks: [AgentMarkdown.Block]
}

@MainActor
enum AgentMarkdownFootnotes {
    static func definition(in lines: [String], at index: Int, source: AgentMarkdownSource? = nil) -> (label: String, body: String, count: Int)? {
        guard lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[^"),
              let expression = try? NSRegularExpression(pattern: #"^ {0,3}\[\^([^\]\s]+)\]:[ \t]*(.*)$"#),
              let match = expression.firstMatch(in: lines[index], range: NSRange(lines[index].startIndex..., in: lines[index])),
              let labelRange = Range(match.range(at: 1), in: lines[index]),
              let bodyRange = Range(match.range(at: 2), in: lines[index]) else { return nil }
        var body = [String(lines[index][bodyRange])]
        var end = index + 1
        while end < lines.count {
            let line = lines[end]
            if line.hasPrefix("    ") { body.append(String(line.dropFirst(4))); end += 1 }
            else if line.hasPrefix("\t") { body.append(String(line.dropFirst())); end += 1 }
            else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                var next = end + 1
                while next < lines.count && lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                guard next < lines.count, lines[next].hasPrefix("    ") || lines[next].hasPrefix("\t") else { break }
                body += Array(repeating: "", count: next - end)
                end = next
            } else { break }
        }
        return (AgentMarkdownReferences.label(String(lines[index][labelRange])),
                source?.join(body, startingAt: index) ?? body.joined(separator: "\n"), end - index)
    }

    static func link(target: String, anchor: String? = nil, back: Bool = false) -> String {
        var url = URLComponents()
        url.scheme = "tab-agent-footnote"
        url.host = back ? "back" : "reference"
        url.queryItems = [URLQueryItem(name: "target", value: target)]
        if let anchor { url.queryItems?.append(URLQueryItem(name: "anchor", value: anchor)) }
        return url.string ?? ""
    }

    static func prepare(_ blocks: [AgentMarkdown.Block], parseRawHTML: Bool) -> [AgentMarkdown.Block] {
        var definitions: [String: String] = [:]
        func collect(_ blocks: [AgentMarkdown.Block]) {
            for block in blocks {
                switch block {
                case .footnoteDefinition(let label, let body):
                    if definitions[label] == nil { definitions[label] = body }
                case .quote(let source), .listBlock(_, let source, _, _), .details(_, let source, _):
                    collect(AgentResponseParser.parse(source, parseRawHTML: parseRawHTML))
                default: break
                }
            }
        }
        collect(blocks)
        guard !definitions.isEmpty else { return blocks }
        var order: [String] = []
        var occurrences: [String: Int] = [:]
        func inline(_ source: String) -> String {
            rewrite(source) { label in
                guard definitions[label] != nil else { return nil }
                if occurrences[label] == nil { order.append(label) }
                let occurrence = (occurrences[label] ?? 0) + 1
                occurrences[label] = occurrence
                let number = (order.firstIndex(of: label) ?? 0) + 1
                let anchor = "fnref-" + label + (occurrence > 1 ? "-\(occurrence)" : "")
                return "[\(number)](<" + link(target: "fn-" + label, anchor: anchor) + ">)"
            }
        }
        func transform(_ blocks: [AgentMarkdown.Block]) -> [AgentMarkdown.Block] {
            blocks.compactMap { block in
                switch block {
                case .footnoteDefinition: return nil
                case .paragraph(let text): return .paragraph(inline(text))
                case .heading(let level, let text): return .heading(level, inline(text))
                case .list(let marker, let text, let depth, let structure): return .list(marker, inline(text), depth, structure: structure)
                case .table(let headers, let rows, let alignments): return .table(headers.map(inline), rows.map { $0.map(inline) }, alignments)
                case .quote(let source):
                    let parts = AgentResponsePart.partition([.quote(source)])
                    guard case .container(let kind, let body) = parts.first else { return block }
                    return .nested(kind, transform(AgentResponseParser.parse(body, parseRawHTML: parseRawHTML)))
                case .listBlock(let marker, let source, let depth, let structure):
                    let ancestors = (structure?.ancestors ?? []) + [structure?.start != nil]
                    return .nested(.list(marker, depth, structure: structure), transform(AgentResponseParser.parse(source, parseRawHTML: parseRawHTML, listAncestors: ancestors)))
                case .details(let title, let source, let open):
                    return .nested(.details(title, open), transform(AgentResponseParser.parse(source, parseRawHTML: parseRawHTML)))
                default: return block
                }
            }
        }
        var result = transform(blocks)
        var bodies: [[AgentMarkdown.Block]] = []
        var index = 0
        while index < order.count {
            bodies.append(transform(AgentResponseParser.parse(definitions[order[index]] ?? "", parseRawHTML: parseRawHTML)))
            index += 1
        }
        let notes: [AgentMarkdownFootnote] = order.enumerated().map { index, label in
            let backrefs = (1...(occurrences[label] ?? 1)).map { occurrence in
                let target = "fnref-" + label + (occurrence > 1 ? "-\(occurrence)" : "")
                return "[↩" + (occurrence > 1 ? "\(occurrence)" : "") + "](<" + link(target: target, back: true) + ">)"
            }.joined(separator: " ")
            var body = bodies[index]
            if case .paragraph(let text) = body.last { body[body.count - 1] = .paragraph(text + " " + backrefs) }
            else { body.append(.paragraph(backrefs)) }
            return AgentMarkdownFootnote(id: "fn-" + label, number: index + 1, blocks: body)
        }
        if !notes.isEmpty { result.append(.footnotes(notes)) }
        return result
    }

    /// Keep escapes, inline code, and existing link destinations literal.
    static func rewrite(_ source: String, reference: (String) -> String?) -> String {
        let chars = Array(source)
        var i = 0
        var output = ""
        while i < chars.count {
            let start = i
            if chars[i] == "\\" { i = min(chars.count, i + 2); output += String(chars[start..<i]); continue }
            if chars[i] == "`" {
                while i < chars.count && chars[i] == "`" { i += 1 }
                let count = i - start
                var cursor = i
                while cursor < chars.count {
                    if chars[cursor] != "`" { cursor += 1; continue }
                    let run = cursor
                    while cursor < chars.count && chars[cursor] == "`" { cursor += 1 }
                    if cursor - run == count { i = cursor; break }
                }
                output += String(chars[start..<i]); continue
            }
            if chars[i] == "[", i + 2 < chars.count, chars[i + 1] == "^",
               let close = chars[(i + 2)...].firstIndex(of: "]") {
                let raw = String(chars[(i + 2)..<close])
                if !raw.isEmpty, !raw.contains(where: { $0.isWhitespace }), let value = reference(AgentMarkdownReferences.label(raw)) {
                    output += value; i = close + 1; continue
                }
            }
            if chars[i] == "]", i + 1 < chars.count, chars[i + 1] == "(" {
                i += 2
                var depth = 1
                while i < chars.count && depth > 0 {
                    if chars[i] == "\\" { i = min(chars.count, i + 2); continue }
                    if chars[i] == "(" { depth += 1 }
                    if chars[i] == ")" { depth -= 1 }
                    i += 1
                }
                output += String(chars[start..<i]); continue
            }
            output.append(chars[i]); i += 1
        }
        return output
    }
}
