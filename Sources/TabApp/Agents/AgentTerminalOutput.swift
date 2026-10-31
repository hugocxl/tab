import AppKit

/// Replays provider output into the source renderer's 64-line live window, with a bounded scrollback tail.
/// Provider snapshots contain the complete current output, so incomplete escapes wait for the next snapshot.
@MainActor
final class AgentTerminalOutput {
    private static let limit = 65_536
    private var lines = [NSMutableAttributedString(string: "")]
    private var settled = ""
    private var runEstimates: [ObjectIdentifier: Int] = [:]
    private static let penKey = NSAttributedString.Key("TabAgentTerminalPen")
    private var row = 0, column = 0
    private var saved: (row: Int, column: Int)?
    private var style = AgentTerminalStyle()
    private var dropped = false
    private let palette: TerminalPalette
    private let baseColor: NSColor
    private let fontSize: CGFloat
    private let lineHeight: CGFloat

    init(dark: Bool, baseColor: NSColor, fontSize: CGFloat = 13, lineHeight: CGFloat = 21.125, palette: TerminalPalette? = nil) {
        self.palette = palette ?? TerminalPalette(dark: dark); self.baseColor = baseColor; self.fontSize = fontSize; self.lineHeight = lineHeight
    }

    private func attributes(_ style: AgentTerminalStyle) -> [NSAttributedString.Key: Any] {
        var attributes = style.attributes(palette: palette, baseColor: baseColor, fontSize: fontSize)
        if let background = attributes.removeValue(forKey: .backgroundColor) { attributes[.agentTerminalBackground] = background }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byWordWrapping
        attributes[.paragraphStyle] = paragraph
        let font = attributes[.font] as? NSFont ?? AppFont.mono(fontSize)
        attributes[.baselineOffset] = (lineHeight - floor(font.ascender - font.descender)) / 2
        attributes[Self.penKey] = style.pen
        return attributes
    }

    private func plain(_ text: String) -> NSAttributedString { NSAttributedString(string: text, attributes: attributes(AgentTerminalStyle())) }

    private func trim(_ text: NSMutableAttributedString) -> Int {
        guard text.length > Self.limit else { return 0 }
        var count = text.length - Self.limit
        if (0xdc00...0xdfff).contains((text.string as NSString).character(at: count)) { count += 1 }
        text.deleteCharacters(in: NSRange(location: 0, length: count))
        dropped = true
        return count
    }

    private func write(_ text: String) {
        guard !text.isEmpty else { return }
        let line = lines[row]
        if column > line.length { line.append(plain(String(repeating: " ", count: column - line.length))) }
        let length = (text as NSString).length
        line.replaceCharacters(in: NSRange(location: column, length: min(length, line.length - column)), with: NSAttributedString(string: text, attributes: attributes(style)))
        column += length
        let id = ObjectIdentifier(line)
        runEstimates[id, default: 0] += 2
        if runEstimates[id, default: 0] > 2048 {
            var ranges: [NSRange] = []
            line.enumerateAttribute(Self.penKey, in: NSRange(location: 0, length: line.length)) { _, range, _ in ranges.append(range) }
            if ranges.count > 2048 {
                let end = ranges[ranges.count - 256].location
                line.setAttributes(attributes(AgentTerminalStyle()), range: NSRange(location: 0, length: end))
                runEstimates[id] = 257
            } else { runEstimates[id] = ranges.count }
        }
        let removed = trim(line)
        column = max(0, column - removed)
        if let position = saved, position.row == row { saved = (row, max(0, position.column - removed)) }
    }

    private func newline() {
        row += 1; column = 0
        if row == lines.count { lines.append(NSMutableAttributedString(string: "")) }
        if lines.count > 64 { _ = scrollOut() }
    }

    @discardableResult
    private func scrollOut() -> Int {
        let line = lines.removeFirst()
        settled += serialize(line) + "\n"
        runEstimates.removeValue(forKey: ObjectIdentifier(line))
        if settled.utf16.count > 2 * Self.limit { settled = tail(settled) }
        row -= 1
        if let position = saved { saved = (max(0, position.row - 1), position.column) }
        return line.length
    }

    private func serialize(_ line: NSAttributedString) -> String {
        var result = "", pen = ""
        let text = line.string as NSString
        line.enumerateAttribute(Self.penKey, in: NSRange(location: 0, length: line.length)) { value, range, _ in
            let next = value as? String ?? ""
            if next != pen { result += next.isEmpty ? "\u{1b}[0m" : "\u{1b}[0;" + next + "m"; pen = next }
            result += text.substring(with: range)
        }
        if !pen.isEmpty { result += "\u{1b}[0m" }
        return result
    }

    private func tail(_ source: String) -> String {
        let text = source as NSString
        guard text.length > Self.limit else { return source }
        dropped = true
        var start = text.length - Self.limit
        let newline = text.range(of: "\n", range: NSRange(location: start, length: text.length - start))
        if newline.location != NSNotFound, newline.location - start < Self.limit / 4 { return text.substring(from: newline.location + 1) }
        let preceding = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: start))
        var cursor = preceding.location == NSNotFound ? 0 : preceding.location + 1
        var prefix = ""
        var cutInsideEscape = false
        while cursor < start {
            let escape = text.range(of: "\u{1b}[", range: NSRange(location: cursor, length: text.length - cursor))
            if escape.location == NSNotFound || escape.location >= start { break }
            let end = text.range(of: "m", range: NSRange(location: escape.location, length: text.length - escape.location))
            if end.location == NSNotFound { break }
            prefix = text.substring(with: NSRange(location: escape.location, length: end.location + 1 - escape.location))
            if end.location >= start { start = end.location + 1; cutInsideEscape = true; break }
            cursor = end.location + 1
        }
        if !cutInsideEscape && prefix == "\u{1b}[0m" { prefix = "" }
        if start < text.length, (0xdc00...0xdfff).contains(text.character(at: start)) { start += 1 }
        return prefix + text.substring(from: start)
    }

    private func move(_ nextRow: Int, _ nextColumn: Int) {
        row = max(0, min(lines.count - 1, nextRow))
        column = max(0, min(Self.limit, nextColumn))
    }

    private func erase(_ index: Int, mode: Int) {
        let line = lines[index]
        switch mode {
        case 0:
            if column < line.length { line.deleteCharacters(in: NSRange(location: column, length: line.length - column)) }
        case 1:
            let count = min(column + 1, line.length)
            line.replaceCharacters(in: NSRange(location: 0, length: count), with: plain(String(repeating: " ", count: count)))
        default: line.setAttributedString(plain(""))
        }
    }

    private func csi(_ parameters: String, final: UInt16) {
        guard !["?", ">", "="].contains(parameters.first.map(String.init) ?? "") else { return }
        let values = AgentTerminalStyle.parameters(parameters)
        let count = min(Self.limit, max(1, values.first ?? 1))
        switch final {
        case 109: style.apply(parameters, palette: palette.colors) // m
        case 65: move(row - count, column)
        case 66: move(row + count, column)
        case 67: move(row, column + count)
        case 68: move(row, column - count)
        case 69: move(row + count, 0)
        case 70: move(row - count, 0)
        case 71: move(row, count - 1)
        case 72, 102: move(count - 1, max(1, values.count > 1 ? values[1] : 1) - 1)
        case 75: erase(row, mode: values.first ?? 0)
        case 74:
            switch values.first ?? 0 {
            case 0: erase(row, mode: 0); lines = Array(lines.prefix(row + 1))
            case 1:
                for index in 0..<row { lines[index] = NSMutableAttributedString(string: "") }
                erase(row, mode: 1)
            case 3:
                dropped = dropped || !settled.isEmpty
                settled = ""
            default: lines = [NSMutableAttributedString(string: "")]; row = 0; column = 0
            }
        case 115: saved = (row, column)
        case 117: if let saved { move(saved.row, saved.column) }
        default: break
        }
    }

    func normalize(_ source: String) -> (text: String, truncated: Bool) {
        let text = source as NSString
        var index = 0, start = 0
        while index < text.length {
            let code = text.character(at: index)
            if code == 9 || (code >= 32 && code != 127 && !(128...159).contains(code)) { index += 1; continue }
            write(text.substring(with: NSRange(location: start, length: index - start)))
            index += 1
            switch code {
            case 10: newline()
            case 13: column = 0
            case 8: column = max(0, column - 1)
            case 27:
                guard index < text.length else { start = index; continue }
                let next = text.character(at: index)
                index += 1
                if next == 91 {
                    let paramsStart = index
                    while index < text.length && !(64...126).contains(text.character(at: index)) { index += 1 }
                    if index < text.length {
                        csi(text.substring(with: NSRange(location: paramsStart, length: index - paramsStart)), final: text.character(at: index))
                        index += 1
                    }
                } else if [93, 80, 88, 95, 94].contains(next) {
                    while index < text.length {
                        let value = text.character(at: index)
                        if value == 10 { break }
                        if value == 7 { index += 1; break }
                        if value == 27, index + 1 < text.length, text.character(at: index + 1) == 92 { index += 2; break }
                        index += 1
                    }
                } else if [40, 41, 42, 43].contains(next) { index = min(text.length, index + 1) }
                else if next == 55 { saved = (row, column) }
                else if next == 56, let saved { move(saved.row, saved.column) }
                else if next == 77 { move(row - 1, column) }
            default: break
            }
            start = index
        }
        write(text.substring(from: start))
        var windowCharacters = lines.reduce(0) { $0 + $1.length }
        while windowCharacters > Self.limit && row > 0 { windowCharacters -= scrollOut() }
        if windowCharacters > Self.limit {
            var budget = Self.limit - lines.prefix(row + 1).reduce(0) { $0 + $1.length }
            for index in (row + 1)..<lines.count {
                let line = lines[index]
                let keep = max(0, min(line.length, budget))
                if keep < line.length { line.deleteCharacters(in: NSRange(location: 0, length: line.length - keep)); dropped = true }
                budget -= keep
            }
        }
        settled = tail(settled)
        let normalized = tail(settled + lines.map(serialize).joined(separator: "\n"))
        return (normalized, dropped)
    }

    func render(_ source: String) -> NSAttributedString {
        let normalized = normalize(source)
        let text = normalized.text as NSString
        let result = NSMutableAttributedString(string: "")
        var cursor = 0, spans = 0
        var style = AgentTerminalStyle()
        guard let escapes = try? NSRegularExpression(pattern: "\u{1b}\\[[0-9;]*m") else { return plain(normalized.text) }
        for match in escapes.matches(in: normalized.text, range: NSRange(location: 0, length: text.length)) {
            if spans >= 2000 { break }
            if match.range.location > cursor {
                result.append(NSAttributedString(string: text.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), attributes: attributes(style)))
                spans += 1
            }
            style = AgentTerminalStyle()
            style.apply(text.substring(with: NSRange(location: match.range.location + 2, length: match.range.length - 3)), palette: palette.colors)
            cursor = NSMaxRange(match.range)
        }
        if cursor < text.length {
            let remainder = text.substring(from: cursor)
            let plainRemainder = spans >= 2000 ? escapes.stringByReplacingMatches(in: remainder, range: NSRange(location: 0, length: (remainder as NSString).length), withTemplate: "") : remainder
            result.append(NSAttributedString(string: plainRemainder, attributes: attributes(spans >= 2000 ? AgentTerminalStyle() : style)))
        }
        if normalized.truncated {
            var style = AgentTerminalStyle(); style.italic = true
            result.insert(NSAttributedString(string: "Earlier output not shown\n", attributes: attributes(style)), at: 0)
        }
        return result
    }
}
