import Foundation
import TabProtocol

/// A link under the pointer: an OSC 8 hyperlink, a URL, or a path-like
/// word, with the cells it covers.
public struct TerminalLinkCandidate: Hashable, Sendable {
    /// Screen-relative row, negative in history.
    public var row: Int
    public var columns: Range<UInt16>
    public var text: String

    public init(row: Int, columns: Range<UInt16>, text: String) {
        self.row = row
        self.columns = columns
        self.text = text
    }
}

/// What a link opens.
public enum TerminalLinkTarget: Hashable, Sendable {
    case url(URL)
    /// An absolute path on the terminal's computer, with an optional
    /// `:line:column`.
    case file(path: String, line: Int?, column: Int?)
}

/// Finds links in a row's text, the way Codesh does: whitespace-separated
/// words (or quoted strings), surrounding punctuation trimmed, URLs found
/// inside words.
public enum TerminalLinkDetector {
    static let urlPrefixes = ["https://", "http://", "file://"]

    public static func detect(runs: [Run], row: Int, column: UInt16, links: [LinkSpan] = []) -> TerminalLinkCandidate? {
        if let span = links.first(where: { $0.start <= column && column < $0.end }) {
            return TerminalLinkCandidate(row: row, columns: span.start..<span.end, text: span.uri)
        }
        var scalars: [Unicode.Scalar] = []
        var cells: [Range<UInt16>] = []
        for cell in TerminalCells.cells(runs) {
            for scalar in cell.text.unicodeScalars {
                scalars.append(scalar)
                cells.append(cell.columns)
            }
            guard scalars.count <= 65536 else { return nil }
        }
        guard let target = cells.firstIndex(where: { $0.contains(column) }) else { return nil }
        var start = 0
        while start < scalars.count {
            let character = scalars[start]
            if character.properties.isWhitespace {
                start += 1
                continue
            }
            let quoted = character == "'" || character == "\""
            let body = start + (quoted ? 1 : 0)
            var end = body
            while end < scalars.count, quoted ? scalars[end] != character : !scalars[end].properties.isWhitespace {
                end += 1
            }
            let raw = String(String.UnicodeScalarView(scalars[body..<end]))
            let leading = raw.unicodeScalars.prefix { "([<\"'".unicodeScalars.contains($0) }.count
            var value = trim(raw)
            var offset = body + leading
            if let prefix = urlPrefixes.compactMap({ value.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                offset += value.unicodeScalars[..<prefix.lowerBound].count
                value = String(value[prefix.lowerBound...])
            }
            let finish = offset + value.unicodeScalars.count
            if offset <= target, target < finish, !value.isEmpty, value.utf8.count <= Limits.maxLinkURI {
                return TerminalLinkCandidate(row: row, columns: cells[offset].lowerBound..<cells[finish - 1].upperBound,
                                             text: value)
            }
            start = end + (quoted && end < scalars.count ? 1 : 0)
        }
        return nil
    }

    /// Strips surrounding punctuation, keeping closing brackets that balance.
    static func trim(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars.drop { "([<\"'".unicodeScalars.contains($0) }
        while let last = scalars.last, ".,;!\"'>".unicodeScalars.contains(last) {
            scalars = scalars.dropLast()
        }
        while let last = scalars.last {
            let open: Unicode.Scalar
            switch last {
            case ")": open = "("
            case "]": open = "["
            case "}": open = "{"
            default: return String(String.UnicodeScalarView(scalars))
            }
            guard scalars.filter({ $0 == last }).count > scalars.filter({ $0 == open }).count else { break }
            scalars = scalars.dropLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// What a candidate opens. Web and file URLs always resolve; paths are
    /// made absolute against `directory` (the terminal's folder) and `home`,
    /// and, when `exists` is given, must exist.
    public static func target(for text: String, directory: String?, home: String? = NSHomeDirectory(),
                              exists: ((String) -> Bool)? = nil) -> TerminalLinkTarget? {
        let lowered = text.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return URL(string: text).map(TerminalLinkTarget.url)
        }
        if lowered.hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { return nil }
            let (path, line, column) = location(url.path)
            return .file(path: path, line: line, column: column)
        }
        let (raw, line, column) = location(text)
        guard !raw.isEmpty else { return nil }
        var path = raw
        if path == "~" || path.hasPrefix("~/") {
            guard let home else { return nil }
            path = home + path.dropFirst()
        } else if !path.hasPrefix("/") {
            guard let directory, !directory.isEmpty else { return nil }
            path = (directory.hasSuffix("/") ? directory : directory + "/") + path
        }
        path = (path as NSString).standardizingPath
        if let exists, !exists(path) { return nil }
        return .file(path: path, line: line, column: column)
    }

    /// Splits `path:line:column`, `path:line`, or `path(line,column)`.
    static func location(_ text: String) -> (String, Int?, Int?) {
        var path = Substring(text)
        if path.hasSuffix(")"), let open = path.lastIndex(of: "(") {
            let inside = path[path.index(after: open)..<path.index(before: path.endIndex)].split(separator: ",")
            if (1...2).contains(inside.count), let line = Int(inside[0].trimmingCharacters(in: .whitespaces)) {
                let column = inside.count == 2 ? Int(inside[1].trimmingCharacters(in: .whitespaces)) : nil
                return (String(path[..<open]), line, column)
            }
        }
        if path.hasSuffix(":") { path = path.dropLast() }
        var numbers: [Int] = []
        while numbers.count < 2, let colon = path.lastIndex(of: ":"),
              let number = Int(path[path.index(after: colon)...]), number > 0 {
            numbers.insert(number, at: 0)
            path = path[..<colon]
        }
        return (String(path), numbers.first, numbers.count > 1 ? numbers[1] : nil)
    }
}
