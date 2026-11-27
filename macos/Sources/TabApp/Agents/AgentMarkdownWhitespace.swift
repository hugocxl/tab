import Foundation

enum AgentMarkdownWhitespace {
    /// Foundation's inline parser recognizes backslash hard breaks, but not the
    /// equivalent two-space form. Convert only literal source spaces outside code.
    static func prepare(_ source: String) -> String {
        guard source.contains("  "), source.contains("\n") || source.contains("\r") || source.contains("\r\n") else { return source }
        let characters = Array(source)
        var ticks: [Int: [(start: Int, end: Int)]] = [:]
        var index = 0
        while index < characters.count {
            if characters[index] == "`" {
                let start = index
                while index < characters.count, characters[index] == "`" { index += 1 }
                ticks[index - start, default: []].append((start, index))
            } else { index += 1 }
        }
        var output = ""
        index = 0
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                output += String(characters[index...index + 1]); index += 2; continue
            }
            if characters[index] == "`" {
                let start = index
                while index < characters.count, characters[index] == "`" { index += 1 }
                let candidates = ticks[index - start] ?? []
                var low = 0, high = candidates.count
                while low < high {
                    let middle = (low + high) / 2
                    if candidates[middle].start < index { low = middle + 1 } else { high = middle }
                }
                if low < candidates.count { index = candidates[low].end }
                output += String(characters[start..<index]); continue
            }
            if characters[index] == "]", index + 1 < characters.count, characters[index + 1] == "(" {
                let start = index
                index += 2
                var depth = 1
                while index < characters.count, depth > 0 {
                    if characters[index] == "\\" { index = min(characters.count, index + 2); continue }
                    if characters[index] == "(" { depth += 1 }
                    if characters[index] == ")" { depth -= 1 }
                    index += 1
                }
                output += String(characters[start..<index]); continue
            }
            if characters[index] == " " {
                let start = index
                while index < characters.count, characters[index] == " " { index += 1 }
                if index - start >= 2, index < characters.count,
                   ["\n", "\r", "\r\n"].contains(characters[index]) {
                    output += "\\\n"; index += 1
                } else { output += String(characters[start..<index]) }
                continue
            }
            output.append(characters[index]); index += 1
        }
        return output
    }

    /// CSS white-space: normal collapses ASCII whitespace across inline boundaries.
    /// Keep nonbreaking/Unicode spaces and explicit Markdown line breaks intact.
    static func collapse(_ source: NSAttributedString, lineBreaks: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var pending: [NSAttributedString.Key: Any]?
        var atLineStart = true
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            let value = (source.string as NSString).substring(with: range)
            if attributes[.agentMarkdownHardBreak] as? Bool == true {
                pending = nil
                result.append(NSAttributedString(string: value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"), attributes: attributes))
                atLineStart = true
                return
            }
            var normalized = ""
            var pendingFromThisRun = false
            for character in value {
                if lineBreaks, attributes[.agentInlineCodeBackground] == nil,
                   character == "\n" || character == "\r" || character == "\r\n" {
                    pending = nil
                    normalized.append("\n")
                    atLineStart = true
                    continue
                }
                if character == " " || character == "\t" || character == "\n" || character == "\r" || character == "\r\n" || character == "\u{c}" {
                    if !atLineStart, pending == nil { pending = attributes; pendingFromThisRun = true }
                    continue
                }
                if let space = pending {
                    if pendingFromThisRun { normalized.append(" ") }
                    else { result.append(NSAttributedString(string: " ", attributes: space)) }
                    pending = nil
                }
                normalized.append(character)
                atLineStart = false
            }
            if !normalized.isEmpty { result.append(NSAttributedString(string: normalized, attributes: attributes)) }

        }
        return result
    }
}

extension NSAttributedString.Key {
    static let agentMarkdownHardBreak = NSAttributedString.Key("TabAgentMarkdownHardBreak")
}
