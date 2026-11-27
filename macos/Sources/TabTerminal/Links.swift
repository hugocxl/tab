import Foundation
import TabProtocol

/// Longest OSC 8 URI kept; longer links are ignored.
public let maxHyperlinkURI = 2048
/// Most OSC 8 spans kept for one screen.
public let maxHyperlinkSpans = 1024

/// Cells `start..<end` of a row carry an OSC 8 hyperlink.
public struct HyperlinkSpan: Hashable, Sendable {
    public var start: UInt16
    public var end: UInt16
    public var uri: String

    public init(start: UInt16, end: UInt16, uri: String) {
        self.start = start
        self.end = end
        self.uri = uri
    }
}

/// The hyperlinks of one screen row.
public struct HyperlinkRow: Hashable, Sendable {
    public var row: UInt16
    public var spans: [HyperlinkSpan]

    public init(row: UInt16, spans: [HyperlinkSpan]) {
        self.row = row
        self.spans = spans
    }
}

/// A link found in a row: an OSC 8 hyperlink, a URL, or a file path
/// (optionally with `:line:column`), with the cells it covers.
public struct LinkCandidate: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case hyperlink
        case url
        case path
    }

    public var columns: Range<UInt16>
    public var text: String
    public var kind: Kind

    public init(columns: Range<UInt16>, text: String, kind: Kind) {
        self.columns = columns
        self.text = text
        self.kind = kind
    }
}

/// Finds URLs and file paths in the text of a row of runs.
public enum LinkDetector {
    private static let urlPrefixes = ["https://", "http://", "file://"]

    /// The link under `column`, preferring an explicit OSC 8 hyperlink.
    public static func candidate(in runs: [Run], at column: UInt16, hyperlinks: [HyperlinkSpan] = []) -> LinkCandidate? {
        if let span = hyperlinks.first(where: { $0.start <= column && column < $0.end }) {
            return LinkCandidate(columns: span.start..<span.end, text: span.uri, kind: .hyperlink)
        }
        return candidates(in: runs, includePlainWords: true).first { $0.columns.contains(column) }
    }

    /// Every URL and path-like word in the row, left to right.
    public static func candidates(in runs: [Run]) -> [LinkCandidate] {
        candidates(in: runs, includePlainWords: false)
    }

    private static func candidates(in runs: [Run], includePlainWords: Bool) -> [LinkCandidate] {
        guard let text = RowText(runs) else { return [] }
        let scalars = text.scalars
        var found: [LinkCandidate] = []
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
            while end < scalars.count,
                  quoted ? scalars[end] != character : !scalars[end].properties.isWhitespace {
                end += 1
            }
            if let candidate = word(scalars, body..<end, text: text, includePlainWords: includePlainWords) {
                found.append(candidate)
            }
            start = end + (quoted && end < scalars.count ? 1 : 0)
        }
        return found
    }

    private static func word(
        _ scalars: [Unicode.Scalar], _ range: Range<Int>, text: RowText, includePlainWords: Bool
    ) -> LinkCandidate? {
        let raw = String(String.UnicodeScalarView(scalars[range]))
        let leading = raw.unicodeScalars.prefix { "([<\"'".unicodeScalars.contains($0) }.count
        var value = trim(raw)
        var offset = range.lowerBound + leading
        let urlStart = urlPrefixes.compactMap { value.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        if let urlStart {
            offset += value.unicodeScalars[..<urlStart.lowerBound].count
            value = String(value[urlStart.lowerBound...])
        }
        guard !value.isEmpty, value.utf8.count <= maxHyperlinkURI else { return nil }
        let kind: LinkCandidate.Kind = urlStart != nil ? .url : .path
        guard kind == .url || includePlainWords || looksLikePath(value) else { return nil }
        let end = offset + value.unicodeScalars.count
        guard let columns = text.columns(offset..<end) else { return nil }
        return LinkCandidate(columns: columns, text: value, kind: kind)
    }

    private static func looksLikePath(_ value: String) -> Bool {
        if value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("./") || value.hasPrefix("../") {
            return true
        }
        let path = value.split(separator: ":", maxSplits: 1).first.map(String.init) ?? value
        guard let dot = path.lastIndex(of: "."), dot != path.startIndex else { return false }
        let ext = path[path.index(after: dot)...]
        return (path.contains("/") || value.contains(":"))
            && !ext.isEmpty && ext.count <= 8 && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Strips surrounding punctuation, keeping closing brackets that balance.
    static func trim(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars.drop { "([<\"'".unicodeScalars.contains($0) }
        while let last = scalars.last, ".,;!\"'>".unicodeScalars.contains(last) {
            scalars = scalars.dropLast()
        }
        while let last = scalars.last {
            let open: Unicode.Scalar = switch last {
            case ")": "("
            case "]": "["
            case "}": "{"
            default: " "
            }
            guard open != " " else { break }
            let closes = scalars.filter { $0 == last }.count
            let opens = scalars.filter { $0 == open }.count
            guard closes > opens else { break }
            scalars = scalars.dropLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// The text of a row with the cell columns of each scalar.
private struct RowText {
    var scalars: [Unicode.Scalar] = []
    var cells: [Range<UInt16>] = []

    init?(_ runs: [Run]) {
        var column: UInt16 = 0
        for run in runs {
            let ascii = run.text.utf8.count == Int(run.width) && run.text.utf8.allSatisfy { $0 < 0x80 }
            for scalar in run.text.unicodeScalars {
                scalars.append(scalar)
                if ascii {
                    cells.append(column..<column + 1)
                    column += 1
                } else {
                    cells.append(column..<column + run.width)
                }
            }
            if !ascii {
                column += run.width
            }
            guard scalars.count <= 65536 else { return nil }
        }
    }

    func columns(_ range: Range<Int>) -> Range<UInt16>? {
        guard range.lowerBound < range.upperBound, range.upperBound <= cells.count else { return nil }
        return cells[range.lowerBound].lowerBound..<cells[range.upperBound - 1].upperBound
    }
}
