import Foundation
import Network
import TabClient
import TabCore

/// What the proxy changes beyond its file: the environment of new
/// terminals, how ssh reaches other computers, and the app's own downloads.
public enum ProxyEnvironment {
    /// The variables a new terminal starts with to use `proxy`:
    /// `http_proxy`, `https_proxy`, `all_proxy` and `no_proxy`, in both cases.
    public static func terminal(_ proxy: ProxySettings?) -> [String: String] {
        proxy?.environment ?? [:]
    }

    /// How ssh reaches other computers while `proxy` applies to the whole
    /// app: through `ProxyTunnel` run from `program`, which honors the
    /// bypass list. `nil` when there is no whole-app proxy.
    public static func sshCommand(_ proxy: ProxySettings?, program: String? = Executable.currentURL()?.path) throws -> ProxyCommand? {
        guard let proxy, proxy.global else { return nil }
        guard let program else { throw TunnelError("this app's executable was not found") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let settings = String(decoding: try encoder.encode(proxy), as: UTF8.self)
        return ProxyCommand(program: program, arguments: [ProxyTunnel.argument],
                            environment: [ProxyTunnel.settingsVariable: settings])
    }

    /// A session configuration for the app's own downloads: through `proxy`
    /// while it applies to the whole app, except for bypassed hosts. A proxy
    /// that can't be used fails the request instead of going around it.
    public static func sessionConfiguration(_ proxy: ProxySettings?,
                                            base: URLSessionConfiguration = .ephemeral) -> URLSessionConfiguration {
        let configuration = base
        guard let proxy, proxy.global, let port = NWEndpoint.Port(rawValue: UInt16(clamping: proxy.port)) else {
            return configuration
        }
        if proxy.bypassHosts.contains("*") {
            configuration.proxyConfigurations = []
            return configuration
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.host), port: port)
        var route: ProxyConfiguration
        switch proxy.kind {
        case .http: route = ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .socks5: route = ProxyConfiguration(socksv5Proxy: endpoint)
        }
        if !proxy.username.isEmpty {
            route.applyCredential(username: proxy.username, password: proxy.password)
        }
        route.excludedDomains = proxy.bypassHosts.compactMap(excludedDomain)
        configuration.proxyConfigurations = [route]
        return configuration
    }

    /// A bypass entry as a domain the session goes to directly; `*` and
    /// address ranges have no domain form.
    static func excludedDomain(_ entry: String) -> String? {
        var domain = Substring(entry)
        while domain.hasPrefix(".") { domain = domain.dropFirst() }
        guard !domain.isEmpty, domain != "*", !domain.contains("/") else { return nil }
        return String(domain)
    }
}
