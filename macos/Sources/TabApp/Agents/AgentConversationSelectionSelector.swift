import Foundation
import TabProtocol

/// Conversation selectors normalize whitespace for stable anchors while retaining the exact
/// selected quotation. NSString keeps offsets compatible with browser UTF-16 ranges.
enum AgentConversationSelectionSelector {
    static func citation(in source: String, range: NSRange, environmentId: String, threadId: String, messageId: String) -> AgentAssistantCitation? {
        let text = source as NSString
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        let quote = text.substring(with: range)
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let normalized = normalize(source) as NSString
        var start = (normalize(text.substring(to: range.location)) as NSString).length
        if range.location > 0, isWhitespace(text.character(at: range.location - 1)), isWhitespace(text.character(at: range.location)) { start -= 1 }
        let end = (normalize(text.substring(to: NSMaxRange(range))) as NSString).length
        var prefixStart = max(0, start - AgentAssistantCitation.contextLength)
        var suffixEnd = min(normalized.length, end + AgentAssistantCitation.contextLength)
        if splitsPair(normalized, at: prefixStart) { prefixStart += 1 }
        if splitsPair(normalized, at: suffixEnd) { suffixEnd -= 1 }
        return AgentAssistantCitation(environmentId: environmentId, threadId: threadId, messageId: messageId,
            text: quote, start: start, end: end,
            prefix: normalized.substring(with: NSRange(location: prefixStart, length: start - prefixStart)),
            suffix: normalized.substring(with: NSRange(location: end, length: suffixEnd - end)))
    }

    static func find(_ citation: AgentAssistantCitation, in source: String) -> NSRange? {
        let normalized = normalize(source) as NSString
        let quote = normalize(citation.text) as NSString
        guard quote.length > 0, !(quote as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let prefix = normalize(citation.prefix), suffix = normalize(citation.suffix)
        func matches(_ range: NSRange) -> Bool {
            let before = max(0, range.location - (prefix as NSString).length)
            let after = min(normalized.length, NSMaxRange(range) + (suffix as NSString).length)
            return normalized.substring(with: NSRange(location: before, length: range.location - before)) == prefix &&
                normalized.substring(with: NSRange(location: NSMaxRange(range), length: after - NSMaxRange(range))) == suffix
        }
        var contextual: NSRange?, only: NSRange?, count = 0, offset = 0
        while offset <= normalized.length - quote.length {
            let range = normalized.range(of: quote as String, options: [], range: NSRange(location: offset, length: normalized.length - offset))
            if range.location == NSNotFound { break }
            count += 1; only = range
            if matches(range) {
                if contextual != nil { return nil }
                contextual = range
            }
            offset = range.location + 1
        }
        return contextual ?? (count == 1 ? only : nil)
    }

    /// `find` reports a range of the whitespace-normalized text; this maps it back to `source`.
    /// A collapsed whitespace run maps to the whole run.
    static func sourceRange(ofNormalized range: NSRange, in source: String) -> NSRange? {
        let text = source as NSString
        var normalized = 0, index = 0, start: Int?, end: Int?
        while index < text.length {
            var next = index + 1
            if isWhitespace(text.character(at: index)) {
                while next < text.length, isWhitespace(text.character(at: next)) { next += 1 }
            }
            if normalized == range.location { start = index }
            normalized += 1
            if normalized == NSMaxRange(range) { end = next; break }
            index = next
        }
        guard let start, let end, end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Like `find`, in `source` offsets rather than normalized ones.
    static func findInSource(_ citation: AgentAssistantCitation, in source: String) -> NSRange? {
        find(citation, in: source).flatMap { sourceRange(ofNormalized: $0, in: source) }
    }

    static func normalize(_ source: String) -> String {
        var result = String.UnicodeScalarView(), previousWhitespace = false
        for scalar in source.unicodeScalars {
            let whitespace = scalar.value <= UInt32(UInt16.max) && isWhitespace(UInt16(scalar.value))
            if whitespace {
                if !previousWhitespace { result.append(" ") }
            } else { result.append(scalar) }
            previousWhitespace = whitespace
        }
        return String(result)
    }

    private static func splitsPair(_ text: NSString, at index: Int) -> Bool {
        guard index > 0, index < text.length else { return false }
        return (0xD800...0xDBFF).contains(text.character(at: index - 1)) && (0xDC00...0xDFFF).contains(text.character(at: index))
    }
    private static func isWhitespace(_ value: UInt16) -> Bool {
        switch value {
        case 0x9...0xD, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }
}
