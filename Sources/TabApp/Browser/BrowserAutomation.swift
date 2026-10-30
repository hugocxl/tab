import AppKit
import TabClient
import TabCore
import WebKit

/// Carries out `tab browser` commands against the app's browser panes. The
/// shell calls `handle` from its `app.sock` handler with the command and its
/// arguments, and replies with the result or the thrown message.
@MainActor
public final class BrowserAutomation {
    /// How long a navigation that a click just caused may take to start.
    static let navigationStart: TimeInterval = 0.5

    private weak var host: BrowserHost?

    public init(host: BrowserHost) {
        self.host = host
    }

    /// Carries out `command`. Errors are `BrowserScripts.Failure`s whose
    /// message is meant for the CLI user.
    public func handle(command: BrowserCommand, args: JSONValue) async throws -> JSONValue {
        guard let host else { throw BrowserScripts.Failure("Tab is closing") }
        guard host.browserSettings.enabled else {
            if command == .list { return .array([]) }
            throw BrowserScripts.Failure("the built-in browser is disabled")
        }
        switch command {
        case .open:
            return .string(try open(args, host: host))
        case .list:
            return try list(args, host: host)
        case .navigate:
            let pane = try page(args, host: host)
            guard let url = host.browserSettings.resolve(try BrowserScripts.string(args, "url")) else {
                throw BrowserScripts.Failure("invalid url")
            }
            host.browserPane(pane, didChange: BrowserPane(url: url, profile: pane.profile.id))
            pane.load(url)
            return .null
        case .close:
            let id = try BrowserScripts.string(args, "tabId")
            guard host.closeBrowserPane(tabId: id) else { throw notFound(id) }
            return .null
        case .reload:
            try page(args, host: host).reload()
            return .null
        case .back:
            try page(args, host: host).goBack()
            return .null
        case .forward:
            try page(args, host: host).goForward()
            return .null
        case .screenshot:
            let png = try await page(args, host: host).screenshot()
            return .object(["png": .string(png.base64EncodedString())])
        case .wait, .waitFor:
            let condition = try BrowserScripts.condition(command, args: args)
            return .bool(try await waitUntil(condition, pane: try page(args, host: host),
                                             timeout: BrowserScripts.timeout(args, default: BrowserCommand.defaultWait)))
        case .waitForNavigation:
            return try await waitForNavigation(try page(args, host: host),
                                               timeout: BrowserScripts.timeout(args, default: BrowserCommand.defaultNavigationWait))
        case .cookiesGet, .cookiesSet, .cookiesDelete, .cookiesClear:
            return try await cookies(command, pane: try page(args, host: host), args: args)
        default:
            guard let script = try BrowserScripts.script(command, args: args) else {
                throw BrowserScripts.Failure("unknown command browser.\(command.rawValue)")
            }
            return try await page(args, host: host).run(script, timeout: BrowserCommand.maxWait)
        }
    }

    /// Carries out a command by its wire name, as `app.sock` delivers it.
    public func handle(command name: String, args: [String: JSONValue]) async throws -> JSONValue {
        let name = name.hasPrefix("browser.") ? String(name.dropFirst("browser.".count)) : name
        guard let host else { throw BrowserScripts.Failure("Tab is closing") }
        guard host.browserSettings.enabled else {
            if name == "list" { return .array([]) }
            throw BrowserScripts.Failure("the built-in browser is disabled")
        }
        guard let command = name == "eval" ? .evaluate : BrowserCommand(rawValue: name) else {
            throw BrowserScripts.Failure("unknown command browser.\(name)")
        }
        return try await handle(command: command, args: .object(args))
    }

    private func notFound(_ id: String) -> BrowserScripts.Failure {
        BrowserScripts.Failure("browser tab not found \(id)")
    }

    private func open(_ args: JSONValue, host: BrowserHost) throws -> String {
        let url: String?
        if let input = BrowserScripts.optionalString(args, "url") {
            guard let resolved = host.browserSettings.resolve(input) else { throw BrowserScripts.Failure("invalid url") }
            url = resolved
        } else {
            url = host.browserSettings.homeURL
        }
        let profile = BrowserScripts.optionalString(args, "profile")
        let profileId = try profile.map { try host.browserProfiles.resolve($0).id }
        let pane = try host.openBrowserPane(
            url: url,
            profile: profileId,
            project: BrowserScripts.optionalString(args, "project"),
            worktree: BrowserScripts.optionalString(args, "worktree"),
            split: BrowserScripts.flag(args, "split"))
        return pane.tabId
    }

    private func list(_ args: JSONValue, host: BrowserHost) throws -> JSONValue {
        let tabs = try host.browserTabs(project: BrowserScripts.optionalString(args, "project"),
                                        worktree: BrowserScripts.optionalString(args, "worktree"))
        let profiles = host.browserProfiles
        return .array(tabs.map { tab in
            let live = profiles.panes.pane(tab.tabId)
            let url = live?.page.url.isEmpty == false ? live?.page.url ?? "" : tab.state.url ?? ""
            let title = live?.pageTitle ?? BrowserAddress.displayTitle("", url: url) ?? ""
            let profile = live?.profile.name ?? profiles.profile(forSaved: tab.state.profile).name
            return .object([
                "tabId": .string(tab.tabId),
                "title": .string(title),
                "url": .string(BrowserAddress.isBlank(url) ? "" : url),
                "profile": .string(profile),
                "active": .bool(tab.active),
            ])
        })
    }

    /// The live page of the tab in `args`, loaded hidden if it was never shown.
    private func page(_ args: JSONValue, host: BrowserHost) throws -> BrowserPaneController {
        let id = try BrowserScripts.string(args, "tabId")
        guard let pane = host.browserProfiles.panes.pane(id) ?? host.browserPane(tabId: id) else { throw notFound(id) }
        guard pane.ensureWebView() != nil else { throw BrowserScripts.Failure("the built-in browser is disabled") }
        return pane
    }

    private func waitUntil(_ condition: String, pane: BrowserPaneController, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try requireOpen(pane)
            let remaining = max(deadline.timeIntervalSinceNow, BrowserScripts.pollInterval)
            if (try? await pane.run(condition, timeout: remaining)) == .bool(true) { return true }
            if Date() >= deadline { return false }
            try await Task.sleep(nanoseconds: UInt64(BrowserScripts.pollInterval * 1_000_000_000))
        }
    }

    /// Waits for the page to settle. A load that doesn't start soon counts as
    /// none, so a click that navigates can be followed by this.
    private func waitForNavigation(_ pane: BrowserPaneController, timeout: TimeInterval) async throws -> JSONValue {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        let loads = pane.page.loads
        while true {
            try requireOpen(pane)
            let waitedForStart = pane.page.loads != loads || Date().timeIntervalSince(started) >= Self.navigationStart
            if !pane.page.loading && waitedForStart { return .string(pane.page.url) }
            if Date() >= deadline { return .null }
            try await Task.sleep(nanoseconds: UInt64(BrowserScripts.pollInterval * 1_000_000_000))
        }
    }

    private func requireOpen(_ pane: BrowserPaneController) throws {
        guard let host else { throw BrowserScripts.Failure("Tab is closing") }
        guard try host.browserTabs(project: nil, worktree: nil).contains(where: { $0.tabId == pane.tabId }) else {
            throw BrowserScripts.Failure("browser tab closed")
        }
    }

    // MARK: Cookies

    private func cookies(_ command: BrowserCommand, pane: BrowserPaneController, args: JSONValue) async throws -> JSONValue {
        let store = pane.cookieStore
        switch command {
        case .cookiesGet:
            var cookies = await store.allCookies()
            if let url = BrowserScripts.optionalString(args, "url") {
                guard let address = URL(string: url), let host = address.host else { return .array([]) }
                cookies = cookies.filter { Self.cookie($0, matches: host, path: address.path, scheme: address.scheme ?? "") }
            }
            return .array(cookies.map(Self.json))
        case .cookiesSet:
            let domain = try BrowserScripts.string(args, "domain")
            guard !domain.isEmpty, BrowserAddress.host(ofURL: "https://\(domain)") != nil else {
                throw BrowserScripts.Failure("invalid cookie domain")
            }
            var expires: Date?
            switch args["expires"] {
            case .int(let seconds) where seconds >= 0: expires = Date(timeIntervalSince1970: TimeInterval(seconds))
            default: break
            }
            let cookie = ImportedCookie(
                name: try BrowserScripts.string(args, "name"), value: try BrowserScripts.string(args, "value"),
                domain: domain, path: BrowserScripts.optionalString(args, "path") ?? "/",
                secure: BrowserScripts.flag(args, "secure"), httpOnly: BrowserScripts.flag(args, "httpOnly"), expires: expires)
            guard let httpCookie = cookie.httpCookie else { throw BrowserScripts.Failure("invalid cookie") }
            await store.setCookie(httpCookie)
            return .null
        case .cookiesDelete:
            let name = try BrowserScripts.string(args, "name")
            let domain = BrowserScripts.optionalString(args, "domain")
            for cookie in await store.allCookies() where cookie.name == name {
                if let domain, cookie.domain != domain { continue }
                await store.deleteCookie(cookie)
            }
            return .null
        default:
            for cookie in await store.allCookies() { await store.deleteCookie(cookie) }
            return .null
        }
    }

    static func bareDomain(_ domain: String) -> String {
        (domain.hasPrefix(".") ? String(domain.dropFirst()) : domain).lowercased()
    }

    /// Whether a browser would send `cookie` to `host` at `path`.
    static func cookie(_ cookie: HTTPCookie, matches host: String, path: String, scheme: String = "https") -> Bool {
        if cookie.isSecure && scheme.lowercased() != "https" { return false }
        let domain = bareDomain(cookie.domain).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !domain.isEmpty else { return false }
        let domainMatches = host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        let requestPath = path.isEmpty ? "/" : path
        let pathMatches = requestPath == cookiePath
            || (requestPath.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).hasPrefix("/")))
        return domainMatches && pathMatches
    }

    static func json(_ cookie: HTTPCookie) -> JSONValue {
        .object([
            "name": .string(cookie.name),
            "value": .string(cookie.value),
            "domain": .string(cookie.domain),
            "path": .string(cookie.path),
            "secure": .bool(cookie.isSecure),
            "httpOnly": .bool(cookie.isHTTPOnly),
            "expires": cookie.expiresDate.flatMap { $0.timeIntervalSince1970 >= 0 ? .int(Int64($0.timeIntervalSince1970)) : nil } ?? .null,
        ])
    }
}
