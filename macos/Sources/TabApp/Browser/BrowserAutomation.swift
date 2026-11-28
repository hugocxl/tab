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
    /// The browser each terminal or agent last named or opened, by session.
    private var current: [String: String] = [:]

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
            try navigate(pane, to: try BrowserScripts.string(args, "url"), host: host)
            return .null
        case .close:
            let id = try browserId(args, host: host)
            guard host.closeBrowserPane(tabId: id) else { throw notFound(id) }
            current = current.filter { $0.value != id }
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
            return .bool(try await wait(args, pane: try page(args, host: host)))
        case .waitFor:
            let target = try BrowserScripts.string(args, "selector")
            let pane = try page(args, host: host)
            return .bool(try await waitUntil(agent: "return A.find(\(BrowserScripts.literal(target))) !== null;", pane: pane,
                                             frame: try pane.frame(for: target),
                                             timeout: BrowserScripts.timeout(args, default: BrowserCommand.defaultWait)))
        case .waitForDownload:
            return try await waitForDownload(try page(args, host: host),
                                             timeout: BrowserScripts.timeout(args, default: BrowserCommand.defaultNavigationWait))
        case .downloads:
            let pane = try page(args, host: host)
            defer { if BrowserScripts.flag(args, "clear") { pane.agent.clearDownloads() } }
            return .array(pane.agent.downloads.map(Self.json))
        case .stateSave:
            return try await saveState(try page(args, host: host))
        case .stateLoad:
            return try await loadState(try page(args, host: host), args: args)
        case .getBox:
            let target = try BrowserScripts.string(args, "selector")
            let pane = try page(args, host: host)
            let frame = try pane.frame(for: target)
            let box = try await pane.agentValue("const el = A.find(\(BrowserScripts.literal(target))); return el ? A.boxOf(el) : null;",
                                                in: frame)
            guard frame != nil, case .object(var fields) = box else { return box }
            let offset = try await pane.offset(of: frame)
            fields["x"] = .double((fields["x"]?.number ?? 0) + offset.x)
            fields["y"] = .double((fields["y"]?.number ?? 0) + offset.y)
            return .object(fields)
        case .waitForNavigation:
            return try await waitForNavigation(try page(args, host: host),
                                               timeout: BrowserScripts.timeout(args, default: BrowserCommand.defaultNavigationWait))
        case .cookiesGet, .cookiesSet, .cookiesDelete, .cookiesClear:
            return try await cookies(command, pane: try page(args, host: host), args: args)
        case .click, .hover, .fill, .type, .press, .select, .setChecked, .upload, .scroll:
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
                return try await pane.agentValue(script, timeout: BrowserCommand.maxWait,
                                                 in: try pane.frame(for: BrowserScripts.optionalString(args, "selector")))
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
        guard BrowserScripts.flag(args, "refs") else {
            guard let script = try BrowserScripts.agentScript(.snapshot, args: args) else { return .null }
            return try await pane.agentValue(script, timeout: BrowserCommand.maxWait)
        }
        if BrowserScripts.flag(args, "settle") { await pane.settle(timeout: BrowserActions.settleTime) }
        let shot = try await pane.snapshot(BrowserScripts.snapshotOptions(args),
                                           in: try pane.frame(for: BrowserScripts.optionalString(args, "selector")))
        var text = shot.lines.joined(separator: "\n")
        if BrowserScripts.flag(args, "delta") {
            text = pane.agent.lastSnapshot.map { BrowserSnapshotDiff.diff(from: $0, to: shot.lines) } ?? text
        }
        pane.agent.lastSnapshot = shot.lines
        if shot.truncated {
            text += "\n… more elements left out; narrow it with -s SELECTOR, -d DEPTH or -i"
        }
        return .object(["text": .string(text), "nodes": .array(shot.nodes), "truncated": .bool(shot.truncated)])
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
                let frame = try pane.frame(for: selector)
                let box = try await pane.agentValue("""
                const el = A.find(\(BrowserScripts.literal(selector)));
                if (!el) return null;
                el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
                return A.boxOf(el);
                """, in: frame)
                guard let x = box["x"]?.number, let y = box["y"]?.number, let width = box["width"]?.number,
                      let height = box["height"]?.number
                else { throw BrowserScripts.Failure("no element matches \(selector)") }
                let offset = frame == nil ? (x: 0.0, y: 0.0, viewport: nil) : try await pane.offset(of: frame)
                options.element = CGRect(x: x + offset.x, y: y + offset.y, width: width, height: height)
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
            func summary(_ request: BrowserAgentState.RequestEntry) -> [String: JSONValue] {
                var object: [String: JSONValue] = [
                    "id": .int(Int64(request.number)), "method": .string(request.method), "url": .string(request.url),
                    "type": .string(request.type), "pending": .bool(request.pending), "time": time(request.time),
                ]
                if let status = request.status { object["status"] = .int(Int64(status)) }
                if let error = request.error { object["error"] = .string(error) }
                if let milliseconds = request.milliseconds { object["ms"] = .int(Int64(milliseconds)) }
                return object
            }
            if let number = args["id"]?.number {
                guard let request = agent.requests.first(where: { Double($0.number) == number }) else {
                    return .null
                }
                var object = summary(request)
                object["requestHeaders"] = .object(request.requestHeaders.mapValues(JSONValue.string))
                object["responseHeaders"] = .object(request.responseHeaders.mapValues(JSONValue.string))
                if let body = request.requestBody { object["requestBody"] = .string(body) }
                if let body = request.responseBody { object["responseBody"] = .string(body) }
                if let type = request.responseType { object["contentType"] = .string(type) }
                return .object(object)
            }
            defer { if clear { agent.clearRequests() } }
            let filter = BrowserScripts.optionalString(args, "filter")?.lowercased()
            let method = BrowserScripts.optionalString(args, "method")?.uppercased()
            let type = BrowserScripts.optionalString(args, "type")?.lowercased()
            let status = BrowserScripts.optionalString(args, "status")
            return .array(agent.requests.filter { request in
                (filter.map { request.url.lowercased().contains($0) } ?? true)
                    && (method.map { request.method == $0 } ?? true)
                    && (type.map { request.type == $0 } ?? true)
                    && (status.map { Self.status(request, matches: $0) } ?? true)
            }.map { .object(summary($0)) })
        }
    }

    /// Whether a request's status is `pattern`: `404`, or a class such as `4xx`.
    static func status(_ request: BrowserAgentState.RequestEntry, matches pattern: String) -> Bool {
        guard let status = request.status else { return false }
        let pattern = pattern.lowercased()
        if pattern.count == 3, pattern.hasSuffix("xx"), let first = pattern.first?.wholeNumberValue {
            return status / 100 == first
        }
        return Int(pattern) == status
    }

    static func json(_ download: BrowserAgentState.DownloadEntry) -> JSONValue {
        var object: [String: JSONValue] = ["id": .int(Int64(download.id)), "url": .string(download.url),
                                           "state": .string(download.state),
                                           "time": .double((download.time * 1000).rounded() / 1000)]
        if let path = download.path { object["path"] = .string(path) }
        if let error = download.error { object["error"] = .string(error) }
        return .object(object)
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
        if BrowserScripts.flag(args, "reuse"), let id = try? browserId(args, host: host, mineOnly: true),
           let pane = host.browserProfiles.panes.pane(id) ?? host.browserPane(tabId: id), pane.ensureWebView() != nil {
            pane.beginAgentControl()
            if let url = BrowserScripts.optionalString(args, "url") { try navigate(pane, to: url, host: host) }
            return id
        }
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
        if let caller = BrowserScripts.optionalString(args, "caller") ?? BrowserScripts.optionalString(args, "beside") {
            current[caller] = pane.tabId
        }
        return pane.tabId
    }

    private func navigate(_ pane: BrowserPaneController, to input: String, host: BrowserHost) throws {
        guard let url = host.browserSettings.resolve(input) else { throw BrowserScripts.Failure("invalid url") }
        host.browserPane(pane, didChange: BrowserPane(url: url, profile: pane.profile.id))
        pane.load(url)
    }

    /// The browser a command names, else the caller's: the one it last named
    /// or opened, else the only one in its tab, else the only one there is.
    /// `mineOnly` stops before that last step, so `open` never takes over a
    /// browser of the user's elsewhere.
    private func browserId(_ args: JSONValue, host: BrowserHost, mineOnly: Bool = false) throws -> String {
        let caller = BrowserScripts.optionalString(args, "caller")
        if let id = BrowserScripts.optionalString(args, "tabId") {
            if let caller { current[caller] = id }
            return id
        }
        let tabs = try host.browserTabs(project: nil, worktree: nil)
        if let caller, let id = current[caller], tabs.contains(where: { $0.tabId == id }) { return id }
        var candidates = caller.flatMap(SessionId.init(string:)).map(host.browserTabs(near:)) ?? []
        if candidates.isEmpty, !mineOnly { candidates = tabs.map(\.tabId) }
        guard candidates.count == 1, let id = candidates.first else {
            if mineOnly { throw BrowserScripts.Failure("the caller has no browser") }
            guard !candidates.isEmpty else {
                throw BrowserScripts.Failure("no browser to drive; open one with tab browser open URL")
            }
            let named = candidates.prefix(5).map { id in
                let url = tabs.first { $0.tabId == id }?.state.url ?? ""
                return url.isEmpty ? id : "\(id) (\(url))"
            }
            throw BrowserScripts.Failure("\(candidates.count) browsers are open; name one: " + named.joined(separator: ", ")
                + (candidates.count > 5 ? ", … (tab browser list shows all)" : ""))
        }
        if let caller { current[caller] = id }
        return id
    }

    private func list(_ args: JSONValue, host: BrowserHost) throws -> JSONValue {
        let tabs = try host.browserTabs(project: BrowserScripts.optionalString(args, "project"),
                                        worktree: BrowserScripts.optionalString(args, "worktree"))
        let profiles = host.browserProfiles
        let mine = BrowserScripts.optionalString(args, "caller").flatMap { current[$0] }
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
                "current": .bool(tab.tabId == mine),
            ])
        })
    }

    /// The live page of the tab in `args`, loaded hidden if it was never shown.
    private func page(_ args: JSONValue, host: BrowserHost) throws -> BrowserPaneController {
        let id = try browserId(args, host: host)
        guard try host.browserTabs(project: nil, worktree: nil).contains(where: { $0.tabId == id }) else {
            throw notFound(id)
        }
        guard let pane = host.browserProfiles.panes.pane(id) ?? host.browserPane(tabId: id) else { throw notFound(id) }
        guard pane.ensureWebView() != nil else { throw BrowserScripts.Failure("the built-in browser is disabled") }
        pane.beginAgentControl()
        return pane
    }

    /// How long the network must be quiet for `wait --load networkidle`.
    static let networkIdle: TimeInterval = 0.5

    /// Waits until every condition `wait` was given holds.
    private func wait(_ args: JSONValue, pane: BrowserPaneController) async throws -> Bool {
        let checks = BrowserScripts.waitChecks(args)
        let load = BrowserScripts.optionalString(args, "load")
        guard load == nil || ["load", "networkidle"].contains(load!) else {
            throw BrowserScripts.Failure("unknown load state '\(load!)'; use load or networkidle")
        }
        let frame = try pane.frame(for: BrowserScripts.optionalString(args, "selector"))
        let deadline = Date().addingTimeInterval(BrowserScripts.timeout(args, default: BrowserCommand.defaultWait))
        var idleSince: Date?
        // A load that a click just caused may take a moment to start.
        let loads = pane.page.loads
        let started = Date()
        while true {
            try requireOpen(pane)
            if let dialog = pane.agent.dialog { throw BrowserPaneController.dialogOpen(dialog) }
            var holds = true
            if let load {
                let begun = pane.page.loads != loads || Date().timeIntervalSince(started) >= Self.navigationStart
                if !begun || pane.page.loading || load == "networkidle" && pane.agent.pendingRequests > 0 {
                    idleSince = nil
                    holds = false
                } else if load == "networkidle" {
                    idleSince = idleSince ?? Date()
                    holds = Date().timeIntervalSince(idleSince!) >= Self.networkIdle
                }
            }
            let remaining = max(deadline.timeIntervalSinceNow, BrowserScripts.pollInterval)
            if holds, let check = checks.agent {
                holds = (try? await pane.agentValue(check, timeout: remaining, in: frame)) == .bool(true)
            }
            if holds, let check = checks.page {
                holds = (try? await pane.run(check, timeout: remaining)) == .bool(true)
            }
            if holds { return true }
            if Date() >= deadline { return false }
            try await Task.sleep(nanoseconds: UInt64(BrowserScripts.pollInterval * 1_000_000_000))
        }
    }

    /// Waits for a ref runtime check; errors, such as a ref not yet seen, count as not yet.
    private func waitUntil(agent condition: String, pane: BrowserPaneController, frame: BrowserAgentState.AgentFrame?,
                           timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try requireOpen(pane)
            if let dialog = pane.agent.dialog { throw BrowserPaneController.dialogOpen(dialog) }
            let remaining = max(deadline.timeIntervalSinceNow, BrowserScripts.pollInterval)
            if (try? await pane.agentValue(condition, timeout: remaining, in: frame)) == .bool(true) { return true }
            if Date() >= deadline { return false }
            try await Task.sleep(nanoseconds: UInt64(BrowserScripts.pollInterval * 1_000_000_000))
        }
    }

    /// Waits for a download that is running or starts within `timeout` to finish.
    private func waitForDownload(_ pane: BrowserPaneController, timeout: TimeInterval) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        let known = Set(pane.agent.downloads.filter { $0.state != "downloading" }.map(\.id))
        while true {
            try requireOpen(pane)
            if let finished = pane.agent.downloads.first(where: { !known.contains($0.id) && $0.state != "downloading" }) {
                return Self.json(finished)
            }
            if Date() >= deadline { return .null }
            try await Task.sleep(nanoseconds: UInt64(BrowserScripts.pollInterval * 1_000_000_000))
        }
    }

    // MARK: Saved state

    /// The profile's cookies and the page's local storage, for `state.load`
    /// to sign another browser in.
    private func saveState(_ pane: BrowserPaneController) async throws -> JSONValue {
        let cookies = await pane.cookieStore.allCookies()
        let storage = try await pane.run("""
        let items = {};
        try { for (let index = 0; index < localStorage.length; index++) { const key = localStorage.key(index); items[key] = localStorage.getItem(key); } }
        catch (error) { items = null; }
        return { origin: location.origin, items };
        """)
        var origins: [JSONValue] = []
        if let origin = storage["origin"]?.string, origin != "null", case .object(let items)? = storage["items"] {
            origins.append(.object(["origin": .string(origin), "localStorage": .object(items)]))
        }
        return .object(["version": .int(1), "url": .string(pane.page.url), "cookies": .array(cookies.map(Self.json)),
                        "origins": .array(origins)])
    }

    private func loadState(_ pane: BrowserPaneController, args: JSONValue) async throws -> JSONValue {
        guard let state = args["state"], case .array(let cookies)? = state["cookies"] else {
            throw BrowserScripts.Failure("the file isn't a saved browser state; make one with tab browser state save FILE")
        }
        var set = 0
        for cookie in cookies {
            guard let name = cookie["name"]?.string, let value = cookie["value"]?.string,
                  let domain = cookie["domain"]?.string else { continue }
            let expires = cookie["expires"]?.number.map { Date(timeIntervalSince1970: $0) }
            let imported = ImportedCookie(name: name, value: value, domain: domain, path: cookie["path"]?.string ?? "/",
                                          secure: cookie["secure"] == .bool(true), httpOnly: cookie["httpOnly"] == .bool(true),
                                          expires: expires)
            guard let httpCookie = imported.httpCookie else { continue }
            await pane.cookieStore.setCookie(httpCookie)
            set += 1
        }
        var stored = 0
        var skipped: [JSONValue] = []
        if case .array(let origins)? = state["origins"] {
            let here = try await pane.run("return location.origin;").string
            for entry in origins {
                guard let origin = entry["origin"]?.string, case .object(let items)? = entry["localStorage"] else { continue }
                guard origin == here else {
                    skipped.append(.string(origin))
                    continue
                }
                let pairs = items.compactMapValues(\.string)
                _ = try await pane.run("""
                const items = \(JSONValue.object(pairs.mapValues(JSONValue.string)).description);
                for (const key of Object.keys(items)) localStorage.setItem(key, items[key]);
                return null;
                """)
                stored += pairs.count
            }
        }
        return .object(["cookies": .int(Int64(set)), "localStorage": .int(Int64(stored)), "skipped": .array(skipped)])
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
