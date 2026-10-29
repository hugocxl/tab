import Foundation
import TabClient
import TabCore

/// What a terminal's menu offers for the proxy.
public enum ProxyMenuItem: Equatable, Sendable {
    /// No proxy is set up yet: open the Set Up Proxy… sheet.
    case setUp
    /// Restart the terminal in its folder with the proxy.
    case apply(enabled: Bool)
    /// Restart the terminal in its folder without the proxy.
    case remove(enabled: Bool)

    public var title: String {
        switch self {
        case .setUp: return "Set Up Proxy…"
        case .apply: return "Apply Proxy"
        case .remove: return "Remove Proxy"
        }
    }

    public var isEnabled: Bool {
        switch self {
        case .setUp: return true
        case .apply(let enabled), .remove(let enabled): return enabled
        }
    }
}

/// The app's one proxy, from `proxy.json`: which new terminals start with it,
/// and whether ssh and the app's downloads go through it.
@MainActor
public final class ProxyModel {
    public let file: URL
    public private(set) var settings: ProxySettings?
    /// Why `proxy.json` couldn't be read; never quotes the file.
    public private(set) var loadError: String?
    /// Whether the terminal a pane is about to start uses the proxy, as
    /// Apply or Remove Proxy chose. Other new terminals follow the whole-app
    /// choice.
    private var choices: [PaneId: Bool] = [:]

    public init(file: URL) {
        self.file = file
        do {
            settings = try ProxySettings.load(file)
        } catch {
            loadError = "\(error)"
        }
    }

    /// Whether new local terminals, ssh and downloads use the proxy.
    public var isGlobal: Bool { settings?.global == true }

    /// Saves the proxy, or removes it with `nil`. Running terminals keep
    /// what they started with.
    public func save(_ settings: ProxySettings?) throws {
        if let settings {
            try settings.save(to: file)
        } else {
            try ProxySettings.remove(file)
        }
        self.settings = settings
        loadError = nil
    }

    /// How ssh reaches other computers now; `nil` goes directly.
    public func sshCommand() throws -> ProxyCommand? {
        try ProxyEnvironment.sshCommand(settings)
    }

    /// A session configuration for the app's own downloads.
    public func sessionConfiguration() -> URLSessionConfiguration {
        ProxyEnvironment.sessionConfiguration(settings)
    }

    /// Notes that `pane`'s next terminal starts with the proxy or without it.
    public func choose(_ pane: PaneId, proxy: Bool) {
        choices[pane] = proxy
    }

    /// Drops the choice of a pane that closed.
    public func forget(_ pane: PaneId) {
        choices[pane] = nil
    }

    /// The environment a new terminal for `pane` starts with, and whether it
    /// includes the proxy, which the shell records on the pane to show the
    /// proxy icon. A server that can't start terminals with an environment
    /// gets none.
    public func creationEnvironment(for pane: PaneId, localServer: Bool,
                                    serverSupportsEnvironment: Bool) -> (environment: [String: String], proxied: Bool) {
        let wanted = choices[pane] ?? (localServer && isGlobal)
        guard wanted, serverSupportsEnvironment, let settings else { return ([:], false) }
        return (ProxyEnvironment.terminal(settings), true)
    }

    /// The terminal menu's way to the proxy for a pane.
    public func menuItem(paneUsesProxy: Bool, canRestart: Bool, serverSupportsEnvironment: Bool) -> ProxyMenuItem {
        if paneUsesProxy { return .remove(enabled: canRestart) }
        guard settings != nil else { return .setUp }
        return .apply(enabled: canRestart && serverSupportsEnvironment)
    }
}
