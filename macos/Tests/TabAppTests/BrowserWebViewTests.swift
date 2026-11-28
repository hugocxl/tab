import AppKit
import TabClient
import TabCore
import WebKit
import XCTest
@testable import TabApp

/// Production forbids file navigation. Fixtures alone allow files within
/// their temporary folder, forwarding the real load events to the pane.
@MainActor
final class BrowserFixtureNavigation: NSObject, WKNavigationDelegate {
    weak var pane: BrowserPaneController?
    let folder: URL

    init(pane: BrowserPaneController, folder: URL) {
        self.pane = pane
        self.folder = folder.resolvingSymlinksInPath()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if let url = action.request.url, url.isFileURL {
            return (url.resolvingSymlinksInPath().path.hasPrefix(folder.path + "/") ? .allow : .cancel, preferences)
        }
        guard let pane else { return (.cancel, preferences) }
        return await pane.webView(webView, decidePolicyFor: action, preferences: preferences)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        pane?.webView(webView, didStartProvisionalNavigation: navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        pane?.webView(webView, didFinish: navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        pane?.webView(webView, didFail: navigation, withError: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        pane?.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
}

@MainActor
final class BrowserWebViewTests: XCTestCase {
    private var folder: URL!
    private var host: TestBrowserHost!
    private var automation: BrowserAutomation!
    private var navigations: [BrowserFixtureNavigation] = []

    override func setUp() async throws {
        folder = URL(fileURLWithPath: "/tmp/tab-browser-test").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        host = TestBrowserHost(root: folder.appendingPathComponent("profiles"))
        automation = BrowserAutomation(host: host)
    }

    override func tearDown() async throws {
        let profiles = host.browserProfiles.profiles.filter { !$0.isBuiltInDefault }
        host.panes.removeAll()
        navigations.removeAll()
        host.browserProfiles.defaultProfileId = ""
        for profile in profiles { try await host.browserProfiles.delete(profile.id) }
        host = nil
        automation = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func command(_ name: String, _ id: String? = nil, _ args: [String: JSONValue] = [:]) async throws -> JSONValue {
        var args = args
        if let id { args["tabId"] = .string(id) }
        return try await automation.handle(command: "browser." + name, args: args)
    }

    private func expect(_ value: JSONValue, _ expected: JSONValue,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value, expected, file: file, line: line)
    }

    /// An action that worked: `true`, or an object saying how.
    private func expectDone(_ value: JSONValue, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value == .bool(true) || value["ok"] == .bool(true), "\(value)", file: file, line: line)
        XCTAssertNil(value["warning"], "\(value)", file: file, line: line)
    }

    private func fixture(_ name: String, _ html: String, profile: String? = nil) async throws -> BrowserPaneController {
        let file = folder.appendingPathComponent(name + ".html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        var args: [String: JSONValue] = [:]
        if let profile { args["profile"] = .string(profile) }
        let opened = try await command("open", nil, args)
        let id = try XCTUnwrap(opened.string)
        let pane = try XCTUnwrap(host.panes[id])
        let webView = try XCTUnwrap(pane.ensureWebView())
        pane.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertNil(webView.window)
        let navigation = BrowserFixtureNavigation(pane: pane, folder: folder)
        navigations.append(navigation)
        webView.navigationDelegate = navigation
        webView.loadFileURL(file, allowingReadAccessTo: folder)
        try await loaded(pane, at: file.absoluteString)
        return pane
    }

    private func loaded(_ pane: BrowserPaneController, at url: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if pane.page.url == url, !pane.page.loading, pane.page.loads > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard pane.page.url == url else {
            throw BrowserScripts.Failure("WebKit did not load the file fixture in this environment")
        }
        XCTAssertFalse(pane.page.loading)
        XCTAssertNil(pane.page.error)
        let title = try await command("read", pane.tabId)
        XCTAssertEqual(title["url"], .string(url))
    }

    func testEveryPageCommandAndOutputShapes() async throws {
        let pane = try await fixture("form", """
        <html><head><title>Form Fixture</title></head><body>
        <h1>Welcome</h1><form onsubmit="event.preventDefault(); document.querySelector('#out').textContent = 'Submitted';">
        <label for="query">Query</label><input id="query" placeholder="Search" data-testid="query">
        <textarea id="notes"></textarea><div id="editable" contenteditable="true">Old</div>
        <select id="choice"><option value="a">A</option><option value="b">B</option></select>
        <input type="checkbox" id="check"><input disabled id="disabled"><input hidden id="hidden">
        <button id="go" type="submit">Submit</button></form>
        <p id="out">Initial</p><button id="hover" onmouseenter="this.textContent='Hovered'">Hover</button>
        <a href="#end" data-testid="anchor">End</a>
        </body></html>
        """)
        let id = pane.tabId
        let read = try await command("read", id)
        XCTAssertEqual(read["title"], .string("Form Fixture"))
        XCTAssertTrue(read["text"]?.string?.contains("Welcome") == true)
        try await expectDone(command("fill", id, ["selector": .string("#query"), "text": .string("a'\"b\n😀")]))
        try await expect(command("getValue", id, ["selector": .string("#query")]), .string("a'\"b😀"))
        try await expectDone(command("type", id, ["selector": .string("#query"), "text": .string("New"), "submit": .bool(true)]))
        try await expect(command("getText", id, ["selector": .string("#out")]), .string("Submitted"))
        try await expectDone(command("fill", id, ["selector": .string("#notes"), "text": .string("Two\nlines")]))
        try await expect(command("getValue", id, ["selector": .string("#notes")]), .string("Two\nlines"))
        try await expectDone(command("fill", id, ["selector": .string("#editable"), "text": .string("Edited")]))
        try await expect(command("getText", id, ["selector": .string("#editable")]), .string("Edited"))
        try await expectDone(command("select", id, ["selector": .string("#choice"), "value": .string("b")]))
        try await expect(command("getValue", id, ["selector": .string("#choice")]), .string("b"))
        try await expectDone(command("setChecked", id, ["selector": .string("#check"), "checked": .bool(true)]))
        for (property, selector) in [("checked", "#check"), ("disabled", "#disabled"), ("hidden", "#hidden"), ("enabled", "#query"), ("visible", "#query")] {
            try await expect(command("is", id, ["selector": .string(selector), "property": .string(property)]), .bool(true))
        }
        try await expectDone(command("press", id, ["selector": .string("#query"), "key": .string("Enter")]))
        try await expectDone(command("hover", id, ["selector": .string("#hover")]))
        try await expect(command("getText", id, ["selector": .string("#hover")]), .string("Hovered"))
        try await expect(command("scrollIntoView", id, ["selector": .string("#go")]), .bool(true))
        try await expect(command("getAttribute", id, ["selector": .string("#query"), "attribute": .string("placeholder")]), .string("Search"))
        try await expect(command("getCount", id, ["selector": .string("form")]), .int(1))
        let html = try await command("getHTML", id, ["selector": .string("h1")])
        XCTAssertEqual(html, .string("<h1>Welcome</h1>"))
        let fullHTML = try await command("getHTML", id)
        XCTAssertTrue(fullHTML.string?.contains("<html>") == true)
        let snapshot = try await command("snapshot", id)
        guard case .array(let elements) = snapshot else { return XCTFail("snapshot is not an array") }
        XCTAssertTrue(elements.contains { $0["selector"] == .string("#go") })
        XCTAssertFalse(elements.contains { $0["selector"] == .string("#hidden") })
        for element in elements {
            XCTAssertEqual(element["visible"], .bool(true))
            XCTAssertNotNil(element["role"])
            XCTAssertNotNil(element["name"])
            let selector = try XCTUnwrap(element["selector"])
            try await expect(command("getCount", id, ["selector": selector]), .int(1))
        }
        for (kind, value) in [("role", "button"), ("label", "Query"), ("text", "Welcome"), ("placeholder", "Search"), ("testid", "query")] {
            guard case .array(let found) = try await command("find", id, ["kind": .string(kind), "value": .string(value)]) else {
                return XCTFail("find is not an array")
            }
            XCTAssertFalse(found.isEmpty, kind)
            XCTAssertNotNil(found.first?["selector"])
        }
        for kind in ["local", "session"] {
            try await expect(command("storage.set", id, ["key": .string("k"), "value": .string("v"), "kind": .string(kind)]), .null)
            try await expect(command("storage.get", id, ["key": .string("k"), "kind": .string(kind)]), .string("v"))
            try await expect(command("storage.clear", id, ["kind": .string(kind)]), .null)
            try await expect(command("storage.get", id, ["key": .string("k"), "kind": .string(kind)]), .null)
        }
        try await expect(command("eval", id, ["script": .string("Promise.resolve({answer: 42})")]), .object(["answer": .int(42)]))
        try await expect(command("eval", id, ["script": .string("const x = 4; return x * 2;")]), .int(8))
        let listing = try await command("list")
        guard case .array(let tabs) = listing else { return XCTFail("list is not an array") }
        XCTAssertEqual(tabs, [.object(["id": .string(id), "title": .string("Form Fixture"), "url": .string(pane.page.url), "profile": .string("Default"), "active": .bool(true), "current": .bool(false)])])
        let screenshot = try await command("screenshot", id)
        let png = try XCTUnwrap(screenshot["png"]?.string.flatMap { Data(base64Encoded: $0) })
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertGreaterThan(image.pixelsWide, 0)
        XCTAssertGreaterThan(image.pixelsHigh, 0)
        try await expect(command("close", id), .null)
        do {
            _ = try await command("read", id)
            XCTFail("read accepted a closed tab")
        } catch { XCTAssertEqual(error.localizedDescription, "browser tab not found \(id)") }
    }

    func testDelayedNavigationBackForwardReloadAndWaits() async throws {
        let destination = folder.appendingPathComponent("destination.html")
        try "<html><head><title>Destination</title></head><body>Arrived</body></html>".write(to: destination, atomically: true, encoding: .utf8)
        let pane = try await fixture("navigation", """
        <html><body><button id="go" onclick="setTimeout(() => location.href='destination.html', 200)">Go</button>
        <script>setTimeout(() => { const p = document.createElement('p'); p.id='late'; p.textContent='Ready'; document.body.appendChild(p); }, 200);</script>
        </body></html>
        """)
        let id = pane.tabId
        let original = pane.page.url
        try await expect(command("waitFor", id, ["selector": .string("#late"), "timeoutMs": .int(3000)]), .bool(true))
        for args: [String: JSONValue] in [["text": .string("Ready")], ["urlContains": .string("navigation.html")], ["function": .string("document.querySelector('#late') !== null")]] {
            try await expect(command("wait", id, args), .bool(true))
        }
        try await expect(command("wait", id, ["function": .string("throw new Error('ignored')"), "timeoutMs": .int(100)]), .bool(false))
        try await expect(command("waitForNavigation", id, ["timeoutMs": .int(0)]), .null)
        try await expectDone(command("click", id, ["selector": .string("#go")]))
        try await expect(command("waitForNavigation", id, ["timeoutMs": .int(5000)]), .string(destination.absoluteString))
        try await loaded(pane, at: destination.absoluteString)
        try await expect(command("back", id), .null)
        try await loaded(pane, at: original)
        try await expect(command("forward", id), .null)
        try await loaded(pane, at: destination.absoluteString)
        let loads = pane.page.loads
        try await expect(command("reload", id), .null)
        _ = try await command("waitForNavigation", id, ["timeoutMs": .int(3000)])
        XCTAssertGreaterThan(pane.page.loads, loads)
        try await expect(command("navigate", id, ["url": .string("about:blank")]), .null)
        try await loaded(pane, at: "about:blank")
        XCTAssertNil(host.saved[id]?.url)
    }

    func testWaitReportsTabClosed() async throws {
        let pane = try await fixture("closing", "<html><body>Closing</body></html>")
        let id = pane.tabId
        let wait = Task { try await command("wait", id, ["selector": .string("#never"), "timeoutMs": .int(5000)]) }
        try await Task.sleep(for: .milliseconds(150))
        _ = try await command("close", id)
        do {
            _ = try await wait.value
            XCTFail("wait succeeded after close")
        } catch { XCTAssertEqual(error.localizedDescription, "browser tab closed") }
    }

    func testProfilesIsolateCookiesSiteDataHistoryAndSavedState() async throws {
        let work = try host.browserProfiles.add(named: "Work")
        let other = try host.browserProfiles.add(named: "Other")
        host.browserProfiles.defaultProfileId = work.id
        let first = try await fixture("work", "<html><body>Work</body></html>")
        let second = try await fixture("other", "<html><body>Other</body></html>", profile: other.id)
        XCTAssertEqual(first.profile, work)
        XCTAssertFalse(first.cookieStore === second.cookieStore)
        XCTAssertFalse(first.webView?.configuration.websiteDataStore === second.webView?.configuration.websiteDataStore)
        try await expect(command("cookies.set", first.tabId, ["name": .string("sid"), "value": .string("secret"), "domain": .string("example.test"), "httpOnly": .bool(true), "secure": .bool(true)]), .null)
        let cookies = try await command("cookies.get", first.tabId)
        guard case .array(let written) = cookies else { return XCTFail("cookies are not an array") }
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0]["value"], .string("secret"))
        XCTAssertEqual(written[0]["httpOnly"], .bool(true))
        try await expect(command("cookies.get", second.tabId), .array([]))
        try await expect(command("storage.set", first.tabId, ["key": .string("secret"), "value": .string("work")]), .null)
        try await expect(command("storage.get", second.tabId, ["key": .string("secret")]), .null)
        host.browserProfiles.history(for: work).recordVisit(url: "https://example.test/", title: "Work History")
        host.browserProfiles.saveHistories()
        let restored = BrowserProfiles(root: host.browserProfiles.root)
        XCTAssertEqual(restored.history(for: work).entries.count, 1)
        XCTAssertTrue(restored.history(for: other).entries.isEmpty)
        let saved = try XCTUnwrap(host.saved[first.tabId])
        let state = try JSONDecoder().decode(BrowserPane.self, from: JSONEncoder().encode(saved))
        let reopened = BrowserPaneController(tabId: "restored", state: state, host: host)
        XCTAssertEqual(reopened.profile, work)
        XCTAssertEqual(reopened.state.url, first.page.url)
        XCTAssertEqual(reopened.zoom, 1)
        let restoredCookies = await restored.dataStore(for: work).httpCookieStore.allCookies()
        XCTAssertEqual(restoredCookies.first { $0.name == "sid" }?.value, "secret")
        try await expect(command("cookies.delete", first.tabId, ["name": .string("sid"), "domain": .string("example.test")]), .null)
        try await expect(command("cookies.get", first.tabId), .array([]))
        try await expect(command("cookies.set", second.tabId, ["name": .string("keep"), "value": .string("other"), "domain": .string("example.test")]), .null)
        try await expect(command("cookies.clear", first.tabId), .null)
        guard case .array(let kept) = try await command("cookies.get", second.tabId) else { return XCTFail("cookies are not an array") }
        XCTAssertEqual(kept.count, 1)
        try await host.browserProfiles.clearData(work.id)
        XCTAssertTrue(host.browserProfiles.history(for: work).entries.isEmpty)
        guard case .array(let stillKept) = try await command("cookies.get", second.tabId) else { return XCTFail("cookies are not an array") }
        XCTAssertEqual(stillKept.count, 1)
        _ = try await command("navigate", first.tabId, ["url": .string("about:blank")])
        try await loaded(first, at: "about:blank")
        first.switchProfile(to: other)
        XCTAssertEqual(host.saved[first.tabId]?.profile, other.id)
        XCTAssertTrue(first.cookieStore === second.cookieStore)
    }

    func testOpenUsesHomePageAndEvalWireName() async throws {
        host.browserSettings.homePage = "https://home.example.test/start"
        let opened = try await command("open")
        let id = try XCTUnwrap(opened.string)
        XCTAssertEqual(host.panes[id]?.state.url, "https://home.example.test/start")
        let pane = try XCTUnwrap(host.panes[id])
        XCTAssertTrue(pane.perform(.browserZoomIn))
        XCTAssertEqual(pane.zoom, 1.1, accuracy: 0.0001)
        XCTAssertTrue(pane.perform(.browserZoomReset))
        XCTAssertEqual(pane.zoom, 1)
        XCTAssertFalse(pane.perform(.newBrowserPane))
        do {
            _ = try await command("eval", id)
            XCTFail("eval ran without a script")
        } catch { XCTAssertEqual(error.localizedDescription, "missing argument 'script'") }
        host.browserSettings.enabled = false
        do {
            _ = try await command("unknown")
            XCTFail("disabled browser accepted an unknown command")
        } catch { XCTAssertEqual(error.localizedDescription, "the built-in browser is disabled") }
    }

    func testPopupShortcutsHomePageAndDisabledState() async throws {
        host.browserSettings.homePage = "about:blank"
        let pane = try await fixture("popup", "<html><body>Popup <button id='popup' onclick=\"window.open('https://popup.example.test/path', '_blank')\">Open</button></body></html>")
        try await expectDone(command("click", pane.tabId, ["selector": .string("#popup")]))
        let deadline = Date().addingTimeInterval(3)
        while host.opened.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(host.opened, ["https://popup.example.test/path"])
        XCTAssertEqual(host.popupProfiles, [pane.profile.id])
        XCTAssertEqual(pane.webView?.isInspectable, true)
        func key(_ character: String, _ modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: character,
                                           charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0))
        }
        XCTAssertTrue(try pane.handleKeyEquivalent(key("l")))
        XCTAssertTrue(try pane.handleKeyEquivalent(key("f")))
        XCTAssertTrue(pane.findVisible)
        pane.pageEscape()
        XCTAssertFalse(pane.findVisible)
        XCTAssertTrue(try pane.handleKeyEquivalent(key("=")))
        XCTAssertEqual(pane.zoom, 1.1, accuracy: 0.0001)
        XCTAssertEqual(pane.webView?.pageZoom, CGFloat(pane.zoom))
        XCTAssertTrue(try pane.handleKeyEquivalent(key("-")))
        XCTAssertTrue(try pane.handleKeyEquivalent(key("0")))
        XCTAssertEqual(pane.zoom, 1)
        XCTAssertTrue(try pane.handleKeyEquivalent(key("c", [.command, .shift])))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), pane.page.url)
        _ = try await command("navigate", pane.tabId, ["url": .string("about:blank")])
        try await loaded(pane, at: "about:blank")
        let before = pane.state
        pane.apply(settings: BrowserSettings(enabled: false))
        XCTAssertNil(pane.webView)
        XCTAssertEqual(pane.state, before)
        pane.apply(settings: BrowserSettings(enabled: true))
        XCTAssertNotNil(pane.webView)
        host.browserSettings.enabled = false
        try await expect(command("list"), .array([]))
        for command in ["open", "read", "close", "eval", "navigate"] {
            do {
                _ = try await self.command(command, pane.tabId)
                XCTFail("disabled browser accepted \(command)")
            } catch { XCTAssertEqual(error.localizedDescription, "the built-in browser is disabled") }
        }
    }

    // MARK: Agents

    private func failure(_ name: String, _ id: String?, _ args: [String: JSONValue],
                         file: StaticString = #filePath, line: UInt = #line) async -> String {
        do {
            let value = try await command(name, id, args)
            XCTFail("\(name) succeeded with \(value)", file: file, line: line)
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    private func refs(_ snapshot: JSONValue) -> [String: String] {
        guard case .array(let nodes)? = snapshot["nodes"] else { return [:] }
        var refs: [String: String] = [:]
        for node in nodes {
            guard let name = node["name"]?.string, let ref = node["ref"]?.string, refs[name] == nil else { continue }
            refs[name] = "@" + ref
        }
        return refs
    }

    func testRefSnapshotsReachFramesAndShadowRootsAndRefsGoStale() async throws {
        let pane = try await fixture("refs", """
        <html><head><title>Refs</title></head><body>
        <h1>Shop</h1><nav><a href="#cart">Cart</a></nav>
        <label for="q">Query</label><input id="q" value="old">
        <button id="send" onclick="document.querySelector('#out').textContent = 'Sent'">Send</button>
        <button id="off" disabled>Off</button>
        <div style="position: relative"><button id="under">Under</button>
        <div id="cover" style="position: absolute; inset: 0; background: white"></div></div>
        <input type="checkbox" id="agree" aria-label="Agree" checked>
        <div id="host"></div><p id="out">Idle</p><p style="display: none"><button>Hidden</button></p>
        <iframe id="frame" srcdoc="<button onclick='parent.document.querySelector(&quot;#out&quot;).textContent = &quot;Inner&quot;'>Inner</button>"></iframe>
        <script>document.querySelector('#host').attachShadow({ mode: 'open' }).innerHTML = '<button>Shadow</button>';</script>
        </body></html>
        """)
        let id = pane.tabId
        try await Task.sleep(for: .milliseconds(200))
        let full = try await command("snapshot", id, ["refs": .bool(true)])
        let text = try XCTUnwrap(full["text"]?.string)
        for line in [#"[heading] "Shop" [level=1]"#, #"[link] "Cart""#, #"[textbox] "Query" value="old""#,
                     #"[button] "Off" [disabled]"#, #"[checkbox] "Agree" [checked]"#, #"[button] "Shadow""#,
                     #"[button] "Inner""#, #"text "Idle""#] {
            XCTAssertTrue(text.contains(line), "\(line) missing from\n\(text)")
        }
        XCTAssertFalse(text.contains("Hidden"), text)
        XCTAssertTrue(text.contains("\n  @"), "the full snapshot is indented:\n\(text)")
        let interactive = try await command("snapshot", id, ["refs": .bool(true), "interactive": .bool(true)])
        let interactiveText = try XCTUnwrap(interactive["text"]?.string)
        XCTAssertFalse(interactiveText.contains("[heading]"))
        XCTAssertFalse(interactiveText.contains("text "))
        XCTAssertFalse(interactiveText.contains("\n "))
        let scoped = try await command("snapshot", id, ["refs": .bool(true), "selector": .string("nav")])
        XCTAssertEqual(scoped["text"]?.string?.split(separator: "\n").count, 2, "\(scoped)")
        let urls = try await command("snapshot", id, ["refs": .bool(true), "selector": .string("nav"), "urls": .bool(true)])
        XCTAssertTrue(urls["text"]?.string?.contains("href=") == true)
        let names = refs(full)
        XCTAssertEqual(refs(interactive)["Send"], names["Send"], "refs stay with their element")
        let send = try XCTUnwrap(names["Send"])

        expectDone(try await command("click", id, ["selector": .string(send)]))
        try await expect(command("getText", id, ["selector": .string("#out")]), .string("Sent"))
        expectDone(try await command("click", id, ["selector": .string(try XCTUnwrap(names["Inner"]))]))
        try await expect(command("getText", id, ["selector": .string("#out")]), .string("Inner"))
        expectDone(try await command("click", id, ["selector": .string(try XCTUnwrap(names["Shadow"]))]))
        expectDone(try await command("fill", id, ["selector": .string(try XCTUnwrap(names["Query"])), "text": .string("new")]))
        try await expect(command("getValue", id, ["selector": .string(try XCTUnwrap(names["Query"]))]), .string("new"))
        expectDone(try await command("type", id, ["selector": .string("#q"), "text": .string(" text")]))
        try await expect(command("getValue", id, ["selector": .string("#q")]), .string("new text"))
        try await expect(command("getCount", id, ["selector": .string(send)]), .int(1))
        try await expect(command("is", id, ["selector": .string(send), "property": .string("visible")]), .bool(true))

        let covered = await failure("click", id, ["selector": .string("#under")])
        XCTAssertEqual(covered, "can't click #under: covered by <div#cover>")
        let disabled = await failure("click", id, ["selector": .string(try XCTUnwrap(names["Off"]))])
        XCTAssertTrue(disabled.hasSuffix("disabled <button#off>"), disabled)
        let notEditable = await failure("fill", id, ["selector": .string(send), "text": .string("x")])
        XCTAssertTrue(notEditable.contains("not_editable"), notEditable)
        try await expect(command("click", id, ["selector": .string("#missing")]), .bool(false))

        _ = try await command("eval", id, ["script": .string("document.querySelector('#send').remove()")])
        let stale = await failure("click", id, ["selector": .string(send)])
        XCTAssertTrue(stale.hasPrefix("stale ref \(send)"), stale)
        let url = pane.page.url
        _ = try await command("reload", id)
        try await loaded(pane, at: url)
        let unknown = await failure("click", id, ["selector": .string(try XCTUnwrap(names["Cart"]))])
        XCTAssertTrue(unknown.hasPrefix("unknown ref"), unknown)
        let fresh = refs(try await command("snapshot", id, ["refs": .bool(true)]))
        XCTAssertNotEqual(fresh["Cart"], names["Cart"], "a new page never reuses a ref")
    }

    func testSettleDiffsDialogsAndLogs() async throws {
        let pane = try await fixture("settle", """
        <html><body>
        <button id="add" onclick="console.log('adding', {n: 1}); fetch('data:text/plain,hi').then(() => setTimeout(() => {
          const b = document.createElement('button'); b.textContent = 'Added'; document.body.appendChild(b); }, 150))">Add</button>
        <button id="ask" onclick="document.querySelector('#answer').textContent = String(confirm('Sure?'))">Ask</button>
        <button id="name" onclick="document.querySelector('#answer').textContent = prompt('Name?', 'Bo')">Name</button>
        <button id="boom" onclick="Promise.reject(new Error('boom'))">Boom</button>
        <p id="answer">none</p>
        </body></html>
        """)
        let id = pane.tabId
        let settled = try await command("click", id, ["selector": .string("#add"), "settle": .bool(true)])
        let diff = try XCTUnwrap(settled["diff"]?.string, "\(settled)")
        XCTAssertTrue(diff.contains(#"+ @"#) && diff.contains(#"[button] "Added""#), diff)
        XCTAssertTrue(diff.contains("unchanged"), diff)
        let delta = try await command("snapshot", id, ["refs": .bool(true), "delta": .bool(true)])
        XCTAssertTrue(delta["text"]?.string?.hasPrefix("= no change") == true || delta["text"]?.string?.contains("text ") == true,
                      "\(delta)")

        guard case .array(let console) = try await command("console", id) else { return XCTFail("console is not an array") }
        XCTAssertEqual(console.last?["text"], .string(#"adding {"n":1}"#))
        XCTAssertEqual(console.last?["level"], .string("log"))
        guard case .array(let requests) = try await command("network", id, ["filter": .string("data:")]) else {
            return XCTFail("network is not an array")
        }
        XCTAssertEqual(requests.first?["method"], .string("GET"))
        XCTAssertEqual(requests.first?["status"], .int(200))
        XCTAssertEqual(requests.first?["pending"], .bool(false))
        expectDone(try await command("click", id, ["selector": .string("#boom")]))
        var errors: [JSONValue] = []
        let deadline = Date().addingTimeInterval(3)
        while errors.isEmpty, Date() < deadline {
            if case .array(let list) = try await command("errors", id) { errors = list }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(errors.first?["text"]?.string?.contains("boom") == true, "\(errors)")
        _ = try await command("console", id, ["clear": .bool(true)])
        try await expect(command("console", id), .array([]))

        let asked = try await command("click", id, ["selector": .string("#ask")])
        XCTAssertEqual(asked["dialog"]?["type"], .string("confirm"), "\(asked)")
        try await expect(command("dialog", id), .object(["type": .string("confirm"), "message": .string("Sure?"), "origin": .string("")]))
        let blocked = await failure("getText", id, ["selector": .string("#answer")])
        XCTAssertTrue(blocked.hasPrefix("the page shows a dialog: confirm \"Sure?\""), blocked)
        _ = try await command("dialog", id, ["action": .string("accept")])
        try await expect(command("dialog", id), .null)
        try await expect(command("getText", id, ["selector": .string("#answer")]), .string("true"))
        _ = try await command("click", id, ["selector": .string("#name")])
        try await expect(command("dialog", id)["defaultText"] ?? .null, .string("Bo"))
        _ = try await command("dialog", id, ["action": .string("accept"), "text": .string("Al")])
        try await expect(command("getText", id, ["selector": .string("#answer")]), .string("Al"))
        _ = try await command("click", id, ["selector": .string("#ask")])
        _ = try await command("dialog", id, ["action": .string("dismiss")])
        try await expect(command("getText", id, ["selector": .string("#answer")]), .string("false"))
        let none = await failure("dialog", id, ["action": .string("accept")])
        XCTAssertEqual(none, "the page shows no dialog")
    }

    func testNativeInputInAWindowIsTrusted() async throws {
        let pane = try await fixture("native", """
        <html><body>
        <button id="go" style="width: 120px; height: 40px">Go</button>
        <input id="field" style="width: 200px">
        <p id="log"></p>
        <script>
        const log = text => document.querySelector('#log').textContent += text + ';';
        document.querySelector('#go').addEventListener('click', event => log('click:' + event.isTrusted));
        document.querySelector('#field').addEventListener('keydown', event => log('key:' + event.key + ':' + event.isTrusted));
        </script>
        </body></html>
        """)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane.view
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(pane.takesNativeInput)
        let id = pane.tabId
        try await expect(command("click", id, ["selector": .string("#go")]), .bool(true))
        try await expect(command("type", id, ["selector": .string("#field"), "text": .string("Hi!")]), .bool(true))
        try await expect(command("getValue", id, ["selector": .string("#field")]), .string("Hi!"))
        try await expect(command("press", id, ["selector": .string("#field"), "key": .string("Backspace")]), .bool(true))
        let deadline = Date().addingTimeInterval(3)
        var log = ""
        while !log.contains("key:Backspace"), Date() < deadline {
            log = try await command("getText", id, ["selector": .string("#log")]).string ?? ""
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(log.hasPrefix("click:true;key:H:true;key:i:true;key:!:true;key:Backspace:true"), log)
        try await expect(command("getValue", id, ["selector": .string("#field")]), .string("Hi"))
    }

    func testScreenshotFormatsSizesAndEmulation() async throws {
        let pane = try await fixture("shots", """
        <html><body style="margin: 0">
        <div id="box" style="width: 200px; height: 100px; background: red"></div>
        <button style="margin-top: 1200px">Bottom</button>
        </body></html>
        """)
        let id = pane.tabId
        func image(_ args: [String: JSONValue]) async throws -> NSBitmapImageRep {
            let reply = try await command("screenshot", id, args)
            let data = try XCTUnwrap((reply["png"] ?? reply["image"])?.string.flatMap { Data(base64Encoded: $0) })
            return try XCTUnwrap(NSBitmapImageRep(data: data))
        }
        let viewport = try await image([:])
        XCTAssertEqual(viewport.pixelsWide, 800)
        let small = try await image(["format": .string("jpeg"), "quality": .int(50), "maxWidth": .int(400)])
        XCTAssertEqual(small.pixelsWide, 400)
        let jpeg = try await command("screenshot", id, ["format": .string("jpeg")])
        XCTAssertEqual(jpeg["format"], .string("jpeg"))
        XCTAssertNil(jpeg["png"])
        let element = try await image(["selector": .string("#box")])
        XCTAssertEqual(element.pixelsWide, 200)
        XCTAssertEqual(element.pixelsHigh, 100)
        let full = try await image(["full": .bool(true)])
        XCTAssertGreaterThan(full.pixelsHigh, 1200)
        let annotated = try await command("screenshot", id, ["annotate": .bool(true)])
        guard case .array(let labeled)? = annotated["refs"] else { return XCTFail("annotated screenshot names no refs") }
        XCTAssertTrue(labeled.isEmpty, "the only control is below the fold: \(labeled)")
        try await expect(command("eval", id, ["script": .string("document.getElementById('__tab-agent-annotations')")]), .null)

        _ = try await command("set.viewport", id, ["width": .int(500), "height": .int(400)])
        try await expect(command("eval", id, ["script": .string("innerWidth")]), .int(500))
        let device = try await command("set.device", id, ["device": .string("iphone")])
        XCTAssertEqual(device["width"]?.number, 393)
        XCTAssertEqual(pane.webView?.customUserAgent?.contains("iPhone"), true)
        _ = try await command("set.device", id, ["device": .string("desktop")])
        XCTAssertEqual(pane.webView?.customUserAgent ?? "", "")
        XCTAssertNil(pane.viewport)
        _ = try await command("set.media", id, ["media": .string("dark")])
        try await expect(command("eval", id, ["script": .string("matchMedia('(prefers-color-scheme: dark)').matches")]), .bool(true))
    }

    /// Polls a read until it answers `expected`, for a few seconds.
    private func eventually(_ name: String, _ id: String, _ args: [String: JSONValue], _ expected: JSONValue,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(4)
        var value = JSONValue.null
        while Date() < deadline {
            value = try await command(name, id, args)
            if value == expected { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(value, expected, file: file, line: line)
    }

    func testCallersDriveTheirOwnBrowserWithoutNamingIt() async throws {
        let pane = try await fixture("mine", "<html><body><h1 id=\"t\">Mine</h1></body></html>")
        try await expect(command("getText", nil, ["selector": .string("#t")]), .string("Mine"))
        let caller = SessionId()
        let opened = try await command("open", nil, ["caller": .string(caller.description)])
        let other = try XCTUnwrap(opened.string)
        let ambiguous = await failure("getText", nil, ["selector": .string("#t")])
        XCTAssertTrue(ambiguous.hasPrefix("2 browsers are open; name one: "), ambiguous)
        guard case .array(let listed) = try await command("list", nil, ["caller": .string(caller.description)]) else {
            return XCTFail("list is not an array")
        }
        XCTAssertEqual(listed.filter { $0["current"] == .bool(true) }.map { $0["id"] }, [.string(other)])
        // Naming a browser once makes it the caller's.
        try await expect(command("getText", pane.tabId, ["selector": .string("#t"), "caller": .string(caller.description)]),
                         .string("Mine"))
        try await expect(command("getText", nil, ["selector": .string("#t"), "caller": .string(caller.description)]),
                         .string("Mine"))
        // open without --new reuses the caller's browser instead of opening another.
        let count = host.panes.count
        try await expect(command("open", nil, ["caller": .string(caller.description), "reuse": .bool(true)]),
                         .string(pane.tabId))
        XCTAssertEqual(host.panes.count, count)
        // Another caller gets the only browser in its tab.
        let neighbor = SessionId()
        host.near[neighbor] = [pane.tabId]
        try await expect(command("getText", nil, ["selector": .string("#t"), "caller": .string(neighbor.description)]),
                         .string("Mine"))
        // Once the other closes, the only browser is everyone's.
        _ = try await command("close", other)
        try await expect(command("getText", nil, ["selector": .string("#t"), "caller": .string(SessionId().description)]),
                         .string("Mine"))
        // open never takes over a browser that isn't the caller's.
        let fresh = try await command("open", nil, ["caller": .string(SessionId().description), "reuse": .bool(true)])
        XCTAssertNotEqual(fresh.string, pane.tabId)
        _ = try await command("close", fresh.string)
        _ = try await command("close", pane.tabId)
        let none = await failure("getText", nil, ["selector": .string("#t")])
        XCTAssertEqual(none, "no browser to drive; open one with tab browser open URL")
    }

    func testUploadsGiveFileFieldsFilesWithoutAChooser() async throws {
        try "alpha".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "{}".write(to: folder.appendingPathComponent("b.json"), atomically: true, encoding: .utf8)
        let pane = try await fixture("upload", """
        <html><body>
        <label id="pick" for="files">Choose</label><input type="file" id="files" multiple style="display: none">
        <input type="file" id="single"><button id="opener" onclick="document.querySelector('#single').click()">Open</button>
        <p id="out"></p><p id="one"></p>
        <script>
        document.querySelector('#files').addEventListener('change', async event => {
          const parts = await Promise.all([...event.target.files].map(async file => file.name + ':' + file.type + ':' + await file.text()));
          document.querySelector('#out').textContent = parts.join('|');
        });
        document.querySelector('#single').addEventListener('change', event => {
          document.querySelector('#one').textContent = [...event.target.files].map(file => file.name).join('|');
        });
        </script>
        </body></html>
        """)
        let id = pane.tabId
        let files: JSONValue = .array([.string(folder.appendingPathComponent("a.txt").path),
                                       .string(folder.appendingPathComponent("b.json").path)])
        expectDone(try await command("upload", id, ["selector": .string("#pick"), "files": files]))
        try await eventually("getText", id, ["selector": .string("#out")],
                             .string("a.txt:text/plain:alpha|b.json:application/json:{}"))
        let single = await failure("upload", id, ["selector": .string("#single"), "files": files])
        XCTAssertTrue(single.contains("single_file"), single)
        let missing = await failure("upload", id, ["selector": .string("#single"), "files": .array([.string("/nonexistent/x.txt")])])
        XCTAssertEqual(missing, "no file at /nonexistent/x.txt")
        // A button that opens a file chooser gets the files when clicked.
        let viaChooser = try await command("upload", id, ["selector": .string("#opener"),
                                                         "files": .array([.string(folder.appendingPathComponent("a.txt").path)])])
        expectDone(viaChooser)
        try await eventually("getText", id, ["selector": .string("#one")], .string("a.txt"))
        // A chooser nobody answers is reported, instead of a panel stopping the app.
        let unanswered = try await command("click", id, ["selector": .string("#opener")])
        XCTAssertTrue(unanswered["warning"]?.string?.contains("file chooser") == true, "\(unanswered)")
    }

    func testCrossOriginFramesJoinTheSnapshotAndTakeActions() async throws {
        try """
        <html><body style="margin: 0">
        <button id="pay" onclick="this.textContent = 'Paid'">Pay</button><input id="card" placeholder="Card">
        </body></html>
        """.write(to: folder.appendingPathComponent("child.html"), atomically: true, encoding: .utf8)
        let pane = try await fixture("parent", """
        <html><body style="margin: 0">
        <p>Parent</p>
        <iframe id="widget" title="Payment" sandbox="allow-scripts" src="child.html" style="width: 300px; height: 120px; border: 0"></iframe>
        </body></html>
        """)
        let id = pane.tabId
        try await Task.sleep(for: .milliseconds(300))
        let shot = try await command("snapshot", id, ["refs": .bool(true)])
        let text = try XCTUnwrap(shot["text"]?.string)
        XCTAssertTrue(text.contains(#"[iframe] "Payment""#), text)
        XCTAssertFalse(text.contains("not shown"), text)
        let names = refs(shot)
        let pay = try XCTUnwrap(names["Pay"], text)
        let card = try XCTUnwrap(names["Card"], text)
        XCTAssertTrue(pay.hasPrefix("@f1e"), pay)
        let interactive = try await command("snapshot", id, ["refs": .bool(true), "interactive": .bool(true)])
        XCTAssertTrue(interactive["text"]?.string?.contains(pay + #" [button] "Pay""#) == true, "\(interactive)")
        expectDone(try await command("fill", id, ["selector": .string(card), "text": .string("4242")]))
        try await expect(command("getValue", id, ["selector": .string(card)]), .string("4242"))
        let box = try await command("getBox", id, ["selector": .string(pay)])
        XCTAssertGreaterThan(box["y"]?.number ?? 0, 10, "the frame's box is offset by the parent's paragraph: \(box)")
        expectDone(try await command("click", id, ["selector": .string(pay)]))
        try await expect(command("getText", id, ["selector": .string(pay)]), .string("Paid"))

        // In a window the click is a real one, at the frame's place in the page.
        _ = try await command("eval", id, ["script": .string("document.querySelector('#widget').src = 'child.html'")])
        try await Task.sleep(for: .milliseconds(400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane.view
        pane.view.layoutSubtreeIfNeeded()
        let again = refs(try await command("snapshot", id, ["refs": .bool(true)]))
        let fresh = try XCTUnwrap(again["Pay"])
        try await expect(command("click", id, ["selector": .string(fresh)]), .bool(true))
        try await eventually("getText", id, ["selector": .string(fresh)], .string("Paid"))
    }

    func testWaitsNeedEveryConditionAndAcceptRefs() async throws {
        let pane = try await fixture("waits", """
        <html><body><button id="go">Go</button><p id="status">Idle</p>
        <script>
        setTimeout(() => { const p = document.createElement('p'); p.id = 'late'; p.textContent = 'Late'; document.body.appendChild(p); }, 200);
        setTimeout(() => { document.querySelector('#status').textContent = 'Done'; }, 600);
        </script></body></html>
        """)
        let id = pane.tabId
        let started = Date()
        try await expect(command("wait", id, ["selector": .string("#late"), "text": .string("Done"), "timeoutMs": .int(3000)]),
                         .bool(true))
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.45, "the text came last, so the wait lasted until then")
        try await expect(command("wait", id, ["selector": .string("#late"), "text": .string("Never"), "timeoutMs": .int(300)]),
                         .bool(false))
        let snapshot = try await command("snapshot", id, ["refs": .bool(true)])
        let go = try XCTUnwrap(refs(snapshot)["Go"])
        try await expect(command("wait", id, ["selector": .string(go), "function": .string("document.title !== null"),
                                              "load": .string("networkidle"), "timeoutMs": .int(3000)]), .bool(true))
        let unknown = await failure("wait", id, ["load": .string("idle")])
        XCTAssertEqual(unknown, "unknown load state 'idle'; use load or networkidle")
    }

    func testNetworkKeepsHeadersAndBodiesAndFilters() async throws {
        let pane = try await fixture("requests", """
        <html><body><button id="load" onclick="fetch('data:application/json,{%22a%22:1}', { headers: { 'X-Test': 'yes' } })">Load</button>
        </body></html>
        """)
        let id = pane.tabId
        expectDone(try await command("click", id, ["selector": .string("#load")]))
        var listed: [JSONValue] = []
        let deadline = Date().addingTimeInterval(4)
        while listed.isEmpty, Date() < deadline {
            if case .array(let list) = try await command("network", id, ["type": .string("fetch"), "status": .string("2xx")]) {
                listed = list.filter { $0["pending"] == .bool(false) }
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        let number = try XCTUnwrap(listed.first?["id"], "\(listed)")
        try await expect(command("network", id, ["status": .string("4xx")]), .array([]))
        try await expect(command("network", id, ["method": .string("POST")]), .array([]))
        var detail = JSONValue.null
        let bodyDeadline = Date().addingTimeInterval(4)
        while detail["responseBody"] == nil, Date() < bodyDeadline {
            detail = try await command("network", id, ["id": number])
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(detail["requestHeaders"]?["x-test"], .string("yes"), "\(detail)")
        XCTAssertEqual(detail["responseBody"], .string(#"{"a":1}"#), "\(detail)")
        XCTAssertEqual(detail["contentType"]?.string?.hasPrefix("application/json"), true, "\(detail)")
        try await expect(command("network", id, ["id": .int(9999)]), .null)
    }

    func testPopupsAreReportedAndDrivenScrollAndClicks() async throws {
        let pane = try await fixture("popups", """
        <html><body style="margin: 0">
        <button id="pop" onclick="window.open('https://popup.example.test/next')">Pop</button>
        <button id="twice" ondblclick="this.textContent = 'Double'" oncontextmenu="event.preventDefault(); this.dataset.menu = 'yes'">Twice</button>
        <div style="height: 3000px"></div>
        </body></html>
        """)
        let id = pane.tabId
        let popped = try await command("click", id, ["selector": .string("#pop")])
        guard case .array(let opened)? = popped["opened"], let popup = opened.first?.string else {
            return XCTFail("the action didn't report the new browser: \(popped)")
        }
        XCTAssertEqual(host.panes[popup]?.agent.driven, true, "an agent's popup is driven too")
        XCTAssertEqual(host.opened, ["https://popup.example.test/next"])
        try await expect(command("click", id, ["selector": .string("#twice"), "double": .bool(true)]), .object([
            "ok": .bool(true), "note": .string("the pane isn't in a window, so Tab used script events instead of real input"),
        ]))
        try await expect(command("getText", id, ["selector": .string("#twice")]), .string("Double"))
        _ = try await command("click", id, ["selector": .string("#twice"), "right": .bool(true)])
        try await expect(command("getAttribute", id, ["selector": .string("#twice"), "attribute": .string("data-menu")]),
                         .string("yes"))
        expectDone(try await command("scroll", id, ["x": .int(0), "y": .int(300)]))
        try await expect(command("eval", id, ["script": .string("scrollY")]), .int(300))
        try await expect(command("downloads", id), .array([]))
    }

    func testSavedStateSignsAnotherBrowserIn() async throws {
        let pane = try await fixture("state", "<html><body>State</body></html>")
        let id = pane.tabId
        _ = try await command("cookies.set", id, ["name": .string("session"), "value": .string("abc"),
                                                  "domain": .string("example.com"), "httpOnly": .bool(true)])
        let saved = try await command("state.save", id)
        guard case .array(let cookies)? = saved["cookies"] else { return XCTFail("no cookies in \(saved)") }
        XCTAssertTrue(cookies.contains { $0["name"] == .string("session") && $0["httpOnly"] == .bool(true) }, "\(saved)")
        _ = try await command("cookies.clear", id)
        try await expect(command("cookies.get", id, ["url": .string("https://example.com/")]), .array([]))
        let loaded = try await command("state.load", id, ["state": saved])
        XCTAssertEqual(loaded["cookies"]?.number ?? 0, Double(cookies.count))
        guard case .array(let back) = try await command("cookies.get", id, ["url": .string("https://example.com/")]) else {
            return XCTFail("cookies.get is not an array")
        }
        XCTAssertEqual(back.first?["value"], .string("abc"))
        let invalid = await failure("state.load", id, ["state": .object([:])])
        XCTAssertTrue(invalid.hasPrefix("the file isn't a saved browser state"), invalid)
    }
}
