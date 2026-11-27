import AppKit
import TabCore

/// Lazy shared favicon state, matching the source renderer's blank loading box and sticky globe fallback.
@MainActor
final class AgentLinkFavicon {
    static let shared = AgentLinkFavicon()
    typealias Fetch = (URL) async throws -> Data
    private struct Observer { weak var manager: NSLayoutManager? }
    private var waiting: [String: [Observer]] = [:]
    private var images: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private let fetch: Fetch
    /// The remote-image setting: with `never`, no link icon is fetched either.
    var policy: () -> RemoteImagePolicy = { AgentSettings().remoteImages }

    init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 256 * 1024 else { throw URLError(.badServerResponse) }
            return data
        }
    }

    nonisolated static let hostMarks: [String: AppIcon] = [
        "github.com": .github, "gitlab.com": .gitlab, "bitbucket.org": .bitbucket,
        "codeberg.org": .forgejo, "git.cafe": .gitcafe,
    ]

    nonisolated static func brand(for host: String) -> String? {
        let host = host.lowercased()
        for (domain, icon) in hostMarks {
            if host == domain || host.hasSuffix("." + domain) { return icon.rawValue }
        }
        return nil
    }

    /// WHATWG URLs expand legacy numeric IPv4 spellings before favicon classification.
    nonisolated static func host(for url: URL) -> String? {
        guard let raw = url.host?.lowercased(), !raw.isEmpty else { return nil }
        if raw.contains(":") { return AgentFaviconHost.canonicalIPv6(raw) }
        var parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        guard let last = parts.last else { return nil }
        func number(_ value: String) -> UInt64? {
            if value.lowercased().hasPrefix("0x") { return value.count == 2 ? 0 : UInt64(value.dropFirst(2), radix: 16) }
            if value.count >= 2, value.hasPrefix("0") { return UInt64(value.dropFirst(), radix: 8) }
            return UInt64(value)
        }
        guard number(last) != nil || (!last.isEmpty && last.allSatisfy({ $0.isASCII && $0.isNumber })) else { return raw }
        guard parts.count <= 4 else { return nil }
        let values = parts.compactMap(number)
        guard values.count == parts.count, values.dropLast().allSatisfy({ $0 <= 255 }), let final = values.last,
              final < (UInt64(1) << (8 * (5 - values.count))) else { return nil }
        var value = final
        for (index, part) in values.dropLast().enumerated() { value += part << (8 * (3 - index)) }
        return [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".")
    }

    nonisolated static func requestURL(host: String) -> URL? {
        guard AgentFaviconHost.isPublic(host) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")
        guard let encoded = host.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(encoded)&sz=32")
    }

    /// The icon for `url`'s host. `fetch` false, as while the message still streams and
    /// its hosts may be half written, uses only what is already loaded, else a globe.
    func image(for url: URL, color: NSColor, manager: NSLayoutManager? = nil, fetch allowed: Bool = true) -> NSImage? {
        guard let host = Self.host(for: url) else { return nil }
        if let brand = Self.brand(for: host) {
            return AppIcon(rawValue: brand)?.image(size: 14, theme: AppTheme.shared)
        }
        guard let request = Self.requestURL(host: host), !failed.contains(host) else {
            return AppIcon.globe.image(size: 14, scale: AppIcon.inlineScale, color: color)
        }
        if let image = images[host] { return image }
        guard allowed, policy() != .never else { return AppIcon.globe.image(size: 14, scale: AppIcon.inlineScale, color: color) }
        if var observers = waiting[host] {
            if let manager, !observers.contains(where: { $0.manager === manager }) {
                observers.removeAll { $0.manager == nil }; observers.append(Observer(manager: manager)); waiting[host] = observers
            }
            // A globe holds the icon's place while it loads, so the link never shows a gap.
            return AppIcon.globe.image(size: 14, scale: AppIcon.inlineScale, color: color)
        }
        waiting[host] = manager.map { [Observer(manager: $0)] } ?? []
        Task { [weak self, fetch] in
            let data = try? await fetch(request)
            guard let self else { return }
            if let data, data.count <= 256 * 1024, let image = NSImage(data: data), image.isValid {
                image.size = NSSize(width: 14, height: 14)
                self.images[host] = image
            } else { self.failed.insert(host) }
            let observers = self.waiting.removeValue(forKey: host) ?? []
            for observer in observers {
                guard let manager = observer.manager, let storage = manager.textStorage else { continue }
                manager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
            }
        }
        return AppIcon.globe.image(size: 14, scale: AppIcon.inlineScale, color: color)
    }
}
