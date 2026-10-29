import Foundation

public enum SearchEngine: String, Codable, Sendable, CaseIterable {
    case google, duckDuckGo, bing, brave, startpage

    public var name: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        case .startpage: return "Startpage"
        }
    }

    private var endpoint: String {
        switch self {
        case .google: return "https://www.google.com/search"
        case .duckDuckGo: return "https://duckduckgo.com/"
        case .bing: return "https://www.bing.com/search"
        case .brave: return "https://search.brave.com/search"
        case .startpage: return "https://www.startpage.com/sp/search"
        }
    }

    public func searchURL(_ query: String) -> String {
        "\(endpoint)?q=\(Self.encodeQuery(query))"
    }

    private static func encodeQuery(_ query: String) -> String {
        var encoded = ""
        for byte in query.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"),
                 UInt8(ascii: "."), UInt8(ascii: "~"):
                encoded.append(Character(Unicode.Scalar(byte)))
            case UInt8(ascii: " "):
                encoded.append("+")
            default:
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }
}

/// The built-in browser's address rules: how typed text becomes an address.
public enum BrowserAddress {
    /// The page a pane with no address shows: the start page.
    public static let blank = "about:blank"
    public static let minimumZoom = 0.5
    public static let maximumZoom = 3.0
    private static let zoomStep = 1.1

    public static func isBlank(_ url: String) -> Bool { url.isEmpty || url == blank }

    /// Turns what was typed in the address bar into an address, or else a
    /// search. Schemes a page could abuse, such as `javascript:` or `file:`,
    /// become searches.
    public static func resolveInput(_ input: String, engine: SearchEngine) -> String? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        return resolveAddress(input) ?? engine.searchURL(input)
    }

    /// A web address as typed, or a host name with a scheme added.
    public static func resolveAddress(_ input: String) -> String? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(where: \.isWhitespace) else { return nil }
        if let colon = input.firstIndex(of: ":") {
            let scheme = input[..<colon].lowercased()
            let rest = input[input.index(after: colon)...]
            if scheme == "about" { return input }
            if (scheme == "http" || scheme == "https") && rest.hasPrefix("//") && rest.count > 2 { return input }
        }
        guard let host = host(of: input) else { return nil }
        return "\(isLocalHost(host) ? "http" : "https")://\(input)"
    }

    /// The host of text that names a site, such as `example.com/a` or
    /// `localhost:3000`.
    private static func host(of input: String) -> Substring? {
        guard let host = input.split(whereSeparator: { "/?#".contains($0) }).first,
              input.first.map({ !"/?#".contains($0) }) ?? false
        else { return nil }
        var name = host
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            if !port.isEmpty && port.allSatisfy({ $0.isASCII && $0.isNumber }) { name = host[..<colon] }
        }
        let dotted = name.contains(".") && !name.hasPrefix(".") && !name.hasSuffix(".")
        let valid = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        guard valid, dotted || name.lowercased() == "localhost" else { return nil }
        return name
    }

    /// Development servers rarely speak TLS, so these hosts get `http://`.
    private static func isLocalHost(_ host: Substring) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".localhost") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return UInt8(part)
        }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Whether a page may load `url` itself. Other schemes, such as `mailto:`
    /// or `file:`, never load in a page; a click on one goes to the system.
    public static func engineLoads(_ url: String) -> Bool {
        guard let colon = url.firstIndex(of: ":") else { return false }
        return ["http", "https", "about", "data", "blob"].contains(url[..<colon].lowercased())
    }

    /// The host of an absolute address, for titles.
    public static func host(ofURL url: String) -> String? {
        guard let range = url.range(of: "://") else { return nil }
        let rest = url[range.upperBound...]
        let authority = rest.split(omittingEmptySubsequences: false, whereSeparator: { "/?#".contains($0) }).first ?? ""
        var host = authority
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if let colon = host.lastIndex(of: ":"), host[host.index(after: colon)...].allSatisfy({ $0.isASCII && $0.isNumber }) {
            host = host[..<colon]
        }
        return host.isEmpty ? nil : String(host)
    }

    /// What a browser pane is called: the page title, else its host.
    public static func displayTitle(_ title: String, url: String?) -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        guard let url, !isBlank(url) else { return nil }
        return host(ofURL: url)
    }

    public static func zoomIn(_ zoom: Double) -> Double { min(zoom * zoomStep, maximumZoom) }
    public static func zoomOut(_ zoom: Double) -> Double { max(zoom / zoomStep, minimumZoom) }
}

public struct BrowserSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Terminal links open in a browser pane instead of the system browser.
    public var openTerminalLinks: Bool
    /// The profile new panes use, by id; empty means the Default profile.
    public var defaultProfile: String
    public var searchEngine: SearchEngine
    /// The page new panes open to; empty means the start page.
    public var homePage: String

    public init(
        enabled: Bool = true,
        openTerminalLinks: Bool = false,
        defaultProfile: String = "",
        searchEngine: SearchEngine = .google,
        homePage: String = ""
    ) {
        self.enabled = enabled
        self.openTerminalLinks = openTerminalLinks
        self.defaultProfile = defaultProfile
        self.searchEngine = searchEngine
        self.homePage = homePage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = BrowserSettings()
        enabled = try container.value(.enabled, d.enabled)
        openTerminalLinks = try container.value(.openTerminalLinks, d.openTerminalLinks)
        defaultProfile = try container.value(.defaultProfile, d.defaultProfile)
        searchEngine = try container.value(.searchEngine, d.searchEngine)
        homePage = try container.value(.homePage, d.homePage)
    }

    public func validate() throws {
        if !homePage.trimmingCharacters(in: .whitespaces).isEmpty && homeURL == nil {
            throw SettingsError("browser.homePage", "must be a web address or empty")
        }
    }

    /// Where new panes go: the home page, or `nil` for the start page.
    public var homeURL: String? {
        let home = homePage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty, home != BrowserAddress.blank else { return nil }
        return BrowserAddress.resolveAddress(home)
    }

    /// The address for what was typed in the address bar.
    public func resolve(_ input: String) -> String? {
        BrowserAddress.resolveInput(input, engine: searchEngine)
    }
}
