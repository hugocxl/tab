import Foundation

/// Markdown recognizes CR, LF and CRLF as line endings, but retains their spelling
/// inside text/code nodes. Unicode paragraph separators are ordinary source text.
struct AgentMarkdownSource {
    /// Inline Foundation source positions count UTF-8 bytes in one logical line.
    /// Normalize CRLF first so positions continue to address the parsed source.
    static func inlineSource(_ source: String) -> String {
        source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    struct InlineLabels {
        private let bytes: [UInt8]
        private let ranges: [Range<Int>]

        init(_ source: String) {
            let bytes = Array(source.utf8)
            self.bytes = bytes
            var ticks: [Int: [Int]] = [:]
            var index = 0
            while index < bytes.count {
                if bytes[index] == 96 {
                    let start = index
                    while index < bytes.count, bytes[index] == 96 { index += 1 }
                    ticks[index - start, default: []].append(start)
                } else { index += 1 }
            }
            var stack: [Int] = [], ranges: [Range<Int>] = []
            index = 0
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 96 {
                    let start = index
                    while index < bytes.count, bytes[index] == 96 { index += 1 }
                    let count = index - start, candidates = ticks[count] ?? []
                    var low = 0, high = candidates.count
                    while low < high {
                        let middle = (low + high) / 2
                        if candidates[middle] < index { low = middle + 1 } else { high = middle }
                    }
                    if low < candidates.count { index = candidates[low] + count }
                    continue
                }
                if bytes[index] == 91 { stack.append(index) }
                if bytes[index] == 93, let start = stack.popLast(), index + 1 < bytes.count, bytes[index + 1] == 40 {
                    ranges.append((start + 1)..<index)
                }
                index += 1
            }
            self.ranges = ranges.sorted { $0.lowerBound < $1.lowerBound }
        }

        func label(at position: AttributedString.MarkdownSourcePosition) -> String? {
            guard let range = range(at: position) else { return nil }
            return String(bytes: bytes[range], encoding: .utf8)
        }

        func identity(at position: AttributedString.MarkdownSourcePosition) -> String {
            if let range = range(at: position) { return "label:\(range.lowerBound):\(range.upperBound)" }
            return "source:\(position.startLine):\(position.startColumn):\(position.endLine):\(position.endColumn)"
        }

        private func range(at position: AttributedString.MarkdownSourcePosition) -> Range<Int>? {
            guard position.startLine == 1, position.endLine == 1 else { return nil }
            let start = position.startColumn - 1, end = position.endColumn
            var low = 0, high = ranges.count
            while low < high {
                let middle = (low + high) / 2
                if ranges[middle].lowerBound <= start { low = middle + 1 } else { high = middle }
            }
            guard low > 0, ranges[low - 1].upperBound >= end else { return nil }
            return ranges[low - 1]
        }
    }

    let lines: [String]
    private let endings: [String]

    init(_ source: String) {
        let source = source.replacingOccurrences(of: "\0", with: "\u{FFFD}")
        var lines: [String] = []
        var endings: [String] = []
        var start = source.startIndex
        for index in source.indices {
            let character = source[index]
            guard character == "\n" || character == "\r" || character == "\r\n" else { continue }
            lines.append(String(source[start..<index]))
            endings.append(String(character))
            start = source.index(after: index)
        }
        lines.append(String(source[start...]))
        endings.append("")
        self.lines = lines
        self.endings = endings
    }

    func ending(after index: Int) -> String {
        endings.indices.contains(index) ? endings[index] : "\n"
    }

    func join(_ lines: [String], startingAt start: Int) -> String {
        var result = ""
        for (offset, line) in lines.enumerated() {
            if offset > 0 { result += ending(after: start + offset - 1) }
            result += line
        }
        return result
    }
}
