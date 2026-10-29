import AppKit
import Combine
import TabClient
import TabCore

/// The remote servers listed in `settings.json` as the app manages them:
/// their states for the host menu and the pane, editing the list, passwords
/// kept in memory, Test Connection, installing Tab there, and restarting or
/// stopping the server there. The shell creates one at launch, builds its
/// remote connections with `connector(for:)`, and calls
/// `connectionsDidChange()` whenever a connection's state changes.
@MainActor
public final class RemoteServersModel {
    public weak var host: RemoteServersHost?
    /// Answers ssh's password prompts from memory.
    public let askpass: AskpassServer
    /// Sent after any change to the list, a state, the selection or a test.
    public let changes = PassthroughSubject<Void, Never>()
    /// The servers ticked in the Remote Servers pane.
    public var selection = ServerSelection() { didSet { changes.send() } }
    /// The last Test Connection: what it tried, and how it went.
    public private(set) var test: (key: String, result: ConnectionTest)?

    public private(set) var entries: [ServerEntry]
    private var installs: [ServerId: RemoteInstallState] = [:]
    /// Restarting or stopping at the user's request, until the connection drops.
    private var stopping: [ServerId: RemoteServerState] = [:]
    /// The version installed on an incompatible server, once read.
    private var versionsThere: [ServerId: String] = [:]
    private var versionReads: Set<ServerId> = []
    private var testGeneration = 0
    let tools: Tools

    /// How the model reaches a server outside the shell's connections;
    /// tests replace it.
    struct Tools {
        var connect: @Sendable (SSHTarget) async throws -> ServerAPI
        var run: @Sendable (SSHTarget, String) async throws -> String
        var login: @Sendable (SSHTarget) async throws -> String

        static let live = Tools(
            connect: { try await RemoteServer.connect($0, start: .ifNeeded, kind: .desktop) },
            run: { target, command in try await RemoteServersModel.run(command, on: target) },
            login: { target in try await Task.detached { try target.login() }.value }
        )
    }

    public convenience init(entries: [ServerEntry], askpass: AskpassServer, host: RemoteServersHost? = nil) {
        self.init(entries: entries, askpass: askpass, tools: .live)
        self.host = host
    }

    init(entries: [ServerEntry], askpass: AskpassServer, tools: Tools) {
        self.entries = entries
        self.askpass = askpass
        self.tools = tools
    }

    // MARK: Reading

    /// Every listed server with its state, in the listed order.
    public var servers: [RemoteServerStatus] { entries.map(status) }

    /// Every group a server is in, in listed order.
    public var groups: [String] {
        var groups: [String] = []
        for group in entries.compactMap(\.group) where !groups.contains(group) { groups.append(group) }
        return groups
    }

    /// Every server in the order the popover and the pane list them.
    public var listedIDs: [ServerId] {
        serversByGroup(entries) { $0 }.flatMap { $0.members.map(\.id) }
    }

    public func status(of id: ServerId) -> RemoteServerStatus? {
        entry(id).map(status)
    }

    public func entry(_ id: ServerId) -> ServerEntry? {
        entries.first { $0.id == id }
    }

    /// The servers of `group`, or the ungrouped ones, in listed order.
    public func members(ofGroup group: String?) -> [ServerId] {
        listedIDs.filter { entry($0)?.group == group }
    }

    /// It logs in with a password that hasn't been typed this session.
    public func needsPassword(_ id: ServerId) -> Bool {
        guard let entry = entry(id), entry.passwordLogin, entry.sshCommand == nil else { return false }
        return !askpass.hasPassword(for: id.description)
    }

    private func status(_ entry: ServerEntry) -> RemoteServerStatus {
        let snapshot = host?.remoteConnection(entry.id) ?? .offline
        let id = entry.id
        var status = RemoteServerStatus(
            entry: entry, state: stopping[id] ?? snapshot.state, needsPassword: needsPassword(id),
            install: installs[id], waitingToRetry: snapshot.retrying
        )
        guard snapshot.state == .offline, let failure = snapshot.failure else { return status }
        guard case .remote(let remote) = failure else {
            status.error = failure.description
            return status
        }
        status.failure = remote.reason
        switch remote.reason {
        case .passwordNeeded:
            status.error = nil
        case .authenticationFailed where entry.passwordLogin:
            status.error = "\(entry.name) didn't accept the password."
        case .incompatible:
            status.error = RemoteRelease.incompatibleGuidance(name: entry.name, there: versionsThere[id])
        default:
            status.error = failure.description
        }
        return status
    }

    // MARK: The shell's connections

    /// The connector the shell's `ServerConnection` uses for `entry`.
    public func connector(for entry: ServerEntry) -> ServerConnector {
        RemoteServerConnector(entry: entry, askpass: askpass, proxy: host?.sshProxy)
    }

    /// The shell calls this when a connection's state changed.
    public func connectionsDidChange() {
        for (id, _) in stopping where host?.remoteConnection(id).state != .connected {
            stopping[id] = nil
        }
        for entry in entries {
            guard case .remote(let failure)? = host?.remoteConnection(entry.id).failure,
                  failure.reason == .incompatible else {
                versionReads.remove(entry.id)
                continue
            }
            readVersionThere(entry)
        }
        changes.send()
    }

    /// Takes in the list as `settings.json` holds it now, such as after a
    /// hand edit. The shell syncs its connections itself.
    public func sync(_ listed: [ServerEntry]) {
        for old in entries where !listed.contains(where: { $0.id == old.id }) {
            askpass.forgetPassword(for: old.id.description)
            installs[old.id] = nil
            stopping[old.id] = nil
            versionsThere[old.id] = nil
        }
        entries = listed
        selection.retain(listed.map(\.id))
        changes.send()
    }

    // MARK: Connecting

    /// Connects the servers that are offline. Only the first one whose
    /// password isn't known yet asks for it.
    public func connect(_ ids: [ServerId]) {
        reconnect(ids.filter { status(of: $0)?.state == .offline })
    }

    /// Connects, or connects again, each of `ids`: a fresh SSH login and
    /// server check. Only the first one needing a password asks for it.
    public func reconnect(_ ids: [ServerId]) {
        let listed = ids.filter { entry($0) != nil }
        let asking = listed.filter(needsPassword)
        for id in listed where !asking.contains(id) {
            host?.connectRemoteServer(id, fresh: true)
        }
        if let first = asking.first { askPassword(first) }
        changes.send()
    }

    /// Hangs up, without ending terminals there.
    public func disconnect(_ ids: [ServerId]) {
        for id in ids where stopping[id] == nil && status(of: id)?.state != .offline {
            host?.disconnectRemoteServer(id)
        }
        changes.send()
    }

    /// Keeps a typed password until Tab quits, then connects with it.
    public func setPassword(_ password: String, for id: ServerId) {
        do {
            try askpass.setPassword(password, for: id.description)
        } catch {
            host?.showRemoteError("Could not take the password: \(error.localizedDescription)")
            return
        }
        host?.connectRemoteServer(id, fresh: true)
        changes.send()
    }

    /// Asks for `id`'s password; the UI layer sets it.
    public var askPassword: (ServerId) -> Void = { _ in }

    // MARK: Editing the list

    /// Adds a server, or edits the one with `id`. A typed password is kept
    /// in memory first; if it can't be, nothing is saved.
    @discardableResult
    public func save(_ form: ServerForm, id: ServerId?) throws -> ServerId {
        if let id, entry(id) == nil { throw ServerFormError("This remote server is no longer listed") }
        let entry = try form.entry(id: id)
        let key = entry.id.description
        if entry.passwordLogin && !form.password.isEmpty {
            try askpass.setPassword(form.password, for: key)
        }
        do {
            try editList { settings, url in
                if id == nil {
                    try settings.addServer(entry, in: url)
                } else {
                    try settings.updateServer(entry, in: url)
                }
            }
        } catch {
            if id == nil { askpass.forgetPassword(for: key) }
            throw error
        }
        if !entry.passwordLogin { askpass.forgetPassword(for: key) }
        return entry.id
    }

    /// Removes servers from settings in one write, and their projects and
    /// layouts from this app. Nothing on those computers changes.
    public func forget(_ ids: [ServerId]) throws {
        try editList { settings, url in try settings.removeServers(ids, in: url) }
        host?.forgetProjects(on: ids)
    }

    /// Moves servers to the end of `group`, or of the ungrouped.
    public func move(_ ids: [ServerId], toGroup group: String?) throws {
        let group = group.flatMap(ServerForm.groupName)
        let before = Self.insertionPoint(in: entries, moving: ids, group: group)
        try editList { settings, url in try settings.placeServers(ids, group: group, before: before, in: url) }
    }

    /// Where `ids` go to land at the end of `group`: before the first server
    /// staying put after that group's last member.
    nonisolated static func insertionPoint(in entries: [ServerEntry], moving ids: [ServerId], group: String?) -> ServerId? {
        guard let last = entries.lastIndex(where: { $0.group == group && !ids.contains($0.id) }) else { return nil }
        return entries[(last + 1)...].first { !ids.contains($0.id) }?.id
    }

    /// Renames a group, or ungroups its servers, where they are listed.
    public func regroup(_ ids: [ServerId], as group: String?) throws {
        let group = group.flatMap(ServerForm.groupName)
        try editList { settings, url in try settings.setServersGroup(ids, group: group, in: url) }
    }

    private func editList(_ change: (inout Settings, URL) throws -> Void) throws {
        guard let url = host?.settingsURL else { throw ServerFormError("Settings aren't available") }
        var settings = Settings()
        settings.servers = entries
        try change(&settings, url)
        sync(settings.servers)
        host?.remoteServerListDidChange(settings.servers)
    }

    // MARK: The server there

    /// Restarts or stops the Tab server there. Every terminal there ends; a
    /// stopped server is hung up so it waits for Connect instead of being
    /// started again by a reconnect.
    public func controlServer(_ id: ServerId, restart: Bool) {
        guard stopping[id] == nil, let api = host?.remoteServerAPI(id) else { return }
        stopping[id] = restart ? .restarting : .stopping
        changes.send()
        Task { [weak self] in
            do {
                if restart {
                    try await api.restartServer()
                } else {
                    _ = try await api.stopServer(force: true)
                    self?.host?.disconnectRemoteServer(id)
                }
            } catch let error as ClientError where error == .disconnected {
                if !restart { self?.host?.disconnectRemoteServer(id) }
            } catch {
                self?.stopping[id] = nil
                self?.host?.showRemoteError(error.localizedDescription)
                self?.changes.send()
            }
        }
    }

    /// Installs this release there over its SSH login, then connects. It
    /// runs off the main thread; downloading takes a while.
    public func install(_ id: ServerId) {
        guard let entry = entry(id), let version = RemoteRelease.installableVersion,
              installs[id] != .running else { return }
        installs[id] = .running
        changes.send()
        let connector = RemoteServerConnector(entry: entry, askpass: askpass, proxy: host?.sshProxy,
                                              login: tools.login, open: tools.connect)
        let run = tools.run
        Task { [weak self] in
            let result: Result<Void, Error>
            do {
                _ = try await run(try await connector.target(), try RemoteInstall.command(version: version))
                result = .success(())
            } catch {
                result = .failure(error)
            }
            guard let self, self.entry(id) != nil else { return }
            switch result {
            case .success:
                self.installs[id] = nil
                self.host?.connectRemoteServer(id, fresh: true)
            case .failure(let error):
                self.installs[id] = .failed(error.localizedDescription)
            }
            self.changes.send()
        }
    }

    /// Copies the command that updates Tab on an incompatible server.
    public func copyUpdateCommand() {
        guard let version = RemoteRelease.installableVersion else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(RemoteRelease.updateCommand(version: version), forType: .string)
    }

    /// Reads the version installed on an incompatible server once, to name
    /// it in the explanation. Password logins aren't asked again for this.
    private func readVersionThere(_ entry: ServerEntry) {
        guard !versionReads.contains(entry.id), !needsPassword(entry.id) else { return }
        versionReads.insert(entry.id)
        let connector = RemoteServerConnector(entry: entry, askpass: askpass, proxy: host?.sshProxy,
                                              login: tools.login, open: tools.connect)
        let run = tools.run
        Task { [weak self] in
            guard let printed = try? await run(try await connector.target(), RemoteRelease.versionCommand) else { return }
            let version = RemoteRelease.parseVersion(printed)
            guard let self, !version.isEmpty, self.entry(entry.id) != nil else { return }
            self.versionsThere[entry.id] = version
            self.changes.send()
        }
    }

    // MARK: Test Connection

    /// The last test's result, if it tried this form.
    public func testResult(for form: ServerForm) -> ConnectionTest? {
        guard let test, test.key == form.probeKey else { return nil }
        return test.result
    }

    public func clearTest() {
        testGeneration += 1
        guard test != nil else { return }
        test = nil
        changes.send()
    }

    /// Tests the form before it is saved: connects as the app would,
    /// starting the server there if needed, then hangs up. A typed password
    /// is answered only while the test runs. `trust` approves the host key
    /// the last test showed; `install` installs Tab there first.
    public func testConnection(_ form: ServerForm, id: ServerId?, trust: Bool = false, install: Bool = false) {
        var approved: String?
        if trust, case .untrustedHost(let prompt)? = testResult(for: form) { approved = prompt }
        testGeneration += 1
        let generation = testGeneration
        let key = form.probeKey
        let entry: ServerEntry
        do {
            entry = try form.entry(id: id)
        } catch {
            finishTest(key, .failed(error.localizedDescription), generation: generation)
            return
        }
        let usesPassword = entry.passwordLogin && entry.sshCommand == nil
        let typed = form.password.isEmpty ? nil : form.password
        let saved = id.map(\.description).flatMap { askpass.hasPassword(for: $0) ? $0 : nil }
        if usesPassword && typed == nil && saved == nil {
            finishTest(key, .failed("Enter the password to test logging in with it."), generation: generation)
            return
        }
        test = (key, install ? .installing : .testing)
        changes.send()
        let probe = TestProbe(entry: entry, typedPassword: typed, savedPasswordOwner: saved, approvedHostKey: approved,
                              install: install, proxy: host?.sshProxy, askpass: askpass, tools: tools)
        Task { [weak self] in
            let result = await probe.run()
            self?.finishTest(key, result, generation: generation)
        }
    }

    private func finishTest(_ key: String, _ result: ConnectionTest, generation: Int) {
        guard generation == testGeneration else { return }
        test = (key, result)
        changes.send()
    }

    // MARK: Running commands there

    /// Runs `command` there through the same login as the bridge and returns
    /// what it printed; a failure throws the last line of its output.
    nonisolated static func run(_ command: String, on target: SSHTarget) async throws -> String {
        let process = try target.process(remote: command)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        return try await Task.detached {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else { throw RemoteInstallError.failed(lastLine(text)) }
            return text
        }.value
    }
}

/// One Test Connection, run off the main actor.
struct TestProbe: Sendable {
    let entry: ServerEntry
    let typedPassword: String?
    /// The server whose password typed earlier this session answers.
    let savedPasswordOwner: String?
    let approvedHostKey: String?
    let install: Bool
    let proxy: ProxyCommand?
    let askpass: AskpassServer
    let tools: RemoteServersModel.Tools

    func run() async -> ConnectionTest {
        let probe = "test-\(UUID().uuidString)"
        defer { askpass.forgetPassword(for: probe) }
        let owner = typedPassword == nil ? (savedPasswordOwner ?? probe) : probe
        var target: SSHTarget
        do {
            target = try ServerForm.target(for: entry, proxy: proxy)
            if !target.isCustomCommand {
                target.hostKeyPrompt = true
                let login = entry.passwordLogin ? try await tools.login(target) : nil
                if let typedPassword { try askpass.setPassword(typedPassword, for: probe) }
                target.askpass = try askpass.askpassWithHostKey(for: owner, login: login, approved: approvedHostKey)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
        if install {
            guard let version = RemoteRelease.installableVersion else {
                return .installFailed(RemoteInstallError.notARelease(Release.version).description)
            }
            do {
                _ = try await tools.run(target, try RemoteInstall.command(version: version))
            } catch {
                return .installFailed(error.localizedDescription)
            }
        }
        do {
            let client = try await tools.connect(target)
            let version = client.server.build.version
            client.close()
            return .succeeded(version)
        } catch {
            return await explain(ClientError.wrapping(error), target: target, owner: owner)
        }
    }

    private func explain(_ error: ClientError, target: SSHTarget, owner: String) async -> ConnectionTest {
        guard case .remote(let failure) = error else { return .failed(error.description) }
        switch failure.reason {
        case .hostKeyUnknown:
            if let offered = askpass.offeredHostKey(for: owner) { return .untrustedHost(offered) }
        case .notInstalled:
            return .notInstalled(failure.description)
        case .incompatible:
            let printed = try? await tools.run(target, RemoteRelease.versionCommand)
            let there = printed.map(RemoteRelease.parseVersion).flatMap { $0.isEmpty ? nil : $0 }
            return .failed(RemoteRelease.incompatibleGuidance(name: entry.name, there: there))
        default:
            break
        }
        return .failed(error.description)
    }
}
