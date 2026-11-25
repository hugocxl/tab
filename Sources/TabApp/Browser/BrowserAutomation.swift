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
            return try await screenshot(try page(args, host: host), args: args)
        case .wait:
            let condition = try BrowserScripts.condition(command, args: args)
            return .bool(try await waitUntil(condition, pane: try page(args, host: host),
                                             timeout: BrowserScripts.timeout(args, default: BrowserCommand.defaultWait)))
        case .waitFor:
            let selector = BrowserScripts.literal(try BrowserScripts.string(args, "selector"))
            return .bool(try await waitUntil(agent: "return A.find(\(selector)) !== null;", pane: try page(args, host: host),
                                             timeout: BrowserScripts.timeout(args, default: BrowserCommand.defaultWait)))
        case .waitForNavigation:
            return try await waitForNavigation(try page(args, host: host),
                                               timeout: BrowserScripts.timeout(args, default: BrowserCommand.defaultNavigationWait))
        case .cookiesGet, .cookiesSet, .cookiesDelete, .cookiesClear:
            return try await cookies(command, pane: try page(args, host: host), args: args)
        case .click, .hover, .fill, .type, .press, .select, .setChecked:
            return try await BrowserActions(pane: try page(args, host: host), args: args).run(command)
        case .snapshot:
            return try await snapshot(try page(args, host: host), args: args)
        case .dialog:
            return try dialog(try page(args, host: host), args: args)
        case .console, .errors, .network:
            return logs(command, pane: try page(args, host: host), args: args)
        case .setViewport, .setDevice, .setMedia:
            return try await emulate(command, pane: try page(args, host: host), args: args)
        default:
            let pane = try page(args, host: host)
            if let script = try BrowserScripts.agentScript(command, args: args) {
                return try await pane.agentValue(script, timeout: BrowserCommand.maxWait)
            }
            guard let script = try BrowserScripts.script(command, args: args) else {
                throw BrowserScripts.Failure("unknown command browser.\(command.rawValue)")
            }
            if let dialog = pane.agent.dialog { throw BrowserPaneController.dialogOpen(dialog) }
            return try await pane.run(script, timeout: BrowserCommand.maxWait)
        }
    }

    // MARK: Snapshots

    private func snapshot(_ pane: BrowserPaneController, args: JSONValue) async throws -> JSONValue {
        guard let script = try BrowserScripts.agentScript(.snapshot, args: args) else { return .null }
        let shot = try await pane.agentValue(script, timeout: BrowserCommand.maxWait)
        guard BrowserScripts.flag(args, "refs"), case .array(let items)? = shot["lines"] else { return shot }
        let lines = items.compactMap(\.string)
        var text = lines.joined(separator: "\n")
        if BrowserScripts.flag(args, "delta") {
            text = pane.agent.lastSnapshot.map { BrowserSnapshotDiff.diff(from: $0, to: lines) } ?? text
        }
        pane.agent.lastSnapshot = lines
        if shot["truncated"] == .bool(true) {
            text += "\n… more elements left out; narrow it with -s SELECTOR, -d DEPTH or -i"
        }
        return .object(["text": .string(text), "nodes": shot["nodes"] ?? .array([]),
                        "truncated": shot["truncated"] ?? .bool(false)])
    }

    // MARK: Screenshots

    private func screenshot(_ pane: BrowserPaneController, args: JSONValue) async throws -> JSONValue {
        var options = BrowserPaneController.ScreenshotOptions()
        if let format = BrowserScripts.optionalString(args, "format") {
            guard let value = BrowserImage.Format(rawValue: format == "jpg" ? "jpeg" : format) else {
                throw BrowserScripts.Failure("unknown format '\(format)'; use png or jpeg")
            }
            options.format = value
        }
        if case .int(let quality) = args["quality"] { options.quality = Int(min(max(quality, 1), 100)) }
        if case .int(let width) = args["maxWidth"], width > 0 { options.maxWidth = Int(min(width, 100_000)) }
        options.full = BrowserScripts.flag(args, "full")
        let annotate = BrowserScripts.flag(args, "annotate")
        var labeled: JSONValue?
        if pane.agent.dialog == nil {
            if let selector = BrowserScripts.optionalString(args, "selector") {
                let box = try await pane.agentValue("""
                const el = A.find(\(BrowserScripts.literal(selector)));
                if (!el) return null;
                el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
                return A.boxOf(el);
                """)
                guard let x = box["x"]?.number, let y = box["y"]?.number, let width = box["width"]?.number,
                      let height = box["height"]?.number
                else { throw BrowserScripts.Failure("no element matches \(selector)") }
                options.element = CGRect(x: x, y: y, width: width, height: height)
            }
            if annotate { labeled = try await pane.agentValue("return A.annotate();") }
        }
        let image: Data
        do {
            image = try await pane.screenshot(options)
        } catch {
            if annotate { _ = try? await pane.agentValue("A.clearAnnotations(); return null;") }
            throw error
        }
        if annotate { _ = try? await pane.agentValue("A.clearAnnotations(); return null;") }
        var reply: [String: JSONValue] = options.format == .png && BrowserScripts.optionalString(args, "format") == nil
            ? ["png": .string(image.base64EncodedString())]
            : ["image": .string(image.base64EncodedString()), "format": .string(options.format.rawValue)]
        if let labeled { reply["refs"] = labeled }
        return .object(reply)
    }

    // MARK: Dialogs and logs

    private func dialog(_ pane: BrowserPaneController, args: JSONValue) throws -> JSONValue {
        let action = BrowserScripts.optionalString(args, "action") ?? "status"
        guard let dialog = pane.agent.dialog else {
            if action == "status" { return .null }
            throw BrowserScripts.Failure("the page shows no dialog")
        }
        switch action {
        case "status":
            return dialog.json
        case "accept", "dismiss":
            let summary = dialog.json
            dialog.answer(accept: action == "accept", text: BrowserScripts.optionalString(args, "text"))
            pane.agent.closed(dialog)
            return summary
        default:
            throw BrowserScripts.Failure("unknown dialog action '\(action)'; use status, accept or dismiss")
        }
    }

    private func logs(_ command: BrowserCommand, pane: BrowserPaneController, args: JSONValue) -> JSONValue {
        let agent = pane.agent
        let clear = BrowserScripts.flag(args, "clear")
        func time(_ seconds: TimeInterval) -> JSONValue { .double((seconds * 1000).rounded() / 1000) }
        switch command {
        case .console:
            defer { if clear { agent.clearConsole() } }
            return .array(agent.console.map {
                .object(["level": .string($0.level), "text": .string($0.text), "url": .string($0.url), "time": time($0.time)])
            })
        case .errors:
            defer { if clear { agent.clearErrors() } }
            return .array(agent.errors.map {
                .object(["text": .string($0.text), "source": .string($0.source), "line": .int(Int64($0.line)),
                         "column": .int(Int64($0.column)), "stack": .string($0.stack), "time": time($0.time)])
            })
        default:
            defer { if clear { agent.clearRequests() } }
            let filter = BrowserScripts.optionalString(args, "filter")?.lowercased()
            return .array(agent.requests.filter { filter == nil || $0.url.lowercased().contains(filter!) }.map { request in
                var object: [String: JSONValue] = [
                    "method": .string(request.method), "url": .string(request.url), "type": .string(request.type),
                    "pending": .bool(request.pending), "time": time(request.time),
                ]
                if let status = request.status { object["status"] = .int(Int64(status)) }
                if let error = request.error { object["error"] = .string(error) }
                if let milliseconds = request.milliseconds { object["ms"] = .int(Int64(milliseconds)) }
                return .object(object)
            })
        }
    }

    // MARK: Emulation

    /// Phone and tablet sizes and user agents for `set device`.
    static let devices: [String: (width: Double, height: Double, userAgent: String?)] = [
        "iphone": (393, 852, "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"),
        "ipad": (820, 1180, "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"),
        "pixel": (412, 915, "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"),
    ]

    private func emulate(_ command: BrowserCommand, pane: BrowserPaneController, args: JSONValue) async throws -> JSONValue {
        guard let webView = pane.ensureWebView() else { throw BrowserScripts.Failure("the built-in browser is disabled") }
        switch command {
        case .setViewport:
            if BrowserScripts.flag(args, "reset") {
                pane.setViewport(nil)
                return .null
            }
            guard let width = args["width"]?.number, let height = args["height"]?.number,
                  (100 ... 10_000).contains(width), (100 ... 10_000).contains(height)
            else { throw BrowserScripts.Failure("the viewport must be 100 to 10000 pixels wide and high") }
            pane.setViewport(CGSize(width: width, height: height))
            return .null
        case .setDevice:
            let name = (try BrowserScripts.string(args, "device")).lowercased()
            let userAgent: String?
            if name == "desktop" || name == "reset" {
                pane.setViewport(nil)
                userAgent = nil
            } else {
                guard let device = Self.devices[name] else {
                    throw BrowserScripts.Failure("unknown device '\(name)'; use iphone, ipad, pixel or desktop")
                }
                pane.setViewport(CGSize(width: device.width, height: device.height))
                userAgent = device.userAgent
            }
            let current = webView.customUserAgent.flatMap { $0.isEmpty ? nil : $0 }
            let reload = current != userAgent && !BrowserAddress.isBlank(pane.page.url)
            webView.customUserAgent = userAgent
            if reload { pane.reload() }
            return .object(["width": .double(Double(webView.bounds.width / max(pane.zoom, 0.01)).rounded()),
                            "height": .double(Double(webView.bounds.height / max(pane.zoom, 0.01)).rounded()),
                            "reloaded": .bool(reload)])
        default:
            switch try BrowserScripts.string(args, "media") {
            case "dark": webView.appearance = NSAppearance(named: .darkAqua)
            case "light": webView.appearance = NSAppearance(named: .aqua)
            case "auto", "reset": webView.appearance = nil
            case let other: throw BrowserScripts.Failure("unknown media '\(other)'; use dark, light or auto")
            }
            return .null
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
            beside: BrowserScripts.optionalString(args, "beside").flatMap(SessionId.init(string:)),
            newTab: BrowserScripts.flag(args, "tab"),
            edge: BrowserScripts.optionalString(args, "edge").flatMap(Direction.init(rawValue:)),
            anchor: BrowserScripts.optionalString(args, "anchor"))
        if pane.ensureWebView() != nil { pane.beginAgentControl() }
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
                "id": .string(tab.tabId),
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
        guard try host.browserTabs(project: nil, worktree: nil).contains(where: { $0.tabId == id }) else {
            throw notFound(id)
        }
        guard let pane = host.browserProfiles.panes.pane(id) ?? host.browserPane(tabId: id) else { throw notFound(id) }
        guard pane.ensureWebView() != nil else { throw BrowserScripts.Failure("the built-in browser is disabled") }
        pane.beginAgentControl()
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
    /// Waits for a ref runtime check; errors, such as a ref not yet seen, count as not yet.
    private func waitUntil(agent condition: String, pane: BrowserPaneController, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try requireOpen(pane)
            if let dialog = pane.agent.dialog { throw BrowserPaneController.dialogOpen(dialog) }
            let remaining = max(deadline.timeIntervalSinceNow, BrowserScripts.pollInterval)
            if (try? await pane.agentValue(condition, timeout: remaining)) == .bool(true) { return true }
            if Date() >= deadline { return false }
            try await Task.sleep(nanoseconds: UInt64(BrowserScripts.pollInterval * 1_000_000_000))
        }
    }

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
