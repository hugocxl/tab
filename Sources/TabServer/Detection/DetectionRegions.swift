// Adapted from herdr (Apache-2.0); see Resources/Detection/THIRD_PARTY.md.
import Foundation

/// The screen, title and progress a rule's region is cut from.
struct DetectionText {
    var screen: String
    var title: String
    var progress: String
}

/// Lines of a text split like Rust's `str::lines`: on `\n`, without a final
/// empty line, a trailing `\r` dropped from each line's text.
struct ScreenLines {
    let content: Substring
    /// Each line's text, without its terminator.
    let lines: [Substring]
    /// Where each line starts in `content`.
    let starts: [String.Index]

    init(_ content: Substring) {
        self.content = content
        var lines: [Substring] = []
        var starts: [String.Index] = []
        var start = content.startIndex
        let utf8 = content.utf8
        var index = utf8.startIndex
        while index < utf8.endIndex {
            if utf8[index] == UInt8(ascii: "\n") {
                starts.append(start)
                lines.append(Self.stripCarriageReturn(content[start ..< index]))
                start = utf8.index(after: index)
            }
            index = utf8.index(after: index)
        }
        if start < content.endIndex {
            starts.append(start)
            lines.append(Self.stripCarriageReturn(content[start...]))
        }
        self.lines = lines
        self.starts = starts
    }

    private static func stripCarriageReturn(_ line: Substring) -> Substring {
        line.utf8.last == UInt8(ascii: "\r") ? line.dropLast() : line
    }

    var count: Int { lines.count }

    /// Where line `index` starts, or the end past the last line.
    func start(of index: Int) -> String.Index {
        index < starts.count ? starts[index] : content.endIndex
    }

    func from(line index: Int) -> Substring { content[start(of: index)...] }
    func before(line index: Int) -> Substring { content[..<start(of: index)] }
}

enum DetectionRegion {
    /// The part of the input a rule's `region` names; empty for unknown names.
    static func text(_ input: DetectionText, spec: String) -> Substring {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "osc_title": return input.title[...]
        case "osc_progress": return input.progress[...]
        default: break
        }
        let content = input.screen[...]
        switch trimmed {
        case "whole_recent": return content
        case "after_last_prompt_marker": return afterLastPromptMarker(content)
        case "before_current_prompt_marker": return beforeCurrentPromptMarker(content)
        case "whole_recent_without_current_prompt_marker":
            return currentCodexPromptIndex(ScreenLines(content)) == nil ? content : content[content.endIndex...]
        case "current_prompt_block_marker": return currentPromptBlockMarker(content) ?? ""
        case "after_current_prompt_block_marker": return afterCurrentPromptBlockMarker(content) ?? ""
        case "prompt_box_body": return promptBoxBody(content) ?? ""
        case "above_prompt_box": return abovePromptBox(content)
        case "last_non_empty_above_prompt_box": return lastNonEmptyLine(abovePromptBox(content))
        case "after_last_horizontal_rule": return afterLastHorizontalRule(content)
        case "last_non_empty_line": return lastNonEmptyLine(content)
        default:
            if let count = regionCount(trimmed, name: "bottom_lines") { return bottomLines(content, count) }
            if let count = regionCount(trimmed, name: "bottom_non_empty_lines") {
                return bottomNonEmptyLines(content, count)
            }
            if let count = topRegionCount(trimmed) { return topNonEmptyLines(content, count) }
            return ""
        }
    }

    /// Whether `spec` names a region this engine knows.
    static func isKnown(_ spec: String) -> Bool {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        let names: Set = [
            "osc_title", "osc_progress", "whole_recent", "after_last_prompt_marker", "before_current_prompt_marker",
            "whole_recent_without_current_prompt_marker", "current_prompt_block_marker",
            "after_current_prompt_block_marker", "prompt_box_body", "above_prompt_box",
            "last_non_empty_above_prompt_box", "after_last_horizontal_rule", "last_non_empty_line",
        ]
        return names.contains(trimmed) || regionCount(trimmed, name: "bottom_lines") != nil
            || regionCount(trimmed, name: "bottom_non_empty_lines") != nil || topRegionCount(trimmed) != nil
    }

    static func regionCount(_ spec: String, name: String) -> Int? {
        guard spec.hasPrefix(name + "("), spec.hasSuffix(")") else { return nil }
        let count = spec.dropFirst(name.count + 1).dropLast()
        guard !count.isEmpty, count.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(count)
    }

    static let maxTopRegionLineCount = Int(UInt16.max)

    static func topRegionCount(_ spec: String) -> Int? {
        guard spec.hasPrefix("top_non_empty_lines("), spec.hasSuffix(")") else { return nil }
        let count = spec.dropFirst("top_non_empty_lines(".count).dropLast()
        guard !count.isEmpty, !count.hasPrefix("0"), count.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let value = Int(count), value <= maxTopRegionLineCount else { return nil }
        return value
    }

    static func isBlank<S: StringProtocol>(_ line: S) -> Bool {
        line.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }

    static func bottomLines(_ content: Substring, _ count: Int) -> Substring {
        let lines = ScreenLines(content)
        return lines.from(line: max(0, lines.count - count))
    }

    static func bottomNonEmptyLines(_ content: Substring, _ count: Int) -> Substring {
        let lines = ScreenLines(content)
        guard count > 0 else { return content[content.endIndex...] }
        var taken = 0
        var startIndex: Int?
        for index in stride(from: lines.count - 1, through: 0, by: -1) where !isBlank(lines.lines[index]) {
            startIndex = index
            taken += 1
            if taken == count { break }
        }
        guard let startIndex else { return content[content.endIndex...] }
        return lines.from(line: startIndex)
    }

    static func topNonEmptyLines(_ content: Substring, _ count: Int) -> Substring {
        let lines = ScreenLines(content)
        var taken = 0
        var endIndex: Int?
        for index in 0 ..< lines.count where !isBlank(lines.lines[index]) {
            endIndex = index
            taken += 1
            if taken == count { break }
        }
        guard let endIndex else { return content[content.endIndex...] }
        return lines.before(line: endIndex + 1)
    }

    static func afterLastPromptMarker(_ content: Substring) -> Substring {
        let lines = ScreenLines(content)
        guard let index = lines.lines.lastIndex(where: isCodexPromptLine) else { return content }
        return lines.from(line: index + 1)
    }

    static func beforeCurrentPromptMarker(_ content: Substring) -> Substring {
        let lines = ScreenLines(content)
        guard let index = currentCodexPromptIndex(lines) else { return content }
        return lines.before(line: index)
    }

    static func currentPromptBlockMarker(_ content: Substring) -> Substring? {
        let lines = ScreenLines(content)
        guard let prompt = currentCodexPromptIndex(lines) else { return nil }
        return lines.lines[..<prompt].last(where: isCodexBlockMarkerLine)
    }

    static func afterCurrentPromptBlockMarker(_ content: Substring) -> Substring? {
        let lines = ScreenLines(content)
        guard let prompt = currentCodexPromptIndex(lines),
              let block = lines.lines[..<prompt].lastIndex(where: isCodexBlockMarkerLine) else { return nil }
        return lines.from(line: block)
    }

    static func currentCodexPromptIndex(_ lines: ScreenLines) -> Int? {
        guard let prompt = lines.lines.lastIndex(where: isCodexPromptLine) else { return nil }
        if lines.lines[(prompt + 1)...].contains(where: isCodexBlockMarkerLine) { return nil }
        return prompt
    }

    static func isCodexPromptLine(_ line: Substring) -> Bool {
        line == "›" || line.utf8.starts(with: "› ".utf8)
    }

    static func isCodexBlockMarkerLine(_ line: Substring) -> Bool {
        guard let first = line.unicodeScalars.first else { return false }
        return first == "•" || first == "■" || first == "✗" || first == "✓"
    }

    static func promptBoxBody(_ content: Substring) -> Substring? {
        let lines = ScreenLines(content)
        guard let top = promptBoxTopBorderIndex(lines) else { return nil }
        let endIndex = lines.lines[(top + 1)...].firstIndex(where: isHorizontalRule) ?? lines.count
        return content[lines.start(of: top + 1) ..< lines.start(of: endIndex)]
    }

    static func abovePromptBox(_ content: Substring) -> Substring {
        let lines = ScreenLines(content)
        guard let top = promptBoxTopBorderIndex(lines) else { return content }
        return lines.before(line: top)
    }

    static func afterLastHorizontalRule(_ content: Substring) -> Substring {
        let lines = ScreenLines(content)
        guard let rule = lines.lines.lastIndex(where: isHorizontalRule) else { return content }
        return lines.from(line: rule + 1)
    }

    static func lastNonEmptyLine(_ content: Substring) -> Substring {
        ScreenLines(content).lines.last { !isBlank($0) } ?? content[content.endIndex...]
    }

    static func promptBoxTopBorderIndex(_ lines: ScreenLines) -> Int? {
        var borders = 0
        for index in stride(from: lines.count - 1, through: 0, by: -1) where isHorizontalRule(lines.lines[index]) {
            borders += 1
            if borders == 2 { return index }
        }
        return nil
    }

    static func isHorizontalRule(_ line: Substring) -> Bool {
        let scalars = line.unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }) else { return false }
        var index = first
        var rule = 0
        while index < scalars.endIndex, scalars[index] == "─" {
            rule += 1
            index = scalars.index(after: index)
        }
        guard rule > 0 else { return false }
        let suffixIsBlank = scalars[index...].allSatisfy { $0.properties.isWhitespace }
        return suffixIsBlank || rule >= 3
    }
}
