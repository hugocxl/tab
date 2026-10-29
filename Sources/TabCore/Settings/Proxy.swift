import Foundation

public enum ProxyKind: String, Codable, Sendable, CaseIterable {
    case http
    case socks5
}

/// The app's one proxy, in `proxy.json` apart from `settings.json` because it
/// can hold a password: only this user can read it, and backups leave it out.
public struct ProxySettings: Codable, Equatable, Sendable {
    /// Hosts a new proxy reaches directly.
    public static let defaultBypass = "localhost, 127.0.0.1, ::1"

    public var kind: ProxyKind
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    /// Hosts reached directly, as a `no_proxy` list.
    public var bypass: String
    /// New terminals on this computer, the app's own requests, and SSH to
    /// other computers all use the proxy.
    public var global: Bool

    public init(
        kind: ProxyKind = .http,
        host: String = "",
        port: Int = 0,
        username: String = "",
        password: String = "",
        bypass: String = "",
        global: Bool = false
    ) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.bypass = bypass
        self.global = global
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.value(.kind, .http)
        host = try container.value(.host, "")
        port = try container.value(.port, 0)
        username = try container.value(.username, "")
        password = try container.value(.password, "")
        bypass = try container.value(.bypass, "")
        global = try container.value(.global, false)
    }

    /// The saved proxy; `nil` when there is no file. Errors never quote the
    /// file, which can hold a password.
    public static func load(_ url: URL) throws -> ProxySettings? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw SettingsError(url.path, error.localizedDescription)
        }
        guard let proxy = try? JSONDecoder().decode(ProxySettings.self, from: data) else {
            throw SettingsError(url.path, "invalid proxy settings")
        }
        try proxy.validate()
        return proxy
    }

    /// Writes the file readable only by this user.
    public func save(to url: URL) throws {
        try validate()
        do {
            try AtomicFile.write(SettingsJSON.encode(self), to: url, permissions: 0o600)
        } catch {
            throw SettingsError(url.path, error.localizedDescription)
        }
    }

    /// Removes the proxy; a missing file is fine.
    public static func remove(_ url: URL) throws {
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw SettingsError(url.path, String(cString: strerror(errno)))
        }
    }

    public func validate() throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let badCharacter = host.contains { $0.isWhitespace || "/@?#[]".contains($0) } || host.hasControlCharacter
        if trimmed.isEmpty || trimmed != host || badCharacter || (host.contains(":") && IPAddress(host)?.isV6 != true) {
            throw SettingsError("proxy.host", "enter a host name or address")
        }
        guard (1...65535).contains(port) else { throw SettingsError("proxy.port", "enter a port") }
        if username.isEmpty && !password.isEmpty {
            throw SettingsError("proxy.username", "enter the user name")
        }
        for (name, value) in [("username", username), ("password", password), ("bypass", bypass)]
            where value.hasControlCharacter
        {
            throw SettingsError("proxy.\(name)", "must not contain control characters")
        }
    }

    /// As programs read it from `http_proxy` and the like.
    public var url: String { url(scheme: kind == .http ? "http" : "socks5") }

    /// Like `url`, but a SOCKS proxy also looks up host names, so names this
    /// computer can't resolve still work.
    public var urlWithRemoteNames: String { url(scheme: kind == .http ? "http" : "socks5h") }

    private func url(scheme: String) -> String {
        let credentials: String
        switch (username.isEmpty, password.isEmpty) {
        case (true, _): credentials = ""
        case (false, true): credentials = "\(Self.percentEncode(username))@"
        case (false, false): credentials = "\(Self.percentEncode(username)):\(Self.percentEncode(password))@"
        }
        return "\(scheme)://\(credentials)\(bracketedHost):\(port)"
    }

    /// An IPv6 address needs brackets before its port.
    public var bracketedHost: String { host.contains(":") ? "[\(host)]" : host }

    /// The hosts reached directly, one per entry.
    public var bypassHosts: [String] {
        bypass.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    /// Whether `host` is reached directly, as `no_proxy` decides: an exact
    /// host, a domain and its subdomains, a CIDR range, or `*`.
    public func bypasses(_ host: String) -> Bool {
        var host = Substring(host)
        while host.hasPrefix("[") { host = host.dropFirst() }
        while host.hasSuffix("]") { host = host.dropLast() }
        let address = IPAddress(String(host))
        return bypassHosts.contains { entry in
            var domain = Substring(entry)
            while domain.hasPrefix(".") { domain = domain.dropFirst() }
            if entry == "*" { return true }
            if let address, Self.subnet(entry, contains: address) { return true }
            if host.lowercased() == domain.lowercased() { return true }
            guard host.count > domain.count else { return false }
            let suffix = host.suffix(domain.count + 1)
            return suffix.first == "." && suffix.dropFirst().lowercased() == domain.lowercased()
        }
    }

    /// Variables that send a terminal's programs through the proxy, in both
    /// spellings since programs disagree on which one they read.
    public var environment: [String: String] {
        var environment: [String: String] = [:]
        for name in ["http_proxy", "https_proxy", "all_proxy"] {
            environment[name] = url
            environment[name.uppercased()] = url
        }
        let bypass = bypassHosts.joined(separator: ",")
        environment["no_proxy"] = bypass
        environment["NO_PROXY"] = bypass
        return environment
    }

    private static func subnet(_ entry: String, contains address: IPAddress) -> Bool {
        let parts = entry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let network = IPAddress(String(parts[0])),
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let prefix = Int(parts[1]),
              network.isV6 == address.isV6
        else { return false }
        let bits = address.bytes.count * 8
        guard prefix <= bits else { return false }
        var remaining = prefix
        for (left, right) in zip(address.bytes, network.bytes) {
            guard remaining > 0 else { break }
            let take = min(8, remaining)
            let mask: UInt8 = take == 8 ? 0xFF : ~(0xFF >> UInt8(take))
            if left & mask != right & mask { return false }
            remaining -= take
        }
        return true
    }

    /// Keeps only unreserved URL characters as they are.
    private static func percentEncode(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            let character = Character(Unicode.Scalar(byte))
            if byte < 0x80 && (character.isLetter || character.isNumber || "-._~".contains(character)) {
                encoded.append(character)
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }
}

/// An IPv4 or IPv6 address, parsed strictly.
struct IPAddress: Equatable {
    let bytes: [UInt8]
    var isV6: Bool { bytes.count == 16 }

    init?(_ text: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return
        }
        return nil
    }
}
