import AppKit
import XCTest
@testable import TabApp
import TabClient
import TabCore

final class RemoteServerFormTests: XCTestCase {
    private func form(host: String, user: String = "", port: String = "") -> ServerForm {
        var form = ServerForm()
        form.host = host
        form.user = user
        form.port = port
        return form
    }

    func testDestinationJoinsUserAndKeepsPortApart() throws {
        let entry = try form(host: "devbox", user: "me", port: "2222").entry()
        XCTAssertEqual(entry.ssh, "me@devbox")
        XCTAssertEqual(entry.port, 2222)
        XCTAssertEqual(entry.name, "me@devbox", "a blank name falls back to the destination")
        XCTAssertEqual(try form(host: "ssh://me@devbox:2200").destination(), "ssh://me@devbox:2200")
    }

    func testRefusesAmbiguousOrInvalidLogins() {
        let cases: [(ServerForm, String)] = [
            (form(host: "me@devbox", user: "other"), "Put the user and port either in the host or in their own fields"),
            (form(host: "ssh://devbox", port: "22"), "Put the user and port either in the host or in their own fields"),
            (form(host: "devbox", user: "a@b"), "Enter a user name without @ or :"),
            (form(host: "devbox", port: "70000"), "Use a port from 1 to 65535"),
            (form(host: "devbox", port: "abc"), "Use a port from 1 to 65535"),
            (form(host: "-oProxyCommand=x"), "Enter an SSH host: a ~/.ssh/config alias, a host name, or an address"),
            (form(host: "two words"), "Enter an SSH host: a ~/.ssh/config alias, a host name, or an address"),
            (form(host: "  "), "Enter an SSH host: a ~/.ssh/config alias, a host name, or an address"),
        ]
        for (form, message) in cases {
            XCTAssertThrowsError(try form.entry(), "\(form)") { error in
                XCTAssertEqual((error as? ServerFormError)?.message, message)
            }
        }
    }

    func testCustomCommandDropsSSHOnlyFields() throws {
        var form = form(host: "ignored", user: "me", port: "22")
        form.identityFile = "~/.ssh/id"
        form.passwordLogin = true
        form.customCommand = "  vm ssh 'my box' --  "
        form.group = "  VMs "
        let entry = try form.entry()
        XCTAssertEqual(entry.sshCommand, "vm ssh 'my box' --")
        XCTAssertEqual(entry.ssh, "")
        XCTAssertNil(entry.port)
        XCTAssertNil(entry.identityFile)
        XCTAssertFalse(entry.passwordLogin)
        XCTAssertEqual(entry.group, "VMs")
        form.customCommand = "vm 'unclosed"
        XCTAssertThrowsError(try form.entry())
    }

    func testEditingAnEntryRoundTrips() throws {
        let id = ServerId()
        let entry = ServerEntry(id: id, name: "Dev", ssh: "me@devbox", identityFile: "/k", port: 2222,
                                passwordLogin: true, group: "Work")
        let form = ServerForm(entry)
        XCTAssertEqual(form.host, "devbox")
        XCTAssertEqual(form.user, "me")
        XCTAssertEqual(form.port, "2222")
        XCTAssertEqual(try form.entry(id: id), entry)
        XCTAssertEqual(ServerForm(ServerEntry(name: "U", ssh: "ssh://me@h:22")).host, "ssh://me@h:22")
    }

    func testTargetCarriesPortKeyProxyAndCustomCommand() throws {
        let proxy = ProxyCommand(program: "/Applications/Tab.app/Contents/MacOS/Tab", arguments: ["--proxy"])
        let entry = ServerEntry(name: "Dev", ssh: "me@devbox", identityFile: "/k", port: 2222)
        let target = try ServerForm.target(for: entry, proxy: proxy)
        let arguments = target.arguments(remote: "tab stdio", proxy: target.proxy)
        XCTAssertEqual(target.port, 2222)
        XCTAssertEqual(target.identity, "/k")
        XCTAssertTrue(arguments.contains("-p") && arguments.contains("2222"))
        XCTAssertTrue(arguments.contains("-i") && arguments.contains("/k"))
        XCTAssertTrue(arguments.contains { $0.hasPrefix("ProxyCommand=") })
        XCTAssertEqual(arguments.last, "tab stdio")

        let custom = try ServerForm.target(for: ServerEntry(name: "VM", ssh: "", sshCommand: "vm ssh box --"), proxy: proxy)
        XCTAssertTrue(custom.isCustomCommand)
        XCTAssertEqual(custom.arguments(remote: "tab stdio"), ["ssh", "box", "--", "tab stdio"])
    }

    func testIncompatibleGuidanceNamesTheFix() {
        let same = RemoteRelease.incompatibleGuidance(name: "dev", there: "1.2.0", here: "1.2.0", installable: "1.2.0")
        XCTAssertTrue(same.contains("pkill -x tabd"))
        let older = RemoteRelease.incompatibleGuidance(name: "dev", there: "1.0.0", here: "1.2.0", installable: "1.2.0")
        XCTAssertTrue(older.hasPrefix("Tab on dev is 1.0.0;"))
        XCTAssertTrue(older.contains("--version 1.2.0 --replace"))
        let local = RemoteRelease.incompatibleGuidance(name: "dev", there: nil, here: "0.1.0-dev", installable: nil)
        XCTAssertTrue(local.contains("Install a matching build there by hand."))
        XCTAssertNil(RemoteRelease.installable("0.1.0-dev", debug: false))
        XCTAssertNil(RemoteRelease.installable("1.2.0", debug: true))
        XCTAssertEqual(RemoteRelease.parseVersion("tab 1.2.0\n"), "1.2.0")
    }
}

final class RemoteServerGroupingTests: XCTestCase {
    private func status(_ name: String, _ group: String?, _ state: RemoteServerState = .offline) -> RemoteServerStatus {
        RemoteServerStatus(entry: ServerEntry(name: name, ssh: name, group: group), state: state)
    }

    func testGroupsKeepFirstAppearanceAndUngroupedLast() {
        let servers = [status("a", nil), status("b", "Work"), status("c", "Home"), status("d", "Work")]
        let groups = serversByGroup(servers, entry: \.entry)
        XCTAssertEqual(groups.map(\.group), ["Work", "Home", nil])
        XCTAssertEqual(groups.map { $0.members.map(\.entry.name) }, [["b", "d"], ["c"], ["a"]])
    }

    func testSearchMatchesEveryWordAndDropsEmptyGroups() {
        let servers = [status("build mac", "Work"), status("db", "Work"), status("pi", nil)]
        let shown = shownServers(servers, query: "MAC build")
        XCTAssertEqual(shown.map(\.group), ["Work"])
        XCTAssertEqual(shown.first?.members.map(\.entry.name), ["build mac"])
        XCTAssertEqual(shownServers(servers, query: "work").first?.members.count, 2, "the group name matches too")
    }

    func testShiftClickTicksTheRangeFromTheLastTick() {
        let ids = (0..<5).map { _ in ServerId() }
        var selection = ServerSelection()
        selection.tick(ids[1], range: false, shown: ids)
        selection.tick(ids[3], range: true, shown: ids)
        XCTAssertEqual(Set(selection.ids), Set(ids[1...3]))
        selection.tick(ids[0], range: true, shown: ids)
        XCTAssertEqual(Set(selection.ids), Set(ids[0...3]), "a range never clears ticked boxes")
        selection.tick(ids[2], range: false, shown: ids)
        XCTAssertFalse(selection.contains(ids[2]))
    }

    func testSelectAllTogglesAndRetainDropsHidden() {
        let ids = (0..<3).map { _ in ServerId() }
        var selection = ServerSelection()
        selection.tick(ids[0], range: false, shown: ids)
        selection.tickAll(shown: ids)
        XCTAssertEqual(selection.count, 3)
        XCTAssertNil(selection.anchor)
        selection.tickAll(shown: ids)
        XCTAssertTrue(selection.isEmpty)
        selection.tickAll(shown: ids)
        selection.retain([ids[1]])
        XCTAssertEqual(selection.ids, [ids[1]])
    }

    func testConnectChoiceKeepsLiveConnections() {
        XCTAssertEqual(ConnectChoice([status("a", nil), status("b", nil, .connected)]).title, "Connect")
        XCTAssertEqual(ConnectChoice([status("a", nil), status("b", nil)]).title, "Connect 2 Servers")
        XCTAssertEqual(ConnectChoice([status("a", nil, .connected)]).title, "Reconnect")
        XCTAssertEqual(ConnectChoice([status("a", nil, .connecting), status("b", nil, .connected)]).title,
                       "Reconnect 2 Servers")
    }

    func testMovingLandsAtTheEndOfTheGroup() {
        let a = ServerEntry(name: "a", ssh: "a", group: "Work")
        let b = ServerEntry(name: "b", ssh: "b", group: "Work")
        let c = ServerEntry(name: "c", ssh: "c")
        let d = ServerEntry(name: "d", ssh: "d")
        let entries = [a, b, c, d]
        XCTAssertEqual(RemoteServersModel.insertionPoint(in: entries, moving: [d.id], group: "Work"), c.id)
        XCTAssertNil(RemoteServersModel.insertionPoint(in: entries, moving: [a.id], group: nil))
        XCTAssertNil(RemoteServersModel.insertionPoint(in: entries, moving: [a.id], group: "New"))
    }

    func testFolderBrowserParents() {
        XCTAssertEqual(RemoteFolderBrowser.parent(of: "/Users/me/code/"), "/Users/me")
        XCTAssertEqual(RemoteFolderBrowser.parent(of: "/Users"), "/")
        XCTAssertNil(RemoteFolderBrowser.parent(of: "/"))
        XCTAssertEqual(RemoteFolderBrowser.name(of: "/Users/me/code"), "code")
    }
}

/// Stands in for the shell.
@MainActor
final class FakeRemoteHost: RemoteServersHost {
    var remoteServersWindow: NSWindow? { nil }
    let settingsURL: URL
    var sshProxy: ProxyCommand?
    var snapshots: [ServerId: RemoteConnectionSnapshot] = [:]
    var connects: [(ServerId, Bool)] = []
    var disconnects: [ServerId] = []
    var lists: [[ServerEntry]] = []
    var forgotten: [ServerId] = []

    init(settingsURL: URL) { self.settingsURL = settingsURL }

    func remoteConnection(_ server: ServerId) -> RemoteConnectionSnapshot { snapshots[server] ?? .offline }
    func connectRemoteServer(_ server: ServerId, fresh: Bool) { connects.append((server, fresh)) }
    func disconnectRemoteServer(_ server: ServerId) { disconnects.append(server) }
    func remoteServerAPI(_ server: ServerId) -> ServerAPI? { nil }
    func remoteServerListDidChange(_ servers: [ServerEntry]) { lists.append(servers) }
    func forgetProjects(on servers: [ServerId]) { forgotten += servers }
    func openRemoteHome(on server: ServerId) {}
    func addRemoteProject(on server: ServerId) {}
    func showRemoteServersPane() {}
    func showRemoteError(_ message: String) {}
}

@MainActor
final class RemoteServersModelTests: XCTestCase {
    private var folder: URL!
    private var askpass: AskpassServer!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        askpass = AskpassServer(socket: URL(fileURLWithPath: "/tmp/tab-ap-\(UInt32.random(in: 0...UInt32.max)).sock"),
                                program: "/usr/bin/false")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: askpass.socket)
    }

    private func unreachableTools() -> RemoteServersModel.Tools {
        RemoteServersModel.Tools(
            connect: { target in
                throw ClientError.remote(RemoteFailure(reason: .notInstalled, destination: target.description, detail: ""))
            },
            run: { _, _ in "" },
            login: { _ in "me@devbox" }
        )
    }

    func testConnectorStopsForAMissingPasswordAndForgetsARefusedOne() async throws {
        let entry = ServerEntry(name: "Dev", ssh: "me@devbox", passwordLogin: true)
        let refused = ClientError.remote(RemoteFailure(reason: .authenticationFailed, destination: "devbox", detail: ""))
        let opened = OpenedTargets()
        let connector = RemoteServerConnector(entry: entry, askpass: askpass, proxy: nil,
                                              login: { _ in "me@devbox" },
                                              open: { target in
                                                  await opened.add(target)
                                                  throw refused
                                              })
        do {
            _ = try await connector.connect()
            XCTFail("connecting without a password must fail")
        } catch let error as ClientError {
            guard case .remote(let failure) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(failure.reason, .passwordNeeded)
            XCTAssertFalse(error.recoverable, "the shell's backoff stops until the user types it")
        }
        let opens = await opened.targets
        XCTAssertTrue(opens.isEmpty, "ssh never runs without the password")

        try askpass.setPassword("secret", for: entry.id.description)
        do {
            _ = try await connector.connect()
            XCTFail("the fake refuses the login")
        } catch let error as ClientError {
            XCTAssertEqual(error, refused)
            XCTAssertFalse(error.recoverable)
        }
        let target = await opened.targets.first
        XCTAssertEqual(target?.askpass?.environment[AskpassServer.tokenVariable] != nil, true)
        XCTAssertFalse(askpass.hasPassword(for: entry.id.description), "a refused password is asked again")
    }

    func testStateMapsFailuresToAttentionAndRetries() {
        let id = ServerId()
        let host = FakeRemoteHost(settingsURL: folder.appendingPathComponent("settings.json"))
        let model = RemoteServersModel(entries: [ServerEntry(id: id, name: "Dev", ssh: "devbox")], askpass: askpass,
                                       tools: unreachableTools())
        model.host = host
        let hostKey = ClientError.remote(RemoteFailure(reason: .hostKeyChanged, destination: "devbox", detail: ""))
        host.snapshots[id] = RemoteConnectionSnapshot(.needsUser(hostKey.description), failure: hostKey)
        var status = model.status(of: id)
        XCTAssertEqual(status?.glyph, .needsAttention)
        XCTAssertEqual(status?.failure, .hostKeyChanged)
        XCTAssertFalse(status?.waitingToRetry ?? true)

        host.snapshots[id] = RemoteConnectionSnapshot(.reconnecting(attempt: 2), failure: .disconnected)
        status = model.status(of: id)
        XCTAssertTrue(status?.waitingToRetry ?? false)
        XCTAssertEqual(status?.state, .offline)

        host.snapshots[id] = RemoteConnectionSnapshot(.ready, failure: nil)
        XCTAssertEqual(model.status(of: id)?.glyph, .connected)
        XCTAssertNil(model.status(of: id)?.detail)
    }

    func testDisconnectCancelsAScheduledReconnect() throws {
        let entry = ServerEntry(name: "Dev", ssh: "devbox")
        let host = FakeRemoteHost(settingsURL: folder.appendingPathComponent("settings.json"))
        let model = RemoteServersModel(entries: [entry], askpass: askpass, tools: unreachableTools())
        model.host = host
        host.snapshots[entry.id] = RemoteConnectionSnapshot(.reconnecting(attempt: 3), failure: .disconnected)
        let controller = RemoteServersController(model: model)
        XCTAssertTrue(try XCTUnwrap(controller.serverMenu(entry.id)).items.contains { $0.title == "Disconnect" })
        model.disconnect([entry.id])
        XCTAssertEqual(host.disconnects, [entry.id])
        host.snapshots[entry.id] = .offline
        model.disconnect([entry.id])
        XCTAssertEqual(host.disconnects, [entry.id])
    }

    func testARefusedSavedPasswordIsForgottenByTestConnection() async throws {
        let entry = ServerEntry(name: "Dev", ssh: "me@devbox", passwordLogin: true)
        try askpass.setPassword("refused-secret", for: entry.id.description)
        let tools = RemoteServersModel.Tools(
            connect: { _ in
                throw ClientError.remote(RemoteFailure(reason: .authenticationFailed, destination: "devbox", detail: ""))
            }, run: { _, _ in "" }, login: { _ in "me@devbox" }
        )
        let model = RemoteServersModel(entries: [entry], askpass: askpass, tools: tools)
        let form = ServerForm(entry)
        model.testConnection(form, id: entry.id)
        for _ in 0..<100 where model.testResult(for: form) == .testing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .failed? = model.testResult(for: form) else { return XCTFail("The login must fail") }
        XCTAssertFalse(askpass.hasPassword(for: entry.id.description))
    }

    func testConnectionResultsCannotApproveChangedCredentials() async throws {
        let model = RemoteServersModel(entries: [], askpass: askpass, tools: unreachableTools())
        var form = ServerForm()
        form.host = "devbox"
        model.testConnection(form, id: nil)
        for _ in 0..<100 where model.testResult(for: form) == .testing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(model.testResult(for: form))
        form.identityFile = "/different/key"
        XCTAssertNil(model.testResult(for: form))
        form.identityFile = ""
        form.passwordLogin = true
        XCTAssertNil(model.testResult(for: form))
        form.passwordLogin = false
        form.password = "different-secret"
        XCTAssertNil(model.testResult(for: form))
    }

    func testOnlyTheFirstServerNeedingAPasswordAsks() {
        let plain = ServerEntry(name: "A", ssh: "a")
        let first = ServerEntry(name: "B", ssh: "b", passwordLogin: true)
        let second = ServerEntry(name: "C", ssh: "c", passwordLogin: true)
        let host = FakeRemoteHost(settingsURL: folder.appendingPathComponent("settings.json"))
        let model = RemoteServersModel(entries: [plain, first, second], askpass: askpass, tools: unreachableTools())
        model.host = host
        var asked: [ServerId] = []
        model.askPassword = { asked.append($0) }
        model.reconnect([plain.id, first.id, second.id])
        XCTAssertEqual(host.connects.map(\.0), [plain.id])
        XCTAssertEqual(asked, [first.id])
        XCTAssertEqual(model.status(of: first.id)?.label, "Password needed")
        XCTAssertEqual(model.status(of: first.id)?.glyph, .needsAttention)
    }

    func testSavingEditingMovingAndForgettingWriteSettings() throws {
        let url = folder.appendingPathComponent("settings.json")
        let host = FakeRemoteHost(settingsURL: url)
        let model = RemoteServersModel(entries: [], askpass: askpass, tools: unreachableTools())
        model.host = host
        var form = ServerForm()
        form.host = "devbox"
        form.passwordLogin = true
        form.password = "secret"
        let id = try model.save(form, id: nil)
        XCTAssertTrue(askpass.hasPassword(for: id.description), "the typed password is kept in memory")
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("secret"), "never in settings.json")

        form.passwordLogin = false
        form.name = "Dev"
        try model.save(form, id: id)
        XCTAssertFalse(askpass.hasPassword(for: id.description))
        XCTAssertEqual(try Settings.load(url).servers.map(\.name), ["Dev"])

        try model.move([id], toGroup: " Work ")
        XCTAssertEqual(model.groups, ["Work"])
        try model.regroup([id], as: "Lab")
        XCTAssertEqual(try Settings.load(url).servers.first?.group, "Lab")

        model.selection.tick(id, range: false, shown: [id])
        try model.forget([id])
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(host.forgotten, [id])
        XCTAssertEqual(host.lists.count, 5)
    }

    func testBulkGroupingAndForgetPreserveUnrelatedSettings() throws {
        let url = folder.appendingPathComponent("settings.json")
        try Data(#"{"futureSetting":{"keep":"unchanged"}}"#.utf8).write(to: url)
        let host = FakeRemoteHost(settingsURL: url)
        let model = RemoteServersModel(entries: [], askpass: askpass, tools: unreachableTools())
        model.host = host
        var form = ServerForm()
        form.host = "first"
        let first = try model.save(form, id: nil)
        form.host = "second"
        let second = try model.save(form, id: nil)
        try model.move([first, second], toGroup: "Work")
        XCTAssertEqual(try Settings.load(url).servers.map(\.group), ["Work", "Work"])
        try model.regroup([first, second], as: "Renamed")
        XCTAssertEqual(model.groups, ["Renamed"])
        try model.regroup([first, second], as: nil)
        XCTAssertEqual(model.entries.count, 2, "deleting a group keeps its servers")
        try model.forget([first, second])
        XCTAssertTrue(try Settings.load(url).servers.isEmpty)
        XCTAssertEqual(host.forgotten, [first, second])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["futureSetting"] as? [String: String], ["keep": "unchanged"])
    }

    func testTestConnectionExplainsAMissingInstall() async throws {
        let model = RemoteServersModel(entries: [], askpass: askpass, tools: unreachableTools())
        var form = ServerForm()
        form.host = "devbox"
        model.testConnection(form, id: nil)
        XCTAssertEqual(model.testResult(for: form), .testing)
        for _ in 0..<100 where model.testResult(for: form) == .testing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .notInstalled? = model.testResult(for: form) else {
            return XCTFail("\(String(describing: model.testResult(for: form)))")
        }
        form.host = "other"
        XCTAssertNil(model.testResult(for: form), "a result shows only for the form it tried")

        form.passwordLogin = true
        model.testConnection(form, id: nil)
        XCTAssertEqual(model.testResult(for: form), .failed("Enter the password to test logging in with it."))
    }
}

private actor OpenedTargets {
    var targets: [SSHTarget] = []
    func add(_ target: SSHTarget) { targets.append(target) }
}
