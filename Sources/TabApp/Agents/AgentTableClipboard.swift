import Foundation

enum AgentTableClipboard {
    private struct InlineRun {
        var text: String
        var marks: [String]
        var serialized: String?
        var linkIdentity: String?
    }

    /// Serialize the inline parse, before CSS whitespace collapsing. Browser copying uses
    /// DOM text nodes: code spaces and entities therefore differ from visible innerText.
    @MainActor
    static func markdownCell(_ source: String, references: [String: String]) -> String {
        let resolved = AgentMarkdownSource.inlineSource(AgentMarkdownWhitespace.prepare(AgentMarkdownReferences.resolve(source, definitions: references)))
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.appliesSourcePositionAttributes = true
        let labels = AgentMarkdownSource.InlineLabels(resolved)
        guard let parsed = try? AttributedString(markdown: resolved, options: options) else { return escapePipes(source) }
        let runs = parsed.runs.map { run -> InlineRun in
            let intent = run.inlinePresentationIntent ?? []
            var marks: [String] = []
            if let link = run.link { marks.append("link:" + link.absoluteString) }
            if intent.contains(.stronglyEmphasized) { marks.append("**") }
            if intent.contains(.emphasized) { marks.append("*") }
            if intent.contains(.strikethrough) { marks.append("~~") }
            if intent.contains(.code) { marks.append("`") }
            var serialized: String?
            if run.link != nil, let position = run.markdownSourcePosition,
               let label = labels.label(at: position), label != resolved {
                serialized = markdownCell(label, references: [:])
            }
            return InlineRun(text: String(parsed[run.range].characters), marks: marks, serialized: serialized, linkIdentity: run.link == nil ? nil : run.markdownSourcePosition.map { labels.identity(at: $0) })
        }
        func serialize(_ range: Range<Int>, excluding: Set<String>) -> String {
            var output = "", index = range.lowerBound
            while index < range.upperBound {
                var chosen: String?, end = index
                for mark in runs[index].marks where !excluding.contains(mark) {
                    var candidate = index + 1
                    while candidate < range.upperBound, runs[candidate].marks.contains(mark) {
                        if mark.hasPrefix("link:"), runs[candidate].linkIdentity != runs[index].linkIdentity { break }
                        candidate += 1
                    }
                    if candidate > end { chosen = mark; end = candidate }
                }
                guard let mark = chosen else {
                    output += runs[index].serialized ?? escapePipes(runs[index].text)
                    index += 1
                    continue
                }
                let content = serialize(index..<end, excluding: excluding.union([mark]))
                if mark == "`" {
                    var longest = 0, current = 0
                    for character in content {
                        current = character == "`" ? current + 1 : 0
                        longest = max(longest, current)
                    }
                    let fence = String(repeating: "`", count: max(1, longest + 1))
                    let padding = content.hasPrefix("`") || content.hasSuffix("`") ? " " : ""
                    output += fence + padding + content + padding + fence
                } else if mark.hasPrefix("link:") {
                    let href = escapePipes(String(mark.dropFirst(5)))
                    let label = trimWhitespace(content)
                    if href.lowercased().hasPrefix("https://") || href.lowercased().hasPrefix("http://") {
                        output += label.isEmpty ? "" : label == href ? href : "[" + label + "](" + href + ")"
                    } else { output += content }
                } else {
                    let core = trimWhitespace(content)
                    if core.isEmpty { output += content }
                    else if let coreRange = content.range(of: core) {
                        output += content[..<coreRange.lowerBound] + mark + core + mark + content[coreRange.upperBound...]
                    }
                }
                index = end
            }
            return output
        }
        let result = serialize(runs.indices, excluding: [])
        return trimWhitespace(result.replacingOccurrences(of: "\n+", with: " ", options: .regularExpression))
    }

    private static func escapePipes(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }

    private static func trimWhitespace(_ text: String) -> String {
        let scalars = text.unicodeScalars
        let start = scalars.firstIndex { !isWhitespace($0) } ?? scalars.endIndex
        let end = scalars.lastIndex { !isWhitespace($0) }.map { scalars.index(after: $0) } ?? start
        return String(scalars[start..<end])
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9...0xD, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }

    /// Export rendered cells, including padded empty cells but excluding surplus source columns.
    static func csv(cells: [String], columns: Int) -> String {
        guard columns > 0 else { return "" }
        return stride(from: 0, to: cells.count, by: columns).map { start in
            cells[start..<min(start + columns, cells.count)].map { cell in
                let value = normalizedWhitespace(cell)
                guard value.contains(",") || value.contains("\"") else { return value }
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    private static func normalizedWhitespace(_ source: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in source.unicodeScalars {
            // JavaScript's /\s+/ and trim(), as used by the source renderer's rendered-table serializer.
            // Foundation's whitespace set also contains U+0085, which JavaScript preserves.
            switch scalar.value {
            case 0x9...0xD, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
                pendingSpace = !result.isEmpty
            default:
                if pendingSpace { result.append(" ") }
                result.append(scalar)
                pendingSpace = false
            }
        }
        return String(result)
    }
}
