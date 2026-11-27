import Foundation

/// Ordered JSON for tool presentation. Object insertion order is visible in the source renderer's argument rows.
indirect enum AgentToolJSON {
    case string(String), literal(String), array([AgentToolJSON]), object([(String, AgentToolJSON)])

    var string: String? { if case .string(let value) = self { return value }; return nil }
    subscript(_ key: String) -> AgentToolJSON? {
        if case .object(let entries) = self { return entries.first { $0.0 == key }?.1 }
        return nil
    }

    static func parse(_ source: String) -> AgentToolJSON? {
        guard let data = source.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else { return nil }
        let source = source as NSString
        var cursor = 0
        func whitespace() { while cursor < source.length && [9, 10, 13, 32].contains(source.character(at: cursor)) { cursor += 1 } }
        func value(_ depth: Int) -> AgentToolJSON? {
            guard depth < 128 else { return nil }
            whitespace()
            guard cursor < source.length else { return nil }
            let first = source.character(at: cursor)
            if first == 34 {
                let start = cursor; cursor += 1
                while cursor < source.length {
                    let code = source.character(at: cursor); cursor += 1
                    if code == 92 { cursor += 1 } else if code == 34 { break }
                }
                let token = source.substring(with: NSRange(location: start, length: cursor - start))
                guard let data = token.data(using: .utf8), let string = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String else { return nil }
                return .string(string)
            }
            if first == 123 || first == 91 {
                cursor += 1; whitespace()
                let end: UInt16 = first == 123 ? 125 : 93
                var entries: [(String, AgentToolJSON)] = [], items: [AgentToolJSON] = []
                while cursor < source.length && source.character(at: cursor) != end {
                    if first == 123 {
                        guard let key = value(depth + 1)?.string else { return nil }
                        whitespace(); cursor += 1 // colon, validated by Foundation
                        guard let child = value(depth + 1) else { return nil }
                        if let index = entries.firstIndex(where: { $0.0 == key }) { entries[index].1 = child }
                        else { entries.append((key, child)) }
                    } else {
                        guard let child = value(depth + 1) else { return nil }; items.append(child)
                    }
                    whitespace()
                    if cursor < source.length && source.character(at: cursor) == 44 { cursor += 1; whitespace() }
                    else { break }
                }
                cursor += 1
                if first == 91 { return .array(items) }
                // JavaScript Object.entries enumerates canonical array-index keys first.
                func index(_ key: String) -> UInt32? { guard let number = UInt32(key), number != UInt32.max, String(number) == key else { return nil }; return number }
                let numeric = entries.compactMap { entry in index(entry.0).map { ($0, entry) } }
                    .sorted { $0.0 < $1.0 }.map(\.1)
                return .object(numeric + entries.filter { index($0.0) == nil })
            }
            let start = cursor
            while cursor < source.length && ![9, 10, 13, 32, 44, 93, 125].contains(source.character(at: cursor)) { cursor += 1 }
            let token = source.substring(with: NSRange(location: start, length: cursor - start))
            return .literal(Double(token).map(Self.number) ?? token)
        }
        return value(0)
    }

    static func quoted(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let result = String(data: data, encoding: .utf8) else { return "\"\"" }
        return result
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == 0 { return "0" }
        var text = String(value)
        let pieces = text.lowercased().components(separatedBy: "e")
        if pieces.count == 2, let exponent = Int(pieces[1]) {
            if abs(value) >= 1e-6 && abs(value) < 1e21 {
                let sign = value < 0 ? "-" : ""
                let mantissa = pieces[0].replacingOccurrences(of: "-", with: "")
                let decimal = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count
                let digits = mantissa.replacingOccurrences(of: ".", with: "")
                let position = decimal + exponent
                if position <= 0 { return sign + "0." + String(repeating: "0", count: -position) + digits }
                if position >= digits.count { return sign + digits + String(repeating: "0", count: position - digits.count) }
                return sign + digits.prefix(position) + "." + digits.dropFirst(position)
            }
            let mantissa = pieces[0].hasSuffix(".0") ? String(pieces[0].dropLast(2)) : pieces[0]
            return mantissa + "e" + (exponent >= 0 ? "+" : "") + String(exponent)
        }
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text
    }

    func encoded(pretty: Bool = false, depth: Int = 0) -> String {
        switch self {
        case .string(let value): return Self.quoted(value)
        case .literal(let value): return value
        case .array(let values):
            return joined(values.map { $0.encoded(pretty: pretty, depth: depth + 1) }, open: "[", close: "]", pretty: pretty, depth: depth)
        case .object(let entries):
            return joined(entries.map { Self.quoted($0.0) + (pretty ? ": " : ":") + $0.1.encoded(pretty: pretty, depth: depth + 1) }, open: "{", close: "}", pretty: pretty, depth: depth)
        }
    }

    private func joined(_ parts: [String], open: String, close: String, pretty: Bool, depth: Int) -> String {
        guard !parts.isEmpty else { return open + close }
        guard pretty else { return open + parts.joined(separator: ",") + close }
        let indent = String(repeating: "  ", count: depth)
        return open + "\n" + parts.map { indent + "  " + $0 }.joined(separator: ",\n") + "\n" + indent + close
    }
}
