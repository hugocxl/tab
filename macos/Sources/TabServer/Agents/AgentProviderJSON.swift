import Foundation
import Darwin

/// Selects original JSON subtrees from an already validated provider event.
/// Skipping unrelated strings avoids decoding/copying large image payloads again.
struct AgentProviderJSON {
    enum Component: Hashable { case key(String), index(Int) }
    struct Replacement {
        var path: [Component]
        var json: String
    }
    let data: Data

    func value(at path: [Component]) -> String? {
        let range: Range<Int>? = data.withUnsafeBytes { raw in
            var cursor = Cursor(bytes: raw.bindMemory(to: UInt8.self))
            return cursor.find(path[...], depth: 0)
        }
        guard let range else { return nil }
        return String(data: data.subdata(in: range), encoding: .utf8)
    }

    /// Copies only retained byte ranges; removed image blobs never become Strings.
    func value(at path: [Component], replacing replacements: [Replacement]) -> String? {
        guard !replacements.isEmpty else { return value(at: path) }
        let tree = Patch()
        for replacement in replacements {
            var node = tree
            for component in replacement.path {
                if node.children[component] == nil { node.children[component] = Patch() }
                guard let child = node.children[component] else { return nil }
                node = child
            }
            node.json = Data(replacement.json.utf8)
        }
        let selected: (Range<Int>, [(Range<Int>, Data)])? = data.withUnsafeBytes { raw in
            var cursor = Cursor(bytes: raw.bindMemory(to: UInt8.self))
            guard let range = cursor.find(path[...], depth: 0) else { return nil }
            cursor.position = range.lowerBound
            var edits: [(Range<Int>, Data)] = []
            var applied = 0
            guard cursor.collect(tree, depth: 0, edits: &edits, applied: &applied), applied == replacements.count else { return nil }
            return (range, edits)
        }
        guard let (range, edits) = selected else { return nil }
        var output = Data()
        output.reserveCapacity(min(range.count, 64 * 1024))
        var position = range.lowerBound
        for (removed, replacement) in edits {
            guard removed.lowerBound >= position, removed.upperBound <= range.upperBound else { return nil }
            output.append(data[position..<removed.lowerBound]); output.append(replacement)
            position = removed.upperBound
        }
        output.append(data[position..<range.upperBound])
        return String(data: output, encoding: .utf8)
    }

    private final class Patch {
        var json: Data?
        var children: [Component: Patch] = [:]
    }

    private struct Cursor {
        let bytes: UnsafeBufferPointer<UInt8>
        var position = 0
        var current: UInt8? { position < bytes.count ? bytes[position] : nil }
        mutating func whitespace() { while let byte = current, [9, 10, 13, 32].contains(byte) { position += 1 } }
        mutating func string() -> Range<Int>? {
            guard current == 34 else { return nil }
            let start = position; position += 1
            guard let base = bytes.baseAddress else { return nil }
            while position < bytes.count {
                guard let quote = memchr(base.advanced(by: position), 34, bytes.count - position) else { return nil }
                let index = UnsafeRawPointer(base).distance(to: quote)
                var slash = index - 1
                while slash >= start, bytes[slash] == 92 { slash -= 1 }
                position = index + 1
                if (index - slash - 1) % 2 == 0 { return start..<position }
            }
            return nil
        }
        mutating func skip() -> Bool {
            whitespace()
            guard let first = current else { return false }
            if first == 34 { return string() != nil }
            if first == 123 || first == 91 {
                var ends: [UInt8] = [first == 123 ? 125 : 93]
                position += 1
                while let byte = current {
                    if byte == 34 { guard string() != nil else { return false }; continue }
                    position += 1
                    if byte == 123 || byte == 91 {
                        guard ends.count < 128 else { return false }
                        ends.append(byte == 123 ? 125 : 93)
                    } else if byte == 125 || byte == 93 {
                        guard ends.popLast() == byte else { return false }
                        if ends.isEmpty { return true }
                    }
                }
                return false
            }
            let start = position
            while let byte = current, ![9, 10, 13, 32, 44, 93, 125].contains(byte) { position += 1 }
            return position > start
        }
        mutating func collect(_ patch: Patch, depth: Int, edits: inout [(Range<Int>, Data)], applied: inout Int) -> Bool {
            guard depth < 128 else { return false }
            whitespace()
            if let json = patch.json {
                let start = position
                guard skip() else { return false }
                edits.append((start..<position, json)); applied += 1
                return true
            }
            if current == 123 {
                // Resolve duplicate keys before visiting children. JSON.parse keeps
                // the first key position but the last value. Nulling shadowed values
                // preserves that ordering while removing any ignored image payload.
                position += 1
                var members: [(String, Range<Int>)] = []
                var last: [String: Int] = [:]
                while true {
                    whitespace()
                    if current == 125 { position += 1; break }
                    guard let keyRange = string(),
                          let key = (try? JSONSerialization.jsonObject(with: Data(bytes[keyRange]), options: .fragmentsAllowed)) as? String else { return false }
                    whitespace(); guard current == 58 else { return false }; position += 1
                    whitespace(); let start = position
                    guard skip() else { return false }
                    last[key] = members.count; members.append((key, start..<position))
                    whitespace()
                    if current == 44 { position += 1 } else if current != 125 { return false }
                }
                let end = position
                for (index, member) in members.enumerated() {
                    let (key, range) = member
                    if last[key] != index { edits.append((range, Data("null".utf8))); continue }
                    if let child = patch.children[.key(key)] {
                        position = range.lowerBound
                        guard collect(child, depth: depth + 1, edits: &edits, applied: &applied) else { return false }
                    }
                }
                position = end
                return true
            }
            guard current == 91 else { return false }
            position += 1
            var index = 0
            while true {
                whitespace()
                if current == 93 { position += 1; return true }
                if let child = patch.children[.index(index)] {
                    guard collect(child, depth: depth + 1, edits: &edits, applied: &applied) else { return false }
                } else { guard skip() else { return false } }
                index += 1
                whitespace()
                if current == 44 { position += 1 } else if current != 93 { return false }
            }
        }
        mutating func find(_ path: ArraySlice<Component>, depth: Int) -> Range<Int>? {
            guard depth < 128 else { return nil }
            whitespace()
            guard let component = path.first else {
                let start = position
                return skip() ? start..<position : nil
            }
            switch component {
            case .key(let wanted):
                guard current == 123 else { return nil }
                position += 1
                var found: Range<Int>?
                while true {
                    whitespace()
                    if current == 125 { position += 1; return found }
                    guard let keyRange = string() else { return nil }
                    let key: String? = keyRange.count <= wanted.utf8.count * 6 + 2
                        ? (try? JSONSerialization.jsonObject(with: Data(bytes[keyRange]), options: .fragmentsAllowed) as? String) : nil
                    whitespace(); guard current == 58 else { return nil }; position += 1
                    whitespace()
                    let start = position
                    if key == wanted {
                        found = find(path.dropFirst(), depth: depth + 1)
                        // A missing child path can stop partway through this value.
                        position = start
                    }
                    guard skip() else { return nil }
                    whitespace()
                    if current == 44 { position += 1 } else if current != 125 { return nil }
                }
            case .index(let wanted):
                guard wanted >= 0, current == 91 else { return nil }
                position += 1
                var index = 0
                while true {
                    whitespace()
                    if current == 93 { return nil }
                    if index == wanted { return find(path.dropFirst(), depth: depth + 1) }
                    guard skip() else { return nil }
                    whitespace(); guard current == 44 else { return nil }
                    position += 1; index += 1
                }
            }
        }
    }
}
