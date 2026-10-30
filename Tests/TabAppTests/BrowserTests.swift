import CommonCrypto
import TabClient
import TabCore
import WebKit
import XCTest
@testable import TabApp

@MainActor
final class BrowserHistoryTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-browser-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTypedTextBecomesAnAddressOrASearch() {
        let settings = BrowserSettings(searchEngine: .duckDuckGo)
        XCTAssertEqual(settings.resolve("example.com/a"), "https://example.com/a")
        XCTAssertEqual(settings.resolve("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(settings.resolve("javascript:alert(1)"), "https://duckduckgo.com/?q=javascript%3Aalert%281%29")
        XCTAssertEqual(settings.resolve("swift concurrency"), "https://duckduckgo.com/?q=swift+concurrency")
        XCTAssertNil(settings.resolve("   "))
    }

    func testSuggestionsMatchCodeshLiteralTextAndVisitOrder() {
        let history = BrowserHistoryStore(file: folder.appendingPathComponent("browser-history.json"))
        let old = Date(timeIntervalSince1970: 1_000)
        history.recordVisit(url: "https://docs.swift.org/guide", title: "The Swift Guide", at: old)
        for _ in 0 ..< 5 { history.recordVisit(url: "https://forums.swift.org", title: "Swift Forums", at: old) }
        history.recordVisit(url: "https://swift.org", title: "Swift.org", at: Date(timeIntervalSince1970: 2_000))
        history.recordVisit(url: "about:blank", title: nil)

        XCTAssertEqual(history.suggestions(for: "swift").map(\.url),
                       ["https://forums.swift.org", "https://swift.org", "https://docs.swift.org/guide"])
        XCTAssertTrue(history.suggestions(for: "swift the").isEmpty)
        XCTAssertEqual(history.suggestions(for: "swift.org/guide").map(\.url), ["https://docs.swift.org/guide"])
        XCTAssertEqual(history.suggestions(for: "").first?.url, "https://swift.org")
        XCTAssertEqual(history.entries.count, 3, "start pages are not history")
    }

    func testHistorySurvivesARestartAndImportsMerge() throws {
        let file = folder.appendingPathComponent("browser-history.json")
        let history = BrowserHistoryStore(file: file)
        history.recordVisit(url: "https://example.com", title: "Example")
        history.recordVisit(url: "https://example.com", title: nil)
        history.updateTitle(url: "https://example.com", title: "Example Domain")
        let added = history.merge([
            BrowserHistoryEntry(url: "https://example.com", visitCount: 3),
            BrowserHistoryEntry(url: "https://bookmarked.dev", title: "Saved", visitCount: 0, bookmarked: true),
        ])
        XCTAssertEqual(added, 1)
        history.saveNow()

        let reopened = BrowserHistoryStore(file: file)
        let example = try XCTUnwrap(reopened.entries.first { $0.url == "https://example.com" })
        XCTAssertEqual(example.visitCount, 5)
        XCTAssertEqual(example.title, "Example Domain")
        XCTAssertEqual(reopened.entries.first { $0.url == "https://bookmarked.dev" }?.bookmarked, true)

        reopened.clear()
        XCTAssertTrue(BrowserHistoryStore(file: file).entries.isEmpty)
    }

    func testProfilesPersistAndTheDefaultCannotBeDeleted() async throws {
        let profiles = BrowserProfiles(root: folder)
        XCTAssertEqual(profiles.browserProfiles().map(\.name), ["Default"])
        let work = try profiles.addBrowserProfile(named: "  Work ")
        XCTAssertEqual(work.name, "Work")
        _ = try profiles.addBrowserProfile(named: "")
        try profiles.renameBrowserProfile(work.id, to: "Client")
        XCTAssertThrowsError(try profiles.renameBrowserProfile(work.id, to: " "))

        let reopened = BrowserProfiles(root: folder)
        XCTAssertEqual(reopened.browserProfiles().map(\.name), ["Default", "Client", "Profile"])
        XCTAssertEqual(try reopened.resolve("client").id, work.id)
        XCTAssertEqual(try reopened.resolve(work.id.uppercased()).name, "Client")
        XCTAssertEqual(try reopened.resolve(nil).name, "Default")
        XCTAssertThrowsError(try reopened.resolve("Nobody"))
        XCTAssertEqual(reopened.profile(forSaved: "gone").name, "Default")

        do {
            try await reopened.deleteBrowserProfile("")
            XCTFail("the default profile was deleted")
        } catch {}
        reopened.defaultProfileId = work.id
        do {
            try await reopened.deleteBrowserProfile(work.id)
            XCTFail("the chosen default profile was deleted")
        } catch {}
        reopened.defaultProfileId = ""
        try await reopened.deleteBrowserProfile(work.id)
        XCTAssertEqual(BrowserProfiles(root: folder).browserProfiles().map(\.name), ["Default", "Profile"])
    }

    func testRepeatedImportKeepsVisitCountsAndLatestTitleAcrossRestarts() {
        let file = folder.appendingPathComponent("browser-history.json")
        let history = BrowserHistoryStore(file: file)
        let imported = [
            BrowserHistoryEntry(url: "https://example.test/", title: "Older", lastVisit: Date(timeIntervalSince1970: 1), importedVisits: ["firefox:1"]),
            BrowserHistoryEntry(url: "https://example.test/", title: "Newer", lastVisit: Date(timeIntervalSince1970: 2), importedVisits: ["firefox:2"]),
            BrowserHistoryEntry(url: "https://saved.test/", visitCount: 0, bookmarked: true),
        ]
        history.merge(imported)
        history.saveNow()
        let reopened = BrowserHistoryStore(file: file)
        reopened.merge(imported)
        XCTAssertEqual(reopened.entries.first?.visitCount, 2)
        XCTAssertEqual(reopened.entries.first?.title, "Newer")
        XCTAssertEqual(reopened.suggestions(for: "").map(\.url), ["https://example.test/"])
        reopened.recordVisit(url: "https://example.test/", title: nil)
        reopened.merge(imported)
        XCTAssertEqual(reopened.entries.first?.visitCount, 3)
    }

    func testProfileNamesAreUniqueAndDefaultRenamePersists() throws {
        let profiles = BrowserProfiles(root: folder)
        let work = try profiles.add(named: "Work")
        XCTAssertThrowsError(try profiles.add(named: "work"))
        XCTAssertThrowsError(try profiles.rename(work.id, to: "DEFAULT"))
        XCTAssertThrowsError(try profiles.add(named: "Bad\0Name"))
        XCTAssertThrowsError(try profiles.add(named: String(repeating: "a", count: 129)))
        try profiles.rename("", to: "Personal")
        XCTAssertEqual(BrowserProfiles(root: folder).profiles[0].name, "Personal")
    }

    func testDownloadsGetAFreeName() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("report.pdf").path, contents: Data())
        XCTAssertEqual(BrowserPaneController.downloadDestination(for: "report.pdf", in: folder).lastPathComponent, "report 2.pdf")
        XCTAssertEqual(BrowserPaneController.downloadDestination(for: "../evil", in: folder).lastPathComponent, "download..-evil")
    }
}

final class BrowserImportTests: XCTestCase {
    func testChromeCookiesDecryptWithTheSafeStorageKey() throws {
        let key = try BrowserImport.chromiumKey(password: Data("peanuts".utf8))
        XCTAssertEqual(key.count, 16)
        let plain = try BrowserImport.aes128(operation: CCOperation(kCCEncrypt), Data("session=abc123".utf8), key: key)
        let encrypted = Data("v10".utf8) + plain
        XCTAssertEqual(try BrowserImport.decryptChromiumValue(encrypted, key: key, hashPrefix: false), "session=abc123")

        let hashed = Data(repeating: 7, count: 32) + Data("token".utf8)
        let newer = Data("v10".utf8) + (try BrowserImport.aes128(operation: CCOperation(kCCEncrypt), hashed, key: key))
        XCTAssertEqual(try BrowserImport.decryptChromiumValue(newer, key: key, hashPrefix: true), "token")

        let wrongKey = try BrowserImport.chromiumKey(password: Data("other".utf8))
        XCTAssertNotEqual(try? BrowserImport.decryptChromiumValue(encrypted, key: wrongKey, hashPrefix: false), "session=abc123")
        XCTAssertThrowsError(try BrowserImport.decryptChromiumValue(Data("v11xxxxxxxxxxxxxxxxx".utf8), key: key, hashPrefix: false))
    }

    func testSafariBinaryCookiesParse() throws {
        var record = Data()
        func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        func le64(_ value: Double) -> Data { withUnsafeBytes(of: value.bitPattern.littleEndian) { Data($0) } }
        let strings = [".example.com", "sid", "/", "xyz"].map { Data($0.utf8) + Data([0]) }
        let header = 56
        var offsets: [Int] = []
        var cursor = header
        for string in strings {
            offsets.append(cursor)
            cursor += string.count
        }
        record += le32(cursor) + le32(0) + le32(1 | 4) + le32(0)
        for offset in offsets { record += le32(offset) }
        record += Data(count: 8) + le64(700_000_000) + le64(600_000_000)
        for string in strings { record += string }
        var page = Data([0, 0, 1, 0]) + le32(1) + le32(16) + le32(0)
        page += record
        var file = Data("cook".utf8)
        file += withUnsafeBytes(of: UInt32(1).bigEndian) { Data($0) }
        file += withUnsafeBytes(of: UInt32(page.count).bigEndian) { Data($0) }
        file += page
        let cookies = try BrowserImport.parseBinaryCookies(file)
        XCTAssertEqual(cookies, [ImportedCookie(name: "sid", value: "xyz", domain: ".example.com", path: "/", secure: true,
                                                httpOnly: true, expires: Date(timeIntervalSince1970: 700_000_000 + 978_307_200))])
        XCTAssertThrowsError(try BrowserImport.parseBinaryCookies(Data("nope".utf8)))
        XCTAssertThrowsError(try BrowserImport.parseBinaryCookies(file.dropLast()))
        var invalidOffset = file
        invalidOffset.replaceSubrange(20 ..< 24, with: [255, 255, 255, 127])
        XCTAssertThrowsError(try BrowserImport.parseBinaryCookies(invalidOffset))
    }
}

final class BrowserScriptTests: XCTestCase {
    func testArgumentsAreEmbeddedAsLiterals() throws {
        let script = try XCTUnwrap(BrowserScripts.script(.type, args: .object([
            "selector": .string("input[name=\"q\"]"), "text": .string("a'b\"c\u{2028}"), "submit": .bool(true),
        ])))
        XCTAssertTrue(script.contains(#"document.querySelector("input[name=\"q\"]")"#))
        XCTAssertTrue(script.contains(#"setValue(el, "a'b\"c\u2028");"#))
        XCTAssertTrue(script.contains("if (true) submit(el);"))
    }

    func testMissingArgumentsAreReported() {
        XCTAssertThrowsError(try BrowserScripts.script(.click, args: .object([:]))) {
            XCTAssertEqual(($0 as? BrowserScripts.Failure)?.message, "missing argument 'selector'")
        }
        XCTAssertThrowsError(try BrowserScripts.script(.storageGet, args: .object(["key": .string("a"), "kind": .string("disk")]))) {
            XCTAssertEqual(($0 as? BrowserScripts.Failure)?.message, "unknown storage 'disk'; use local or session")
        }
    }

    func testAppCommandsHaveNoPageScript() throws {
        for command in [BrowserCommand.open, .navigate, .screenshot, .cookiesGet, .reload] {
            XCTAssertNil(try BrowserScripts.script(command, args: .object([:])), command.rawValue)
        }
    }

    func testWaitConditionsFollowTheirPriorityAndSwallowErrors() throws {
        let function = try BrowserScripts.condition(.wait, args: .object(["function": .string("window.ready"), "selector": .string("#a")]))
        XCTAssertTrue(function.contains(BrowserScripts.literal("return (\nwindow.ready\n);")))
        XCTAssertTrue(function.contains("catch (error)"))
        let text = try BrowserScripts.condition(.wait, args: .object(["text": .string("Done"), "urlContains": .string("x")]))
        XCTAssertTrue(text.contains(#".includes("Done")"#))
        XCTAssertTrue(try BrowserScripts.condition(.wait, args: .object([:])).contains("return true;"))
        XCTAssertThrowsError(try BrowserScripts.condition(.waitFor, args: .object([:])))
    }

    func testMalformedTimeoutsUseCodeshDefaults() {
        XCTAssertEqual(BrowserScripts.timeout(.object(["timeoutMs": .int(-1)]), default: 5), 5)
        XCTAssertEqual(BrowserScripts.timeout(.object(["timeoutMs": .double(100.5)]), default: 5), 5)
    }

    func testTimeoutsAreCapped() {
        XCTAssertEqual(BrowserScripts.timeout(.object([:]), default: 5), 5)
        XCTAssertEqual(BrowserScripts.timeout(.object(["timeoutMs": .int(900_000)]), default: 5), BrowserCommand.maxWait)
        XCTAssertEqual(BrowserScripts.timeout(.object(["timeoutMs": .int(250)]), default: 5), 0.25)
    }

    func testElementPickerCopyIsCut() {
        let html = String(repeating: "h", count: 600)
        let copied = BrowserScripts.elementClipboardText(.object([
            "url": .string("https://x.dev"), "html": .string(html), "text": .string("Hello"),
        ]))
        XCTAssertEqual(copied, "Page: https://x.dev\n\nHTML:\n\(String(repeating: "h", count: 500))\n… [remaining HTML omitted to save tokens]\n\nText:\nHello")
    }
}

/// A shell stand-in: panes live in a dictionary.
@MainActor
final class TestBrowserHost: BrowserHost {
    let theme = AppTheme(systemIsDark: true)
    var browserSettings = BrowserSettings()
    let browserProfiles: BrowserProfiles
    var panes: [String: BrowserPaneController] = [:]
    var saved: [String: BrowserPane] = [:]
    var opened: [String] = []
    var popupProfiles: [String] = []

    init(root: URL) {
        browserProfiles = BrowserProfiles(root: root, storeFactory: { profile in
            if profile.isBuiltInDefault { return .nonPersistent() }
            return WKWebsiteDataStore(forIdentifier: UUID(uuidString: profile.id)!)
        })
    }

    func openBrowserPane(url: String, profile: String, from source: BrowserPaneController) {
        opened.append(url)
        popupProfiles.append(profile)
    }
    func browserPane(_ pane: BrowserPaneController, didChange state: BrowserPane) { saved[pane.tabId] = state }
    func browserPane(_ pane: BrowserPaneController, didChangeTitle title: String?, favicon: NSImage?) {}
    func browserPaneRequestsClose(_ pane: BrowserPaneController) {}
    func showToast(_ message: String, isError: Bool) {}
    func manageBrowserProfiles() {}

    func openBrowserPane(url: String?, profile: String?, project: String?, worktree: String?, split: Bool) throws
        -> BrowserPaneController {
        if project == "missing" { throw BrowserScripts.Failure("no project named 'missing'") }
        let pane = BrowserPaneController(tabId: UUID().uuidString, state: BrowserPane(url: url, profile: profile), host: self)
        panes[pane.tabId] = pane
        return pane
    }

    func browserTabs(project: String?, worktree: String?) throws -> [BrowserTab] {
        panes.values.map { BrowserTab(tabId: $0.tabId, state: $0.state, active: true) }
    }

    func browserPane(tabId: String) -> BrowserPaneController? { panes[tabId] }

    func closeBrowserPane(tabId: String) -> Bool { panes.removeValue(forKey: tabId) != nil }
}

@MainActor
final class BrowserAutomationTests: XCTestCase {
    private var folder: URL!
    private var host: TestBrowserHost!
    private var automation: BrowserAutomation!
    private var navigation: BrowserFixtureNavigation?

    override func setUp() async throws {
        folder = URL(fileURLWithPath: "/tmp/tab-browser-test").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        host = TestBrowserHost(root: folder)
        automation = BrowserAutomation(host: host)
    }

    override func tearDown() async throws {
        host = nil
        automation = nil
        navigation = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private let page = """
    <html><head><title>Fixture</title></head><body>
    <h1>Welcome</h1>
    <button id="go" onclick="document.getElementById('out').textContent = 'clicked'">Go</button>
    <input name="q" placeholder="Search">
    <ul><li>One</li><li>Two</li><li>Three</li></ul>
    <a href="#later" data-testid="later">Later</a>
    <p id="out"></p>
    <script>setTimeout(() => { const p = document.createElement('p'); p.id = 'late'; p.textContent = 'Ready'; document.body.appendChild(p); }, 300);</script>
    </body></html>
    """

    private func call(_ command: BrowserCommand, _ args: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await automation.handle(command: command, args: .object(args))
    }

    private func expect(_ value: JSONValue, _ expected: JSONValue, _ message: String = "",
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value, expected, message, file: file, line: line)
    }

    /// Opens a pane over the fixture page and waits for it to load.
    private func openFixture() async throws -> String {
        let opened = try await call(.open)
        let id = try XCTUnwrap(opened.string)
        let pane = try XCTUnwrap(host.panes[id])
        let webView = try XCTUnwrap(pane.ensureWebView())
        pane.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        pane.view.layoutSubtreeIfNeeded()
        let file = folder.appendingPathComponent("index.html")
        try page.write(to: file, atomically: true, encoding: .utf8)
        let navigation = BrowserFixtureNavigation(pane: pane, folder: folder)
        self.navigation = navigation
        webView.navigationDelegate = navigation
        webView.loadFileURL(file, allowingReadAccessTo: folder)
        let deadline = Date().addingTimeInterval(20)
        while (pane.page.loads == 0 || pane.page.loading), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(pane.page.loading, "the fixture did not load")
        guard pane.page.loads > 0, pane.page.url == file.absoluteString else {
            throw BrowserScripts.Failure("WebKit did not load the file fixture in this environment")
        }
        XCTAssertEqual(pane.page.error, nil)
        return id
    }

    func testCommandsDriveARealPage() async throws {
        let id = try await openFixture()
        let tab: [String: JSONValue] = ["tabId": .string(id)]

        try await expect(call(.getCount, tab.merging(["selector": .string("li")]) { $1 }), .int(3))
        try await expect(call(.getText, tab.merging(["selector": .string("h1")]) { $1 }), .string("Welcome"))
        try await expect(call(.click, tab.merging(["selector": .string("#go")]) { $1 }), .bool(true))
        try await expect(call(.getText, tab.merging(["selector": .string("#out")]) { $1 }), .string("clicked"))
        try await expect(call(.click, tab.merging(["selector": .string("#nothing")]) { $1 }), .bool(false))
        try await expect(call(.fill, tab.merging(["selector": .string("input[name=q]"), "text": .string("tab")]) { $1 }), .bool(true))
        try await expect(call(.getValue, tab.merging(["selector": .string("input[name=q]")]) { $1 }), .string("tab"))
        try await expect(call(.evaluate, tab.merging(["script": .string("1 + 2")]) { $1 }), .int(3))
        try await expect(call(.evaluate, tab.merging(["script": .string("const x = 4; return x * 2;")]) { $1 }), .int(8))
        try await expect(call(.wait, tab.merging(["selector": .string("#late"), "timeoutMs": .int(5000)]) { $1 }), .bool(true))
        try await expect(call(.waitFor, tab.merging(["selector": .string("#never"), "timeoutMs": .int(300)]) { $1 }), .bool(false))

        let read = try await call(.read, tab)
        XCTAssertEqual(read["title"], .string("Fixture"))
        XCTAssertTrue(read["text"]?.string?.contains("Welcome") == true)

        let snapshot = try await call(.snapshot, tab)
        guard case .array(let elements) = snapshot else { return XCTFail("snapshot is not a list") }
        let selectors = elements.compactMap { $0["selector"]?.string }
        XCTAssertTrue(selectors.contains("#go"))
        XCTAssertTrue(selectors.contains("[data-testid=\"later\"]"))
        XCTAssertTrue(selectors.contains("html > body > input") || selectors.contains("body > input"), "\(selectors)")
        for selector in selectors {
            try await expect(call(.getCount, tab.merging(["selector": .string(selector)]) { $1 }), .int(1), selector)
        }

        let finding = try await call(.find, tab.merging(["kind": .string("role"), "value": .string("button")]) { $1 })
        guard case .array(let found) = finding else { return XCTFail("find is not a list") }
        XCTAssertEqual(found.first?["selector"], .string("#go"))

        try await expect(call(.storageSet, tab.merging(["key": .string("k"), "value": .string("v")]) { $1 }), .null)
        try await expect(call(.storageGet, tab.merging(["key": .string("k")]) { $1 }), .string("v"))

        let listing = try await call(.list)
        guard case .array(let listed) = listing else { return XCTFail("list is not a list") }
        XCTAssertEqual(listed.first?["tabId"], .string(id))
        XCTAssertEqual(listed.first?["profile"], .string("Default"))

        try await expect(call(.close, tab), .null)
        XCTAssertNil(host.panes[id])
    }

    func testScriptErrorsAndUnknownTabsAreReported() async throws {
        do {
            _ = try await call(.click, ["tabId": .string("nope"), "selector": .string("a")])
            XCTFail("an unknown tab was found")
        } catch {
            XCTAssertEqual((error as? BrowserScripts.Failure)?.message, "browser tab not found nope")
        }
        do {
            _ = try await call(.open, ["project": .string("missing")])
            XCTFail("an unknown project opened")
        } catch {
            XCTAssertEqual((error as? BrowserScripts.Failure)?.message, "no project named 'missing'")
        }
        let id = try await openFixture()
        do {
            _ = try await call(.evaluate, ["tabId": .string(id), "script": .string("throw new Error('boom')")])
            XCTFail("the error was lost")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("script error: "), "\(error)")
        }
        do {
            _ = try await automation.handle(command: "browser.fly", args: [:])
            XCTFail("an unknown command ran")
        } catch {
            XCTAssertEqual((error as? BrowserScripts.Failure)?.message, "unknown command browser.fly")
        }
    }

    func testPaneSwitchesProfileAndReportsItsState() async throws {
        let work = try host.browserProfiles.add(named: "Work")
        let pane = BrowserPaneController(tabId: "pane", state: BrowserPane(url: nil, profile: nil), host: host)
        _ = pane.view
        XCTAssertTrue(pane.isBlank)
        XCTAssertNil(pane.pageTitle)
        let first = try XCTUnwrap(pane.webView)
        XCTAssertTrue(first.configuration.websiteDataStore === host.browserProfiles.dataStore(for: pane.profile))
        pane.switchProfile(to: work)
        XCTAssertFalse(pane.webView === first, "a profile change needs a page in the other data store")
        XCTAssertEqual(host.saved["pane"]?.profile, work.id)
        XCTAssertTrue(host.browserProfiles.panes.pane("pane") === pane)

        try await host.browserProfiles.delete(work.id)
        XCTAssertEqual(pane.profile.name, "Default", "panes of a deleted profile browse with the default")

        pane.apply(settings: BrowserSettings(enabled: false))
        XCTAssertNil(pane.webView)
        pane.apply(settings: BrowserSettings(enabled: true))
        XCTAssertNotNil(pane.webView)
    }

    func testDisabledBrowserListsNothingAndRefusesCommands() async throws {
        host.browserSettings.enabled = false
        try await expect(call(.list), .array([]))
        do {
            _ = try await call(.open)
            XCTFail("a disabled browser opened a tab")
        } catch {
            XCTAssertEqual((error as? BrowserScripts.Failure)?.message, "the built-in browser is disabled")
        }
    }
}
