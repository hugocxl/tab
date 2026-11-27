import Darwin
import Foundation
import TabProtocol

/// Addresses a phone can try to reach this Mac, for the pairing link.
enum PairingHosts {
    /// The given hosts first, then this Mac's IPv4 addresses (local networks
    /// before Tailscale), then its `.local` name; each once, ignoring case,
    /// at most `Limits.maxPairingHosts`.
    static func candidates(given: [String], interfaces: [String] = localAddresses(),
                           localName: String? = PairingHosts.localName()) -> [String] {
        let tailscale = interfaces.filter(isTailscale)
        let local = interfaces.filter { !isTailscale($0) }
        var kept: [String] = []
        for host in given + local + tailscale + [localName].compactMap({ $0 }) {
            guard kept.count < Limits.maxPairingHosts else { break }
            if !kept.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) {
                kept.append(host)
            }
        }
        return kept
    }

    /// IPv4 addresses of interfaces that are up, excluding loopback and
    /// link-local ones.
    static func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var raw = ipv4
            guard inet_ntop(AF_INET, &raw, &text, socklen_t(text.count)) != nil else { continue }
            let string = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if string.hasPrefix("169.254.") || addresses.contains(string) { continue }
            addresses.append(string)
        }
        return addresses
    }

    static func isTailscale(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 100 && (64 ..< 128).contains(parts[1])
    }

    /// `name.local` for a plain host name, the name itself when it already
    /// has a domain, `nil` when it isn't a valid DNS name.
    static func localName(_ name: String = nodeName()) -> String? {
        guard !name.isEmpty, name.utf8.allSatisfy({ isDNSByte($0) }) else { return nil }
        return name.contains(".") ? name : name + ".local"
    }

    /// The Mac's name for the phone's list of servers.
    static func displayName(_ name: String = nodeName()) -> String {
        let trimmed = name.hasSuffix(".local") ? String(name.dropLast(6)) : name
        return trimmed.isEmpty ? "Tab" : trimmed
    }

    static func nodeName() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "" }
        return withUnsafeBytes(of: &info.nodename) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }.trimmingCharacters(in: .whitespaces)
    }

    private static func isDNSByte(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
            || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
    }
}
