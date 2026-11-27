import Foundation

/// The source renderer's public-favicon classification. Private names and special-use addresses use a globe.
enum AgentFaviconHost {
    static func normalized(_ host: String) -> String {
        var value = host.lowercased()
        if value.hasPrefix("[") { value.removeFirst() }
        if value.hasSuffix("]") { value.removeLast() }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    static func canonicalIPv6(_ input: String) -> String? {
        var host = normalized(input)
        if host.contains("."), let colon = host.lastIndex(of: ":"),
           let parts = ipv4(String(host[host.index(after: colon)...])) {
            host = String(host[...colon]) + String(parts[0] * 256 + parts[1], radix: 16) + ":" + String(parts[2] * 256 + parts[3], radix: 16)
        }
        guard let address = ipv6(host) else { return nil }
        var bestStart = 0, bestLength = 0, index = 0
        while index < address.count {
            guard address[index] == 0 else { index += 1; continue }
            let start = index
            while index < address.count, address[index] == 0 { index += 1 }
            if index - start > bestLength { bestStart = start; bestLength = index - start }
        }
        let values = address.map { String($0, radix: 16) }
        if bestLength >= 2 {
            return "[" + values[..<bestStart].joined(separator: ":") + "::" + values[(bestStart + bestLength)...].joined(separator: ":") + "]"
        }
        return "[" + values.joined(separator: ":") + "]"
    }

    static func isPublic(_ host: String) -> Bool {
        guard !host.hasSuffix("..") else { return false }
        let host = normalized(host)
        let suffixes = [".localhost", ".local", ".home.arpa", ".ts.net", ".alt", ".corp", ".example", ".home", ".internal", ".intranet", ".invalid", ".lan", ".onion", ".private", ".test"]
        if host == "localhost" || host == "home.arpa" || host == "::" || host == "::1" || (!host.contains(".") && !host.contains(":")) { return false }
        if suffixes.contains(where: { host == String($0.dropFirst()) || host.hasSuffix($0) }) { return false }
        if host.split(separator: ".").contains(where: { ["corp", "internal", "intranet"].contains(String($0)) }) { return false }
        if let parts = ipv4(host) { return !specialIPv4(parts) }
        if host.hasPrefix("::ffff:") {
            let suffix = String(host.dropFirst(7))
            if let parts = ipv4(suffix) { return !specialIPv4(parts) }
            let halves = suffix.split(separator: ":", omittingEmptySubsequences: false)
            if halves.count == 2, let high = hex(halves[0]), let low = hex(halves[1]) {
                return !specialIPv4([high >> 8, high & 255, low >> 8, low & 255])
            }
        }
        guard host.contains(":") else { return true }
        guard let address = ipv6(host) else { return false }
        if prefix(address, [0x64, 0xff9b, 0, 0, 0, 0], bits: 96) {
            return !specialIPv4([address[6] >> 8, address[6] & 255, address[7] >> 8, address[7] & 255])
        }
        guard address[0] & 0xe000 == 0x2000 else { return false }
        if prefix(address, [0x2001, 0], bits: 23) {
            return (address[1] == 1 && address[2..<7].allSatisfy { $0 == 0 } && [1, 2, 3].contains(address[7]))
                || prefix(address, [0x2001, 3], bits: 32)
                || prefix(address, [0x2001, 4, 0x112], bits: 48)
                || prefix(address, [0x2001, 0x20], bits: 28)
                || prefix(address, [0x2001, 0x30], bits: 28)
        }
        if prefix(address, [0x2001, 0xdb8], bits: 32) || address[0] == 0x2002 { return false }
        if address[0] == 0x3fff && address[1] & 0xf000 == 0 { return false }
        return true
    }

    private static func specialIPv4(_ p: [Int]) -> Bool {
        p[0] == 0 || p[0] == 10 || p[0] == 127 || p[0] >= 224
            || (p[0] == 100 && (64...127).contains(p[1]))
            || (p[0] == 172 && (16...31).contains(p[1]))
            || (p[0] == 192 && p[1] == 168) || (p[0] == 169 && p[1] == 254)
            || (p[0] == 198 && (18...19).contains(p[1]))
            || (p[0] == 192 && p[1] == 0 && [0, 2].contains(p[2]))
            || (p[0] == 192 && p[1] == 88 && p[2] == 99)
            || (p[0] == 198 && p[1] == 51 && p[2] == 100)
            || (p[0] == 203 && p[1] == 0 && p[2] == 113)
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let tokens = host.split(separator: ".", omittingEmptySubsequences: false)
        guard tokens.count == 4 else { return nil }
        var parts: [Int] = []
        for token in tokens {
            let value = token.isEmpty ? 0 : Double(token)
            guard let value, value.isFinite, value.rounded() == value, value >= 0, value <= 255 else { return nil }
            parts.append(Int(value))
        }
        return parts
    }

    private static func hex(_ token: Substring) -> Int? {
        guard !token.isEmpty, token.count <= 4, token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return Int(token, radix: 16)
    }

    private static func ipv6(_ host: String) -> [Int]? {
        let halves = host.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        let head = halves[0].isEmpty ? [] : halves[0].split(separator: ":", omittingEmptySubsequences: false)
        let tail = halves.count == 1 || halves[1].isEmpty ? [] : halves[1].split(separator: ":", omittingEmptySubsequences: false)
        let parsed = (head + tail).compactMap(hex)
        guard parsed.count == head.count + tail.count else { return nil }
        let missing = 8 - parsed.count
        guard halves.count == 1 ? missing == 0 : missing >= 1 else { return nil }
        return Array(parsed.prefix(head.count)) + Array(repeating: 0, count: missing) + Array(parsed.suffix(tail.count))
    }

    private static func prefix(_ address: [Int], _ prefix: [Int], bits: Int) -> Bool {
        let full = bits / 16, remainder = bits % 16
        guard address.prefix(full).elementsEqual(prefix.prefix(full)) else { return false }
        guard remainder != 0 else { return true }
        let mask = (0xffff << (16 - remainder)) & 0xffff
        return address[full] & mask == prefix[full] & mask
    }
}
