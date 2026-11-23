import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class UpdaterLifecycleTests: XCTestCase {
    private func fixture(
        operations: UpdaterOperations = .init(validate: { _ in }, install: { _, _ in }),
        settings: UpdateSettings = UpdateSettings(),
        includePrepared: Bool = true,
        settleDelay: TimeInterval = 0.05
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
        operations.install = { update, quiet in
            log.append(quiet ? "install-quiet" : "install")
            try install(update, quiet)
        }
        let host = UpdateHostFixture(log: log)
        let controller = UpdaterController(
            host: host,
            dirs: TabDirs(root: root),
            prepared: includePrepared ? update : nil,
            installation: installation,
            settings: settings,
            settleDelay: settleDelay,
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
        XCTAssertEqual(log.values, ["save", "validate", "install-quiet", "quit"])
        XCTAssertTrue(QuietRelaunchMarker.take(root.appendingPathComponent("quiet-relaunch")))
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
        XCTAssertEqual(log.values, ["save", "validate", "install-quiet", "quit"])
        controller.stop()
    }
}

@MainActor
private final class UpdateHostFixture: UpdaterHost {
    var localServerBuild: BuildInfo? = .init(version: "1.0.0", protocolVersions: [ProtocolVersion(1)])
    var localServerInstance: UInt64? = 1
    var runningSessionCount = 2
    var runningAgentCount = 0
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
