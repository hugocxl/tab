import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class UpdaterLifecycleTests: XCTestCase {
    private func fixture(
        operations: UpdaterOperations = .init(validate: { _ in }, install: { _, _ in }),
        settings: UpdateSettings = UpdateSettings(automaticInstall: false, automaticServerRestart: false),
        includePrepared: Bool = true,
        settleDelay: TimeInterval = 0.05,
        appVersion: String = Release.version
    ) throws -> (UpdaterController, UpdateHostFixture, UpdateCallLog, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-update-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let installation = Installation(bundle: root.appendingPathComponent("Tab.app"), team: "TESTTEAM00")
        let update = PreparedUpdate(manifest: .init(version: "99.0.0", url: URL(string: "https://example.com/update.zip")!,
                                                    sha256: "", protocolVersions: [ProtocolVersion(1)]),
                                    installation: installation,
                                    staging: root.appendingPathComponent(".tab-update-test"))
        let log = UpdateCallLog()
        var operations = operations
        let validate = operations.validate
        let install = operations.install
        operations.validate = { update in log.append("validate"); try validate(update) }
        operations.install = { update, relaunch in
            switch relaunch {
            case .open: log.append("install")
            case .quietly(let presentation): log.append("install-quiet-\(presentation.rawValue)")
            case .none: log.append("install-at-quit")
            }
            try install(update, relaunch)
        }
        let host = UpdateHostFixture(log: log)
        let controller = UpdaterController(
            host: host,
            dirs: TabDirs(root: root),
            prepared: includePrepared ? update : nil,
            installation: installation,
            settings: settings,
            settleDelay: settleDelay,
            appVersion: appVersion,
            operations: operations
        )
        return (controller, host, log, root)
    }

    private func settled(_ controller: UpdaterController) async throws {
        for _ in 0..<200 {
            if !controller.isInstalling { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Install did not settle")
    }

    func testSaveFailurePreventsValidationServerStopAndReplacement() async throws {
        let (controller, host, log, _) = try fixture()
        host.prepare = { throw UpdateError.install("Draft disk is full") }
        controller.handle(.update)
        try await settled(controller)
        XCTAssertEqual(log.values, ["save"])
        XCTAssertNotNil(controller.prepared)
        XCTAssertTrue(controller.chip?.message.contains("Draft disk is full") == true)
    }

    func testUnsavedEditorsLeaveDownloadReady() async throws {
        let (controller, host, log, _) = try fixture()
        host.prepare = { false }
        controller.handle(.update)
        try await settled(controller)
        XCTAssertEqual(log.values, ["save"])
        XCTAssertEqual(controller.status, .ready(version: "99.0.0"))
        XCTAssertTrue(controller.chip?.message.contains("unsaved changes") == true)
    }

    func testCancelledQuitRetriesOnlyQuitNotTheCompletedInstallation() async throws {
        let (controller, host, log, _) = try fixture()
        controller.handle(.update)
        try await settled(controller)
        XCTAssertEqual(controller.status, .installed(version: "99.0.0"))
        XCTAssertEqual(log.values, ["save", "validate", "install", "quit"])
        XCTAssertNil(controller.prepared)
        controller.checkForUpdates()
        controller.handle(.update)
        XCTAssertEqual(log.values, ["save", "validate", "install", "quit", "quit"])
        XCTAssertEqual(host.runningSessionCount, 2)
        XCTAssertFalse(controller.canRestartServer)
    }

    func testInvalidStagingOffersRedownloadBeforeStoppingTheServer() async throws {
        let operations = UpdaterOperations(validate: { _ in throw UpdateError.invalidBundle("Staging was removed") }, install: { _, _ in })
        let (controller, host, log, _) = try fixture(operations: operations)
        host.localServerBuild = BuildInfo(version: "1.0.0", protocolVersions: [ProtocolVersion(2)])
        host.runningSessionCount = 0
        controller.handle(.update)
        try await settled(controller)
        XCTAssertEqual(log.values, ["save", "validate"])
        XCTAssertNil(controller.prepared)
        XCTAssertEqual(controller.available?.version, "99.0.0")
        XCTAssertEqual(controller.chip?.button?.action, .download)
    }

    func testIdleServerRefusalDoesNotForceStopAgents() async throws {
        let (controller, host, log, _) = try fixture()
        host.localServerBuild = BuildInfo(version: "1.0.0", protocolVersions: [ProtocolVersion(2)])
        host.runningSessionCount = 0
        host.stopsWhenIdle = false
        controller.handle(.update)
        try await settled(controller)
        XCTAssertEqual(log.values, ["save", "validate", "stopIdle"])
        XCTAssertTrue(controller.chip?.message.contains("agents") == true)
        XCTAssertNotNil(controller.prepared)
    }

    func testIncompatibleUpdateWithOnlyAgentsRequiresConfirmation() async throws {
        let (controller, host, log, _) = try fixture()
        host.localServerBuild = BuildInfo(version: "1.0.0", protocolVersions: [ProtocolVersion(2)])
        host.runningSessionCount = 0
        host.runningAgentCount = 1
        controller.handle(.update)
        XCTAssertTrue(log.values.isEmpty)
        XCTAssertEqual(controller.chip?.button?.action, .endTerminalsAndUpdate)
        XCTAssertTrue(controller.chip?.message.contains("agents") == true)
        controller.handle(.endTerminalsAndUpdate)
        try await settled(controller)
        XCTAssertEqual(log.values, ["save", "validate", "stopAll", "install", "quit"])
    }

    func testCompatibilityChangeAfterConfirmationPreservesSessions() async throws {
        let (controller, host, log, _) = try fixture()
        host.localServerBuild = BuildInfo(version: "1.0.0", protocolVersions: [ProtocolVersion(2)])
        controller.handle(.update)
        XCTAssertEqual(controller.chip?.button?.action, .endTerminalsAndUpdate)
        host.localServerBuild = BuildInfo(version: "1.0.0", protocolVersions: [ProtocolVersion(1)])
        controller.handle(.endTerminalsAndUpdate)
        try await settled(controller)
        XCTAssertEqual(log.values, ["save", "validate", "install", "quit"])
    }

    func testServerRestartWithNoTerminalsStillRequiresConsentForAgents() throws {
        let (controller, host, log, _) = try fixture()
        host.runningSessionCount = 0
        controller.handle(.restartServer)
        XCTAssertTrue(log.values.isEmpty)
        controller.stop()
    }

    func testDisconnectedServerExplainsWhyReadyUpdateCannotRestart() throws {
        let (controller, host, log, _) = try fixture()
        host.localServerBuild = nil
        XCTAssertTrue(controller.chip?.message.contains("Waiting for the local server") == true)
        XCTAssertNil(controller.chip?.button)
        controller.handle(.update)
        XCTAssertTrue(log.values.isEmpty)
        host.localServerBuild = BuildInfo(version: "1.0.0", protocolVersions: [ProtocolVersion(1)])
        XCTAssertEqual(controller.chip?.button?.action, .update)
    }

    func testRestartWaitsForANewServerInstance() async throws {
        let (controller, host, log, _) = try fixture()
        host.localServerBuild = BuildInfo(version: Release.version)
        controller.handle(.endTerminalsAndRestartServer)
        controller.reconcile()
        XCTAssertEqual(controller.status, .restartingServer)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(log.values, ["restart"])
        host.localServerInstance = 2
        controller.reconcile()
        XCTAssertEqual(controller.status, .ready(version: "99.0.0"))
        controller.stop()
    }

    func testInstallCanInterruptCheckAndCancelledResultCannotOverwriteIt() async throws {
        let operations = UpdaterOperations(latest: { _ in
            try? await Task.sleep(for: .milliseconds(100))
            return nil
        }, validate: { _ in }, install: { _, _ in })
        let (controller, host, log, _) = try fixture(operations: operations)
        controller.checkForUpdates()
        XCTAssertEqual(controller.status, .checking)
        controller.handle(.update)
        try await settled(controller)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(controller.status, .installed(version: "99.0.0"))
        XCTAssertEqual(log.values, ["save", "validate", "install", "quit"])
        _ = host
    }

    func testAutomaticDownloadHoldsOnHotspotAndResumesWhenUnconstrained() async throws {
        let manifest = UpdateManifest(version: "99.0.0", url: URL(string: "https://example.com/update.zip")!,
                                      sha256: "", protocolVersions: [ProtocolVersion(1)])
        let downloads = UpdateCallLog()
        let operations = UpdaterOperations(
            latest: { _ in manifest },
            downloadAndPrepare: { _, manifest, installation, _, _ in
                downloads.append("download:\(manifest.version)")
                return PreparedUpdate(manifest: manifest, installation: installation,
                                      staging: installation.directory.appendingPathComponent(".tab-update-auto"))
            },
            validate: { _ in },
            install: { _, _ in }
        )
        let (controller, host, _, _) = try fixture(operations: operations, settings: UpdateSettings(automaticDownloads: true), includePrepared: false)
        controller.networkStateDidChange(UpdateNetworkState(isOnline: true, hold: .hotspot))
        controller.checkForUpdates()
        for _ in 0..<100 where controller.available == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.available?.version, "99.0.0")
        XCTAssertEqual(controller.downloadHold, .hotspot)
        XCTAssertTrue(downloads.values.isEmpty)
        XCTAssertTrue(controller.chip?.message.contains("hotspot") == true)

        controller.networkStateDidChange(.unconstrained)
        for _ in 0..<100 where controller.prepared == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(downloads.values, ["download:99.0.0"])
        XCTAssertNil(controller.downloadHold)
        XCTAssertEqual(controller.status, .ready(version: "99.0.0"))
        controller.stop()
        _ = host
    }

    func testAutomaticInstallRelaunchesQuietlyOnceHiddenAndSettled() async throws {
        let (controller, host, log, root) = try fixture(
            settings: UpdateSettings(automaticDownloads: true, automaticInstall: true),
            settleDelay: 0.05
        )
        host.environment = AutomaticInstallEnvironment(isWindowVisible: true)
        controller.reevaluateAutomaticInstall()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(log.values.isEmpty)

        host.environment = AutomaticInstallEnvironment(isWindowVisible: false)
        controller.reevaluateAutomaticInstall()
        for _ in 0..<100 where controller.status != .installed(version: "99.0.0") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(log.values, ["save", "validate", "install-quiet-hidden", "quit"])
        XCTAssertEqual(QuietRelaunchMarker.take(root.appendingPathComponent("quiet-relaunch")), .hidden)
        controller.stop()
    }

    func testOneShotRelaunchWhenIdleWorksWithAutomaticInstallOff() async throws {
        let (controller, host, log, _) = try fixture(
            settings: UpdateSettings(automaticDownloads: true, automaticInstall: false),
            settleDelay: 0.05
        )
        host.environment = AutomaticInstallEnvironment(isWindowVisible: false)
        controller.scheduleRelaunchWhenIdle()
        XCTAssertTrue(controller.relaunchWhenIdle)
        for _ in 0..<100 where controller.status != .installed(version: "99.0.0") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(log.values, ["save", "validate", "install-quiet-hidden", "quit"])
        controller.stop()
    }

    // MARK: Keeping terminals through restarts

    private static let incompatible = BuildInfo(version: "1.0.0", protocolVersions: [ProtocolVersion(2)])
    private static let npm = ServerWork(programs: [.init(session: SessionId(), project: ProjectId(), name: "npm")])

    func testAnIncompatibleUpdateRestartsAServerThatKeepsTerminalsWithoutAsking() async throws {
        let (controller, host, log, _) = try fixture()
        host.localServerBuild = Self.incompatible
        host.localServerKeepsTerminals = true
        XCTAssertTrue(controller.chip?.message.contains("terminals reopen") == true)
        controller.handle(.update)
        try await settled(controller)
        XCTAssertEqual(log.values, ["save", "validate", "restartIfIdle", "install", "quit"])
    }

    func testAnIncompatibleUpdateAsksBeforeStoppingWorkAndNamesIt() async throws {
        let (controller, host, log, _) = try fixture()
        host.localServerBuild = Self.incompatible
        host.localServerKeepsTerminals = true
        host.serverWork = Self.npm
        controller.handle(.update)
        try await settled(controller)
        XCTAssertEqual(log.values, ["save", "validate", "restartIfIdle"])
        XCTAssertNotNil(controller.prepared, "nothing stopped and the download stays")
        let confirm = try XCTUnwrap(controller.chip)
        XCTAssertEqual(confirm.button?.action, .updateStoppingWork)
        XCTAssertTrue(confirm.message.contains("stops npm"), confirm.message)
        XCTAssertTrue(confirm.message.contains("Terminals reopen"), confirm.message)

        controller.handle(.updateStoppingWork)
        try await settled(controller)
        XCTAssertEqual(log.values, ["save", "validate", "restartIfIdle", "save", "validate", "restartStoppingWork", "install", "quit"])
    }

    func testQuittingInstallsTheReadyUpdateWithoutRelaunchingOrSayingSo() async throws {
        let (controller, host, log, _) = try fixture(settings: UpdateSettings())
        await controller.prepareForQuit()
        XCTAssertEqual(log.values, ["save", "validate", "install-at-quit"])
        XCTAssertEqual(controller.status, .installed(version: "99.0.0"))
        XCTAssertNil(controller.chip, "Tab is quitting; nothing to say")
        _ = host
    }

    func testQuittingLeavesTheUpdateWhenInstallingIsUpToThePerson() async throws {
        let (controller, host, log, _) = try fixture()
        await controller.prepareForQuit()
        XCTAssertTrue(log.values.isEmpty)
        XCTAssertNotNil(controller.prepared)
        _ = host
    }

    func testQuittingWithAnIncompatibleUpdateStartsTheNewServerForAgentsAndPhones() async throws {
        let (controller, host, log, _) = try fixture(settings: UpdateSettings())
        host.localServerBuild = Self.incompatible
        host.localServerKeepsTerminals = true
        await controller.prepareForQuit()
        XCTAssertEqual(log.values, ["save", "validate", "restartIfIdle", "install-at-quit", "startServer"])
    }

    func testQuittingWithWorkRunningKeepsTheServerAndTheUpdate() async throws {
        let (controller, host, log, _) = try fixture(settings: UpdateSettings())
        host.localServerBuild = Self.incompatible
        host.localServerKeepsTerminals = true
        host.serverWork = Self.npm
        await controller.prepareForQuit()
        XCTAssertEqual(log.values, ["save", "validate", "restartIfIdle"])
        XCTAssertNotNil(controller.prepared)
        XCTAssertNil(controller.chip.flatMap { $0.tone == .warning ? $0 : nil }, "quitting never asks")
    }

    func testAReadyUpdateThatInstallsItselfGoesUnmentioned() throws {
        let (controller, host, _, _) = try fixture(settings: UpdateSettings())
        XCTAssertNil(controller.chip, "it installs while the person is away")
        host.localServerBuild = Self.incompatible
        XCTAssertNotNil(controller.chip, "a server that ends terminals needs the person")
        host.localServerKeepsTerminals = true
        XCTAssertNil(controller.chip)
    }

    func testAnOutdatedServerRestartsQuietlyOnlyWhileThePersonIsAwayAndNothingWorks() async throws {
        let (controller, host, log, _) = try fixture(settings: UpdateSettings(), includePrepared: false, appVersion: "1.0.0")
        host.localServerBuild = BuildInfo(version: "0.0.1", protocolVersions: [ProtocolVersion(1)])
        host.localServerKeepsTerminals = true
        XCTAssertNil(controller.chip, "it restarts by itself, so it goes unmentioned")
        XCTAssertNotNil(controller.serverUpdateDetail)

        host.environment = AutomaticInstallEnvironment(isWindowVisible: true, isAppActive: true)
        controller.reevaluateAutomaticInstall()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(log.values.isEmpty, "not while the person uses Tab")

        host.environment = AutomaticInstallEnvironment(isWindowVisible: true, userIdleTime: 3600)
        host.workingAgentCount = 1
        controller.reevaluateAutomaticInstall()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(log.values.isEmpty, "not while an agent works")

        host.workingAgentCount = 0
        host.serverWork = Self.npm
        controller.reevaluateAutomaticInstall()
        for _ in 0..<100 where log.values.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(log.values, ["restartIfIdle"])
        for _ in 0..<100 where controller.serverWork == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.serverWork, Self.npm)
        XCTAssertTrue(controller.serverUpdateDetail?.contains("npm") == true)
        XCTAssertNotEqual(controller.status, .restartingServer)

        host.serverWork = nil
        controller.reevaluateAutomaticInstall()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(log.values, ["restartIfIdle"], "the server isn't asked again right away")
        controller.stop()
    }

    func testAQuietServerRestartFinishesWithoutANotice() async throws {
        let (controller, host, _, _) = try fixture(settings: UpdateSettings(), includePrepared: false, appVersion: "1.0.0")
        host.localServerBuild = BuildInfo(version: "0.0.1", protocolVersions: [ProtocolVersion(1)])
        host.localServerKeepsTerminals = true
        host.environment = AutomaticInstallEnvironment(isWindowVisible: false, hasOpenWindow: false)
        controller.reevaluateAutomaticInstall()
        for _ in 0..<100 where controller.status != .restartingServer { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.status, .restartingServer)
        XCTAssertNil(controller.chip, "a background restart goes unmentioned")
        XCTAssertFalse(controller.mentionsServerRestart)
        host.localServerInstance = 2
        host.localServerBuild = BuildInfo(version: "1.0.0")
        controller.reconcile()
        XCTAssertEqual(controller.status, .idle)
        XCTAssertNil(controller.chip)
        controller.stop()
    }

    func testRestartingAServerThatKeepsTerminalsAsksOnlyWhenWorkWouldStop() async throws {
        let (controller, host, log, _) = try fixture(includePrepared: false, appVersion: "1.0.0")
        host.localServerBuild = BuildInfo(version: "0.0.1", protocolVersions: [ProtocolVersion(1)])
        host.localServerKeepsTerminals = true
        host.serverWork = ServerWork(programs: [.init(session: SessionId(), project: ProjectId(), name: "cargo")], agents: [SessionId()])
        controller.handle(.restartServer)
        for _ in 0..<100 where controller.chip?.button?.action != .restartServerStoppingWork {
            try await Task.sleep(for: .milliseconds(10))
        }
        let confirm = try XCTUnwrap(controller.chip)
        XCTAssertEqual(confirm.button?.action, .restartServerStoppingWork)
        XCTAssertTrue(confirm.message.contains("stops cargo"), confirm.message)
        XCTAssertTrue(confirm.message.contains("agent picks up"), confirm.message)
        controller.handle(.restartServerStoppingWork)
        for _ in 0..<100 where log.values.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(log.values, ["restartIfIdle", "restartStoppingWork"])
        XCTAssertEqual(controller.status, .restartingServer)
        XCTAssertTrue(controller.mentionsServerRestart)
        controller.stop()
    }

    func testRelaunchComesBackAsTabWas() {
        XCTAssertEqual(AutomaticInstallEnvironment(isWindowVisible: true, isAppActive: true).presentation, .active)
        XCTAssertEqual(AutomaticInstallEnvironment(isWindowVisible: false, isAppActive: false, hasOpenWindow: true,
                                                   isScreenLocked: true).presentation, .background,
                       "a window covered by the lock screen opens again")
        XCTAssertEqual(AutomaticInstallEnvironment(isWindowVisible: false).presentation, .hidden)
        XCTAssertEqual(PreparedUpdate.openOptions(.quietly(.hidden)), ["-n", "-g", "-j"])
        XCTAssertEqual(PreparedUpdate.openOptions(.quietly(.background)), ["-n", "-g"])
        XCTAssertEqual(PreparedUpdate.openOptions(.open), ["-n"])
        XCTAssertNil(PreparedUpdate.openOptions(.none))
    }

    func testAPersonAwayFromAVisibleTabCountsAsAQuietMoment() {
        let visible = AutomaticInstallEnvironment(isWindowVisible: true)
        XCTAssertEqual(AutomaticUpdateInstaller.quietObstacle(visible), .windowVisible)
        var away = visible
        away.userIdleTime = AutomaticInstallEnvironment.awayAfter
        XCTAssertNil(AutomaticUpdateInstaller.quietObstacle(away))
        var locked = visible
        locked.isScreenLocked = true
        XCTAssertNil(AutomaticUpdateInstaller.quietObstacle(locked))
        locked.hasUnsavedEditors = true
        XCTAssertEqual(AutomaticUpdateInstaller.quietObstacle(locked), .unsavedWork, "unsaved files always wait")
        var watching = away
        watching.isAppActive = true
        XCTAssertEqual(AutomaticUpdateInstaller.quietObstacle(watching), .windowVisible,
                       "someone watching Tab in front without typing isn't away yet")
        watching.userIdleTime = AutomaticInstallEnvironment.longAwayAfter
        XCTAssertNil(AutomaticUpdateInstaller.quietObstacle(watching))
    }
}

@MainActor
private final class UpdateHostFixture: UpdaterHost {
    var localServerBuild: BuildInfo? = .init(version: "1.0.0", protocolVersions: [ProtocolVersion(1)])
    var localServerInstance: UInt64? = 1
    var runningSessionCount = 2
    var runningAgentCount = 0
    var workingAgentCount = 0
    var localServerKeepsTerminals = false
    /// What the server says keeps it from restarting while idle-only restarts are asked.
    var serverWork: ServerWork?
    func restartLocalServerKeepingTerminals(onlyWhenIdle: Bool) async throws -> ServerWork? {
        log.append(onlyWhenIdle ? "restartIfIdle" : "restartStoppingWork")
        return onlyWhenIdle ? serverWork : nil
    }
    func startLocalServer() { log.append("startServer") }
    var environment = AutomaticInstallEnvironment(isWindowVisible: true)
    var automaticInstallEnvironment: AutomaticInstallEnvironment { environment }
    var prepare: () async throws -> Bool = { true }
    var stopsWhenIdle = true
    let log: UpdateCallLog
    init(log: UpdateCallLog) { self.log = log }
    func endAllSessions() async throws { log.append("stopAll") }
    func stopLocalServerIfIdle() async -> Bool { log.append("stopIdle"); return stopsWhenIdle }
    func restartLocalServer() async throws { log.append("restart") }
    func prepareToQuitForUpdate() async throws -> Bool { log.append("save"); return try await prepare() }
    func quitForUpdate() { log.append("quit") }
    func updaterDidChange() {}
}

private final class UpdateCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var values: [String] { lock.withLock { calls } }
    func append(_ value: String) { lock.withLock { calls.append(value) } }
}
