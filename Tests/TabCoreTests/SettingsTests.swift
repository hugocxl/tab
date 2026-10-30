import XCTest
@testable import TabCore

final class SettingsTests: XCTestCase {
    // MARK: Compatibility

    func testDefaultsRoundTripAndAMissingFileIsCreatedOnce() throws {
        let directory = try TemporaryDirectory()
        let path = directory.file("settings.json")
        XCTAssertEqual(try Settings.load(path), Settings())
        let created = try directory.read("settings.json")
        XCTAssertEqual(try Settings.load(path), Settings())
        XCTAssertEqual(try directory.read("settings.json"), created)
        XCTAssertEqual(try roundTrip(Settings()), Settings())
    }

    func testUnknownKeysAndMissingKeysAreTolerated() throws {
        let directory = try TemporaryDirectory()
        let source = """
        {
          "future": {"anything": [1, 2]},
          "window": {"confirmRunningProcess": false, "newOption": "x"},
          "appearance": {"darkTheme": "Dracula", "layout": "tab_focused", "tipsVisible": true,
                         "agentsPanelDock": "right", "agentSessionsProviders": ["claude"]},
          "browser": {"searchEngine": "duckDuckGo"},
          "keymap": {"split_right": "cmd-alt-d", "toggle_composer": "cmd-j", "extension.foo": "cmd-u",
                     "toggle_agents_panel": "cmd-alt-a", "toggle_agent_sessions": "cmd-alt-s"}
        }
        """
        let path = try directory.write("settings.json", source)
        let settings = try Settings.load(path)
        XCTAssertFalse(settings.window.confirmRunningProcess)
        XCTAssertEqual(settings.appearance.darkTheme, "Dracula")
        XCTAssertEqual(settings.appearance.lightTheme, "Tab Light")
        XCTAssertEqual(settings.browser.searchEngine, .duckDuckGo)
        XCTAssertTrue(settings.browser.enabled)
        XCTAssertEqual(settings.keymap.chord(.splitRight)?.rawValue, "cmd-alt-d")
        XCTAssertEqual(try directory.read("settings.json"), source)
        XCTAssertEqual(try Settings.decode(Data("  \n".utf8)), Settings())
    }

    func testValuesOfTheWrongTypeAreErrorsNamingTheSetting() throws {
        let directory = try TemporaryDirectory()
        let path = try directory.write("settings.json", #"{"window": {"confirmRunningProcess": "no"}}"#)
        XCTAssertThrowsError(try Settings.load(path)) { error in
            XCTAssertTrue("\(error)".contains("confirmRunningProcess"), "\(error)")
        }
    }

    func testSectionSavesKeepOtherSectionsAndUnknownKeys() throws {
        let directory = try TemporaryDirectory()
        let path = try directory.write("settings.json", #"{"window": {"confirmRunningProcess": false}, "custom": {"keep": true}}"#)
        var settings = try Settings.load(path)
        settings.browser.openTerminalLinks = true
        try settings.saveBrowser(to: path)
        settings.panes.newPaneDirectory = .current
        try settings.savePanes(to: path)
        try settings.setProjectSearchRoot("/code", in: path)
        let loaded = try Settings.load(path)
        XCTAssertEqual(loaded, settings)
        XCTAssertFalse(loaded.window.confirmRunningProcess)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual((object["custom"] as? [String: Bool])?["keep"], true)
        var invalid = settings
        invalid.browser.homePage = "not a page"
        XCTAssertThrowsError(try invalid.saveBrowser(to: path))
        XCTAssertEqual(try Settings.load(path), loaded)
    }

    func testSavingCloseConfirmationPreservesInvalidFilesAndInMemoryPreferences() throws {
        let directory = try TemporaryDirectory()
        for source in ["not valid JSON", #"{"window": "invalid"}"#] {
            let path = try directory.write("settings.json", source)
            var settings = Settings()
            XCTAssertThrowsError(try settings.setConfirmRunningProcess(false, in: path))
            XCTAssertTrue(settings.window.confirmRunningProcess)
            XCTAssertEqual(try directory.read("settings.json"), source)
        }
        let blocked = try directory.write("blocked", "keep this file")
        var settings = Settings()
        XCTAssertThrowsError(try settings.setConfirmRunningProcess(false, in: blocked.appendingPathComponent("settings.json")))
        XCTAssertTrue(settings.window.confirmRunningProcess)
        XCTAssertEqual(try directory.read("blocked"), "keep this file")
    }

    // MARK: Appearance

    func testAppearanceSavesOnlyChangesAndMergesHiddenWorktrees() throws {
        let directory = try TemporaryDirectory()
        let path = try directory.write("settings.json", #"{"appearance": {"sidebarProjectOrder": "name"}, "window": {"confirmRunningProcess": false}}"#)
        var appearance = try Appearance.load(path)
        XCTAssertEqual(appearance.sidebarProjectOrder, .name)
        for order in ProjectOrder.allCases {
            let previous = appearance
            appearance.sidebarProjectOrder = order
            appearance = try appearance.saveChanges(since: previous, to: path)
            let saved = try Settings.load(path)
            XCTAssertEqual(saved.appearance, appearance)
            XCTAssertFalse(saved.window.confirmRunningProcess)
        }

        let first = ProjectId()
        let second = ProjectId()
        let initial = try Appearance.load(path)
        var one = initial
        one.hiddenWorktrees.insert(first)
        try one.saveChanges(since: initial, to: path)
        var two = initial
        two.hiddenWorktrees.insert(second)
        two.sidePanel = .files
        var saved = try two.saveChanges(since: initial, to: path)
        XCTAssertEqual(saved.hiddenWorktrees, [first, second])
        let previousOne = one
        one.hiddenWorktrees.remove(first)
        saved = try one.saveChanges(since: previousOne, to: path)
        XCTAssertEqual(saved.hiddenWorktrees, [second])
        XCTAssertEqual(saved.sidePanel, .files, "another window's change is kept")
        XCTAssertEqual(try Appearance.load(path), saved)
    }

    func testSidebarHostRoundTripsAndMatchesServers() throws {
        let first = ServerId()
        let second = ServerId()
        for (host, expected) in [(SidebarHost.all, [true, true, true]), (.local, [true, false, false]), (.server(first), [false, true, false])] {
            XCTAssertEqual([ServerId.local, first, second].map(host.matches), expected)
            var appearance = Appearance()
            appearance.sidebarHost = host
            XCTAssertEqual(try roundTrip(appearance).sidebarHost, host)
        }
    }

    // MARK: Worktrees

    func testWorktreeTemplatesRequireABranchThatSurvivesNormalization() {
        for template in ["../fixed", "../{branch}/../fixed", "  "] {
            XCTAssertEqual((try? WorktreeLocation(pathTemplate: template).validate()) != nil, template.trimmingCharacters(in: .whitespaces).isEmpty, template)
        }
        XCTAssertNoThrow(try WorktreeLocation(pathTemplate: WorktreeLocation.suggestedTemplate).validate())
        XCTAssertEqual(sanitizedComponent("feature/a b", fallback: "name"), "feature-a-b")
        XCTAssertEqual(sanitizedComponent("..", fallback: "name"), "name")
    }

    func testWorktreeLocationPrecedenceAndSavedPreferences() throws {
        let home = "/Users/dev"
        var settings = Settings()
        let defaultChoice = WorktreeLocation()
        func directory(_ location: WorktreeLocation, name: String = "Feature A") throws -> String {
            try settings.worktrees.directory(projectName: "My Project", projectDirectory: "/code/repo", location: location, name: name, branch: "feature/a", home: home)
        }
        XCTAssertEqual(try directory(defaultChoice), "/Users/dev/.tab/worktrees/My-Project/Feature-A")
        settings.worktrees.defaultLocation.parentPath = "  "
        XCTAssertEqual(try directory(defaultChoice), "/Users/dev/.tab/worktrees/My-Project/Feature-A")
        settings.worktrees.defaultLocation.parentPath = "/trees"
        XCTAssertEqual(try directory(defaultChoice), "/trees/My-Project/Feature-A")
        settings.worktrees.defaultLocation.parentPath = "~/trees"
        XCTAssertEqual(try directory(defaultChoice), "/Users/dev/trees/My-Project/Feature-A")
        settings.worktrees.defaultLocation.parentPath = "/trees"
        XCTAssertEqual(try directory(WorktreeLocation(parentPath: "../trees")), "/code/trees/Feature-A")
        let template = WorktreeLocation(pathTemplate: "../{base-dir}.{branch}/{project-name}")
        XCTAssertEqual(try directory(template, name: "ignored"), "/code/repo.feature-a/My-Project")

        let project = ProjectId()
        settings.worktrees.projects[project] = template
        let files = try TemporaryDirectory()
        let path = files.file("settings.json")
        try settings.saveWorktrees(to: path)
        XCTAssertEqual(try Settings.load(path).worktrees, settings.worktrees)
        settings.worktrees.projects[project] = WorktreeLocation(pathTemplate: "../fixed")
        XCTAssertThrowsError(try settings.saveWorktrees(to: path))
    }

    // MARK: Servers

    private func names(_ settings: Settings) -> [String] { settings.servers.map(\.name) }

    func testServersLoadAndSavesKeepOtherSettingsAndHandEdits() throws {
        let directory = try TemporaryDirectory()
        let path = try directory.write("settings.json", #"{"window": {"confirmRunningProcess": false}, "servers": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "box", "ssh": "dev@box"}]}"#)
        var settings = try Settings.load(path)
        let first = try XCTUnwrap(ServerId("6f9619ff8b86d011b42d00c04fc964ff"))
        XCTAssertEqual(settings.servers, [ServerEntry(id: first, name: "box", ssh: "dev@box")])
        XCTAssertEqual(settings.server(first)?.ssh, "dev@box")

        let build = ServerEntry(name: "build", ssh: "ci@build.example.com")
        try settings.addServer(build, in: path)
        let hand = ServerEntry(name: "hand", ssh: "hand@host")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var servers = try XCTUnwrap(object["servers"] as? [[String: Any]])
        servers.append(["id": hand.id.description, "name": "hand", "ssh": "hand@host"])
        object["servers"] = servers
        try JSONSerialization.data(withJSONObject: object).write(to: path)

        var changed = build
        changed.name = "builder"
        changed.identityFile = "~/.ssh/build key"
        changed.passwordLogin = true
        changed.port = 2222
        try settings.updateServer(changed, in: path)
        XCTAssertEqual(names(settings), ["box", "builder", "hand"])
        let loaded = try Settings.load(path)
        XCTAssertEqual(loaded.servers, settings.servers)
        XCTAssertFalse(loaded.window.confirmRunningProcess)

        try settings.removeServers([first], in: path)
        XCTAssertEqual(names(settings), ["builder", "hand"])
        try settings.removeServers([build.id, hand.id], in: path)
        XCTAssertTrue(settings.servers.isEmpty)
        XCTAssertFalse(try directory.read("settings.json").contains("servers"))
        XCTAssertFalse(try Settings.load(path).window.confirmRunningProcess)
    }

    func testServersArePlacedAndRegroupedInOneWriteInListedOrder() throws {
        let directory = try TemporaryDirectory()
        let path = try directory.write("settings.json", #"{"window": {"confirmRunningProcess": false}}"#)
        var settings = try Settings.load(path)
        let a = ServerEntry(name: "a", ssh: "dev@a")
        let b = ServerEntry(name: "b", ssh: "dev@b", group: "Build")
        let c = ServerEntry(name: "c", ssh: "dev@c", group: "Build")
        let d = ServerEntry(name: "d", ssh: "dev@d", group: "Deploy")
        for entry in [a, b, c, d] { try settings.addServer(entry, in: path) }
        func listed() -> [String] { settings.servers.map { "\($0.name):\($0.group ?? "-")" } }
        try settings.placeServers([d.id], group: "Build", before: c.id, in: path)
        XCTAssertEqual(listed(), ["a:-", "b:Build", "d:Build", "c:Build"])
        try settings.placeServers([a.id, b.id], group: "Deploy", before: nil, in: path)
        XCTAssertEqual(listed(), ["d:Build", "c:Build", "a:Deploy", "b:Deploy"])
        XCTAssertEqual(settings.serverGroups, ["Build", "Deploy"])
        try settings.setServersGroup([c.id, ServerId()], group: nil, in: path)
        XCTAssertEqual(try Settings.load(path).servers, settings.servers)
        let before = try directory.read("settings.json")
        for invalid in ["", " ", "Prod\u{7}", String(repeating: "g", count: 257)] {
            XCTAssertThrowsError(try settings.setServersGroup([a.id], group: invalid, in: path), invalid)
            XCTAssertEqual(try directory.read("settings.json"), before)
        }
    }

    func testCustomCommandsRejectAmbiguousLoginsAndInvalidServersChangeNothing() throws {
        let directory = try TemporaryDirectory()
        let path = try directory.write("settings.json", #"{"window": {"confirmRunningProcess": false}}"#)
        var settings = try Settings.load(path)
        let custom = ServerEntry(name: "VM", ssh: "", sshCommand: "'/Applications/VM Tool/vm' ssh 'dev box' --")
        try settings.addServer(custom, in: path)
        XCTAssertEqual(try Settings.load(path).servers, settings.servers)
        let source = try directory.read("settings.json")
        var invalid: [ServerEntry] = []
        for change in [
            { (entry: inout ServerEntry) in entry.ssh = "box" },
            { $0.identityFile = "key" },
            { $0.passwordLogin = true },
            { $0.port = 22 },
            { $0.sshCommand = "vm 'unterminated" },
            { $0.sshCommand = "" },
            { $0.name = " " },
        ] {
            var entry = custom
            change(&entry)
            invalid.append(entry)
        }
        for entry in invalid {
            XCTAssertThrowsError(try settings.updateServer(entry, in: path))
            XCTAssertEqual(try directory.read("settings.json"), source)
        }
        XCTAssertThrowsError(try settings.addServer(ServerEntry(id: .local, name: "This Mac", ssh: "me@localhost"), in: path))
        XCTAssertThrowsError(try settings.updateServer(ServerEntry(name: "box", ssh: "dev@box"), in: path))
        XCTAssertThrowsError(try settings.addServer(ServerEntry(name: "box", ssh: "dev@box", port: 70000), in: path))
        XCTAssertEqual(try directory.read("settings.json"), source)

        let other = ServerId().description
        for servers in [
            #"[{"id": "\#(ServerId.local)", "name": "This Mac", "ssh": "me@localhost"}]"#,
            #"[{"id": "\#(other)", "name": "a", "ssh": "a@host"}, {"id": "\#(other)", "name": "b", "ssh": "b@host"}]"#,
            #"[{"id": "\#(other)", "name": "box", "ssh": " "}]"#,
            #"[{"id": "box", "name": "box", "ssh": "dev@box"}]"#,
        ] {
            let source = #"{"servers": \#(servers)}"#
            try directory.write("settings.json", source)
            XCTAssertThrowsError(try Settings.load(path), servers)
            XCTAssertEqual(try directory.read("settings.json"), source)
        }
    }

    // MARK: Browser

    func testBrowserSettingsResolveInputAndCheckTheHomePage() throws {
        XCTAssertNil(BrowserSettings().homeURL)
        let directory = try TemporaryDirectory()
        let path = try directory.write("settings.json", #"{"browser": {"searchEngine": "duckDuckGo", "homePage": "example.com"}}"#)
        let settings = try Settings.load(path)
        XCTAssertEqual(settings.browser.homeURL, "https://example.com")
        XCTAssertEqual(settings.browser.resolve("a b"), "https://duckduckgo.com/?q=a+b")
        func resolve(_ input: String) -> String? { BrowserAddress.resolveInput(input, engine: .google) }
        XCTAssertEqual(resolve("https://example.com/a?b=c"), "https://example.com/a?b=c")
        XCTAssertEqual(resolve("example.com/docs"), "https://example.com/docs")
        XCTAssertEqual(resolve("localhost:3000/app"), "http://localhost:3000/app")
        XCTAssertEqual(resolve("127.0.0.1:8080"), "http://127.0.0.1:8080")
        XCTAssertEqual(resolve("192.168.1.2"), "http://192.168.1.2")
        XCTAssertEqual(resolve("about:blank"), "about:blank")
        XCTAssertEqual(resolve("rust lifetimes"), "https://www.google.com/search?q=rust+lifetimes")
        XCTAssertNil(resolve("   "))
        for unsafe in ["javascript:alert(1)", "data:text/html,hi", "file:///etc/passwd"] {
            XCTAssertTrue(resolve(unsafe)?.hasPrefix("https://www.google.com/search?q=") ?? false, unsafe)
        }
        XCTAssertEqual(SearchEngine.duckDuckGo.searchURL("a&b=c ü"), "https://duckduckgo.com/?q=a%26b%3Dc+%C3%BC")
        XCTAssertTrue(BrowserAddress.engineLoads("blob:https://example.com/1"))
        XCTAssertFalse(BrowserAddress.engineLoads("mailto:me@example.com"))
        XCTAssertEqual(BrowserAddress.displayTitle("", url: "https://user@docs.rs:443/x"), "docs.rs")
        XCTAssertNil(BrowserAddress.displayTitle("", url: BrowserAddress.blank))
        XCTAssertEqual(BrowserAddress.zoomIn(2.9), BrowserAddress.maximumZoom)
    }

    // MARK: Proxy

    private func proxy() -> ProxySettings { ProxySettings(host: "proxy.local", port: 8080) }

    func testProxyURLsEscapeCredentialsAndBracketIPv6Hosts() {
        XCTAssertEqual(proxy().url, "http://proxy.local:8080")
        let socks = ProxySettings(kind: .socks5, host: "::1", port: 1080, username: "me@work", password: "p:ss/word")
        XCTAssertEqual(socks.url, "socks5://me%40work:p%3Ass%2Fword@[::1]:1080")
        XCTAssertEqual(socks.urlWithRemoteNames, "socks5h://me%40work:p%3Ass%2Fword@[::1]:1080")
        var userOnly = proxy()
        userOnly.username = "me"
        XCTAssertEqual(userOnly.url, "http://me@proxy.local:8080")
        var withBypass = proxy()
        withBypass.bypass = "localhost, 127.0.0.1  .internal"
        let environment = withBypass.environment
        for name in ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
            XCTAssertEqual(environment[name], "http://proxy.local:8080")
        }
        XCTAssertEqual(environment["no_proxy"], "localhost,127.0.0.1,.internal")
        XCTAssertEqual(proxy().environment["NO_PROXY"], "")
    }

    func testBypassedHostsMatchAsNoProxyDoes() {
        var bypass = proxy()
        bypass.bypass = "localhost, 127.0.0.1 ::1 .internal example.com"
        for host in ["localhost", "127.0.0.1", "::1", "[::1]", "box.internal", "internal", "example.com", "git.EXAMPLE.com"] {
            XCTAssertTrue(bypass.bypasses(host), host)
        }
        for host in ["box.example", "notexample.com", "127.0.0.2", "internal.box"] {
            XCTAssertFalse(bypass.bypasses(host), host)
        }
        for (entry, host, expected) in [
            ("10.20.30.0/24", "10.20.30.255", true), ("10.20.30.100/24", "10.20.30.1", true),
            ("10.20.30.0/24", "10.20.31.0", false), ("10.20.30.0/32", "10.20.30.1", false),
            ("0.0.0.0/0", "192.0.2.1", true), ("0.0.0.0/0", "::1", false),
            ("2001:db8::/33", "2001:db8:7fff::1", true), ("2001:db8::/33", "2001:db8:8000::1", false),
            ("2001:db8::1/128", "[2001:db8::1]", true), ("::/0", "127.0.0.1", false),
            ("127.0.0.0/8", "localhost", false), ("127.0.0.1/33", "127.0.0.1", false),
            ("::1/129", "::1", false), ("::1/-1", "::1", false), ("invalid/8", "127.0.0.1", false),
            ("*", "anything", true),
        ] {
            var settings = proxy()
            settings.bypass = entry
            XCTAssertEqual(settings.bypasses(host), expected, "\(entry): \(host)")
        }
        XCTAssertFalse(proxy().bypasses("localhost"))
    }

    func testInvalidProxiesAreRefusedAndTheFileIsPrivate() throws {
        for change in [
            { (proxy: inout ProxySettings) in proxy.host = "" },
            { $0.host = "http://proxy" },
            { $0.host = " proxy" },
            { $0.port = 0 },
            { $0.host = "proxy.local:3128" },
            { $0.password = "secret" },
            { $0.username = "me\n" },
        ] {
            var invalid = proxy()
            change(&invalid)
            XCTAssertThrowsError(try invalid.validate(), "\(invalid)")
        }
        var ipv6 = proxy()
        ipv6.host = "fe80::1"
        XCTAssertNoThrow(try ipv6.validate())

        let directory = try TemporaryDirectory()
        let path = directory.file("proxy.json")
        XCTAssertNil(try ProxySettings.load(path))
        var saved = proxy()
        saved.username = "me"
        saved.password = "secret"
        saved.global = true
        try saved.save(to: path)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        XCTAssertEqual(try ProxySettings.load(path), saved)
        try ProxySettings.remove(path)
        try ProxySettings.remove(path)
        XCTAssertNil(try ProxySettings.load(path))
        for source in [#"{"username": "me", "password": "FAKE_SECRET" extra}"#, #"{"port": "FAKE_SECRET"}"#] {
            try directory.write("proxy.json", source)
            XCTAssertThrowsError(try ProxySettings.load(path)) { error in
                XCTAssertFalse("\(error)".contains("FAKE_SECRET"))
                XCTAssertTrue("\(error)".contains("invalid proxy settings"))
                XCTAssertTrue("\(error)".contains("proxy.json"))
            }
        }
    }

    // MARK: Terminal

    func testTerminalSettingsRoundTripAndAMissingFileGetsDefaults() throws {
        let directory = try TemporaryDirectory()
        let path = directory.file("terminal.json")
        XCTAssertEqual(try TerminalSettings.load(path), TerminalSettings())
        var settings = TerminalSettings()
        settings.fontFamilies = ["JetBrains Mono", "Symbols Nerd Font"]
        settings.cellHeight = .percent(12.5)
        settings.font.features = [FontFeature("calt", 0), FontFeature("ss01", 1)]
        settings.font.codepoints = [FontMap(start: 0xE000, end: 0xF8FF, family: "Symbols Nerd Font")]
        settings.optionAsAlt = .left
        settings.options.palette[4] = RGBColor(0x112233)
        settings.options.cursorColor = .cellForeground
        settings.options.cursorStyle = .blockHollow
        settings.options.backgroundOpacity = 0.8
        settings.keybindings.clearDefaults = true
        settings.keybindings.bindings[try KeyChord("cmd-shift-=")] = .increaseFontSize(2)
        settings.keybindings.bindings[try KeyChord("shift-enter")] = .text([0x1B, 0x0D])
        try settings.save(to: path)
        XCTAssertEqual(try TerminalSettings.load(path), settings)
        let text = try directory.read("terminal.json")
        XCTAssertTrue(text.contains("cmd+shift+equal=increase_font_size:2"), text)
        XCTAssertTrue(text.contains("12.5%"), text)
    }

    func testTerminalFilesTolerateUnknownKeysAndRejectInvalidValues() throws {
        let loaded = try TerminalSettings.decode(Data(#"{"fontSize": 15, "future": 1, "options": {"cursorStyle": "bar", "newThing": true}}"#.utf8))
        XCTAssertEqual(loaded.fontSize, 15)
        XCTAssertEqual(loaded.options.cursorStyle, .bar)
        XCTAssertEqual(loaded.fontFamilies, ["Menlo"])
        XCTAssertEqual(loaded.optionAsAlt, .both)
        for invalid in [
            #"{"fontSize": 0}"#,
            #"{"fontFamilies": []}"#,
            #"{"cellHeight": "5000"}"#,
            #"{"options": {"background": "blurple"}}"#,
            #"{"options": {"cursorOpacity": 2}}"#,
            #"{"keybindings": ["cmd+k=unknown_action"]}"#,
            #"{"font": {"features": [{"tag": "toolong", "value": 1}]}}"#,
        ] {
            XCTAssertThrowsError(try TerminalSettings.decode(Data(invalid.utf8)), invalid)
        }
    }

    func testInvalidEditsAndCorruptedFilesPreserveSavedPreferences() throws {
        let directory = try TemporaryDirectory()
        let path = directory.file("terminal.json")
        var settings = try TerminalSettings.load(path)
        let saved = try directory.read("terminal.json")
        for (id, value) in [("font-size", "0"), ("cursor-opacity", "150"), ("palette-300", "#ffffff"), ("cursor-style", "triangle"), ("unknown", "1")] {
            XCTAssertThrowsError(try settings.setPreference(id, value), id)
        }
        XCTAssertEqual(settings, TerminalSettings())
        try settings.setPreference("font-size", "16")
        try settings.setPreference("background-transparency", "25")
        try settings.setPreference("font-ligatures", "false")
        try settings.setPreference("palette-1", "#ff0000")
        try settings.setPreference("cursor-style", "underline")
        try settings.setPreference("window-padding-x", "4,8")
        try settings.setPreference("macos-option-as-alt", "right")
        XCTAssertEqual(settings.fontSize, 16)
        XCTAssertEqual(settings.options.backgroundOpacity, 0.75)
        XCTAssertFalse(settings.ligaturesEnabled)
        XCTAssertEqual(settings.options.palette[1], RGBColor(0xFF0000))
        XCTAssertEqual(settings.options.cursorStyle, .underline)
        XCTAssertEqual(settings.options.paddingX, [4, 8])
        XCTAssertEqual(settings.optionAsAlt, .right)

        try directory.write("terminal.json", "{ hand edit gone wrong")
        XCTAssertThrowsError(try settings.save(to: path))
        XCTAssertEqual(try directory.read("terminal.json"), "{ hand edit gone wrong")
        XCTAssertThrowsError(try TerminalSettings.load(path))
        try directory.write("terminal.json", saved)
        try settings.save(to: path)
        XCTAssertEqual(try TerminalSettings.load(path), settings)
    }

    func testInvalidOrConflictingTerminalEditsChangeNothing() throws {
        var settings = TerminalSettings()
        try settings.edit(.fallbacks(["Apple Color Emoji"]))
        XCTAssertEqual(settings.fontFamilies, ["Menlo", "Apple Color Emoji"])
        try settings.edit(.codepointMap(previous: nil, range: "U+E000-U+F8FF,U+F0000", family: "\"Nerd\""))
        XCTAssertEqual(settings.font.codepoints, [
            FontMap(start: 0xE000, end: 0xF8FF, family: "Nerd"),
            FontMap(start: 0xF0000, end: 0xF0000, family: "Nerd"),
        ])
        let before = settings
        XCTAssertThrowsError(try settings.edit(.codepointMap(previous: nil, range: "U+F8FF-U+E000", family: "Nerd")))
        XCTAssertThrowsError(try settings.edit(.codepointMap(previous: FontMap(start: 1, end: 2, family: "x"), range: nil, family: nil)))
        XCTAssertThrowsError(try settings.edit(.fallbacks(["Bad\"Name"])))
        XCTAssertEqual(settings, before)
        let chord = try KeyChord("cmd-shift-k")
        try settings.edit(.binding(previous: nil, chord: chord, action: "csi:2J"))
        XCTAssertEqual(settings.keybindings.action(for: chord), .text([0x1B, 0x5B, 0x32, 0x4A]))
        let bound = settings
        XCTAssertThrowsError(try settings.edit(.binding(previous: nil, chord: chord, action: "clear_screen")))
        XCTAssertThrowsError(try settings.edit(.binding(previous: nil, chord: try KeyChord("cmd-j"), action: "goto_tab:1")))
        XCTAssertEqual(settings, bound)
        try settings.edit(.binding(previous: chord, chord: nil, action: nil))
        XCTAssertNil(settings.keybindings.bindings[chord])
    }

    func testTerminalBindingsReadGhosttySyntaxAndKeepBuiltIns() throws {
        var bindings = TerminalBindings()
        XCTAssertNil(try bindings.read("super+arrow_left=text:\\x01"))
        XCTAssertNil(try bindings.read("ctrl+shift+equal=increase_font_size"))
        XCTAssertNotNil(try bindings.read("ctrl+a>c=new_tab"))
        XCTAssertNotNil(try bindings.read("cmd+t=new_tab"))
        XCTAssertThrowsError(try bindings.read("cmd+t"))
        XCTAssertEqual(bindings.action(for: try KeyChord("cmd-left")), .text([0x01]))
        XCTAssertEqual(bindings.action(for: try KeyChord("ctrl-shift-=")), .increaseFontSize(1))
        XCTAssertEqual(bindings.action(for: try KeyChord("cmd-k")), .clearScreen)
        XCTAssertEqual(bindings.chords(for: .text([0x0A])), [try KeyChord("shift-enter")])
        XCTAssertNotNil(try bindings.read("clear"))
        XCTAssertTrue(bindings.bindings.isEmpty)
        XCTAssertNil(bindings.action(for: try KeyChord("cmd-k")))
        XCTAssertEqual(try roundTrip(bindings), bindings)
        XCTAssertEqual(try TerminalAction.unescape("a\\e\\x1b\\\\"), [0x61, 0x1B, 0x1B, 0x5C])
        XCTAssertEqual(TerminalAction.escape([0x1B, 0x0A, 0x20, 0x7F]), "\\e\\n \\x7f")
        XCTAssertThrowsError(try TerminalAction.unescape("\\q"))
    }

    func testCellHeightsApplyInWholePixels() throws {
        XCTAssertEqual(try CellHeight("0"), .natural)
        XCTAssertEqual(try CellHeight("-2"), .pixels(-2))
        XCTAssertEqual(try CellHeight("10%"), .percent(10))
        XCTAssertThrowsError(try CellHeight("-100%"))
        XCTAssertThrowsError(try CellHeight("5000"))
        XCTAssertEqual(CellHeight.natural.apply(natural: 15.3, scale: 2), 15.5)
        XCTAssertEqual(CellHeight.pixels(2).apply(natural: 15.3, scale: 2), 16.5)
        XCTAssertEqual(CellHeight.percent(10).apply(natural: 10, scale: 2), 11)
        XCTAssertEqual(CellHeight.pixels(-100).apply(natural: 10, scale: 2), 0.5)
        var settings = TerminalSettings()
        settings.zoom(300)
        XCTAssertEqual(settings.fontSize, 256)
    }
}
