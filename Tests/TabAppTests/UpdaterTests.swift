import CryptoKit
import Foundation
import TabProtocol
import XCTest
@testable import TabApp

final class UpdaterTests: XCTestCase {
    @MainActor
    func testAutomaticUpdateChecksMatchCodeshHourlySchedule() {
        XCTAssertEqual(UpdaterController.checkInterval, 3600)
    }

    private func feed(_ version: String, extra: [String: Any] = [:], url: String? = nil) -> Data {
        var object: [String: Any] = [
            "version": version,
            "url": url ?? "https://github.com/hugocxl/tab/releases/download/v\(version)/Tab-\(version).zip",
            "sha256": String(repeating: "a", count: 64),
            "size": 123,
        ]
        object.merge(extra) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)

    func testUpdatesOnlyToANewerReleaseOfTheSameChannel() throws {
        for version in ["2.0.0-beta.10", "2.1.0-beta.10"] {
            XCTAssertNotNil(try UpdateFeed.parse(feed(version), current: "2.0.0-beta.9", systemVersion: sonoma), version)
        }
        for version in ["2.0.0-beta.8", "2.0.0-beta.9", "2.0.0", "3.0.0"] {
            XCTAssertNil(try UpdateFeed.parse(feed(version), current: "2.0.0-beta.9", systemVersion: sonoma), version)
        }
        XCTAssertNotNil(try UpdateFeed.parse(feed("2.0.1"), current: "2.0.0", systemVersion: sonoma))
        XCTAssertNotNil(try UpdateFeed.parse(feed("2.10.0"), current: "2.9.9", systemVersion: sonoma))
        for version in ["2.0.0", "1.9.9", "2.0.1-beta.10"] {
            XCTAssertNil(try UpdateFeed.parse(feed(version), current: "2.0.0", systemVersion: sonoma), version)
        }
        XCTAssertThrowsError(try UpdateFeed.parse(feed("2.0.1"), current: "0.1.0-dev", systemVersion: sonoma)) { error in
            XCTAssertEqual(error as? UpdateError, .notARelease)
        }
        for version in ["2.0.0-alpha.99", "2.0-beta.99", "2.x.0-beta.99", "2.0.0-beta.0", "2.0.0-beta.01"] {
            XCTAssertThrowsError(try UpdateFeed.parse(feed(version), current: "2.0.0-beta.9", systemVersion: sonoma), version)
        }
    }

    func testDecodingToleratesUnknownAndMissingOptionalKeys() throws {
        let data = feed("1.1.0", extra: ["protocolVersion": 1, "notes": "faster", "sha256": String(repeating: "AB", count: 32)])
        let manifest = try XCTUnwrap(UpdateFeed.parse(data, current: "1.0.0", systemVersion: sonoma))
        XCTAssertEqual(manifest.protocolVersions, [ProtocolVersion(1)])
        XCTAssertEqual(manifest.sha256, String(repeating: "ab", count: 32))
        XCTAssertNil(manifest.minimumSystemVersion)

        let list = try XCTUnwrap(UpdateFeed.parse(feed("1.1.0", extra: ["protocolVersions": [1, 2], "protocolVersion": 9]),
                                                  current: "1.0.0", systemVersion: sonoma))
        XCTAssertEqual(list.protocolVersions, [ProtocolVersion(1), ProtocolVersion(2)])

        let bare: [String: Any] = [
            "version": "1.1.0",
            "url": "https://github.com/hugocxl/tab/releases/download/v1.1.0/Tab.zip",
            "sha256": String(repeating: "0", count: 64),
        ]
        let minimal = try XCTUnwrap(UpdateFeed.parse(JSONSerialization.data(withJSONObject: bare), current: "1.0.0", systemVersion: sonoma))
        XCTAssertEqual(minimal.protocolVersions, [])
        XCTAssertNil(minimal.size)

        let roundTrip = try JSONDecoder().decode(UpdateManifest.self, from: JSONEncoder().encode(list))
        XCTAssertEqual(roundTrip, list)
    }

    func testRejectsForeignLocationsBadChecksumsSizesAndOldSystems() {
        for url in [
            "http://github.com/hugocxl/tab/releases/download/v1.1.0/Tab.zip",
            "https://example.com/Tab.zip",
            "https://github.com/foreign/tab/releases/download/v1.1.0/Tab.zip",
            "https://github.com/hugocxl/tab/releases/download/v1.0.9/Tab.zip",
            "https://github.com/hugocxl/tab/releases/download/v1.1.0/../v1.0.0/Tab.zip",
            "https://github.com/hugocxl/tab/releases/download/v1.1.0/Tab.pkg",
        ] {
            XCTAssertThrowsError(try UpdateFeed.parse(feed("1.1.0", url: url), current: "1.0.0", systemVersion: sonoma), url)
        }
        for checksum in ["abcd", String(repeating: "z", count: 64)] {
            XCTAssertThrowsError(try UpdateFeed.parse(feed("1.1.0", extra: ["sha256": checksum]), current: "1.0.0", systemVersion: sonoma))
        }
        for size in [0, Int64(3) * 1024 * 1024 * 1024] {
            XCTAssertThrowsError(try UpdateFeed.parse(feed("1.1.0", extra: ["size": size]), current: "1.0.0", systemVersion: sonoma))
        }
        XCTAssertThrowsError(try UpdateFeed.parse(Data("{\"version\":\"1.1.0\"}".utf8), current: "1.0.0", systemVersion: sonoma))
        XCTAssertThrowsError(try UpdateFeed.parse(feed("1.1.0", extra: ["minimumSystemVersion": "15.1"]), current: "1.0.0", systemVersion: sonoma)) { error in
            XCTAssertEqual(error as? UpdateError, .systemTooOld(version: "1.1.0", minimum: "15.1"))
        }
        XCTAssertNoThrow(try UpdateFeed.parse(feed("1.1.0", extra: ["minimumSystemVersion": "14.2"]), current: "1.0.0", systemVersion: sonoma))
    }

    func testInstallDecisionTable() {
        let manifest = UpdateManifest(version: "1.1.0", url: URL(string: "https://example.com")!, sha256: "",
                                      protocolVersions: [ProtocolVersion(1), ProtocolVersion(2)])
        XCTAssertTrue(UpdateDecision.isCompatible(manifest, with: BuildInfo(version: "1.0.0", protocolVersions: [ProtocolVersion(2)])))
        XCTAssertFalse(UpdateDecision.isCompatible(manifest, with: BuildInfo(version: "1.0.0", protocolVersions: [ProtocolVersion(3)])))
        XCTAssertFalse(UpdateDecision.isCompatible(manifest, with: nil))
        var unknown = manifest
        unknown.protocolVersions = []
        XCTAssertFalse(UpdateDecision.isCompatible(unknown, with: BuildInfo(version: "1.0.0")))

        XCTAssertEqual(UpdateDecision.offer(compatible: true, scheduled: false, sessions: 3), .installNow)
        XCTAssertEqual(UpdateDecision.offer(compatible: false, scheduled: false, sessions: 3), .needsNewServer)
        XCTAssertEqual(UpdateDecision.offer(compatible: true, scheduled: true, sessions: 3), .waitingForSessions(3))

        XCTAssertEqual(UpdateDecision.step(for: .install(restartServer: false), compatible: true, sessions: 4), .install(stopServer: false))
        XCTAssertEqual(UpdateDecision.step(for: .install(restartServer: true), compatible: true, sessions: 4), .install(stopServer: true))
        XCTAssertEqual(UpdateDecision.step(for: .install(restartServer: false), compatible: false, sessions: 4), .wait)
        XCTAssertEqual(UpdateDecision.step(for: .endSessions, compatible: false, sessions: 4), .install(stopServer: true))
        XCTAssertEqual(UpdateDecision.step(for: .waitForSessions, compatible: false, sessions: 4), .wait)
        XCTAssertEqual(UpdateDecision.step(for: .waitForSessions, compatible: false, sessions: 0), .install(stopServer: true))
        XCTAssertEqual(UpdateDecision.step(for: .cancelWaiting, compatible: false, sessions: 4), .cancelWait)
        XCTAssertEqual(UpdateDecision.step(for: .later, compatible: true, sessions: 0), .nothing)
        XCTAssertEqual(UpdateDecision.scheduledStep(sessions: 1), .wait)
        XCTAssertEqual(UpdateDecision.scheduledStep(sessions: 0), .install(stopServer: true))

        XCTAssertTrue(UpdateDecision.shouldReplaceServer(serverVersion: "1.0.0", appVersion: "1.1.0", sessions: 0))
        XCTAssertFalse(UpdateDecision.shouldReplaceServer(serverVersion: "1.0.0", appVersion: "1.1.0", sessions: 1))
        XCTAssertFalse(UpdateDecision.shouldReplaceServer(serverVersion: "1.1.0", appVersion: "1.1.0", sessions: 0))
        XCTAssertFalse(UpdateDecision.shouldReplaceServer(serverVersion: nil, appVersion: "1.1.0", sessions: 0))
    }

    func testDownloadVerificationRejectsChecksumAndSizeMismatches() throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("update.zip")
        let contents = Data("signed app".utf8)
        try contents.write(to: file)
        let hash = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try UpdateDownloader.verify(file, sha256: hash.uppercased(), size: Int64(contents.count)))
        XCTAssertNoThrow(try UpdateDownloader.verify(file, sha256: hash, size: nil))
        XCTAssertThrowsError(try UpdateDownloader.verify(file, sha256: String(repeating: "0", count: 64), size: Int64(contents.count))) { error in
            XCTAssertEqual(error as? UpdateError, .checksumMismatch)
        }
        XCTAssertThrowsError(try UpdateDownloader.verify(file, sha256: hash, size: Int64(contents.count) + 1)) { error in
            XCTAssertEqual(error as? UpdateError, .sizeMismatch)
        }
    }

    func testReplacementKeepsTheOldBundleAndRollsBackOnFailure() throws {
        let folder = try temporaryFolder()
        let current = folder.appendingPathComponent("Tab.app")
        let next = folder.appendingPathComponent("next.app")
        let backup = folder.appendingPathComponent("previous.app")
        for (bundle, version) in [(current, "old"), (next, "new")] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data(version.utf8).write(to: bundle.appendingPathComponent("tabd"))
        }
        struct RelaunchFailed: Error {}
        XCTAssertThrowsError(try BundleReplacement.replace(current: current, next: next, backup: backup) { throw RelaunchFailed() })
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("tabd"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: next.appendingPathComponent("tabd"), encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))

        XCTAssertThrowsError(try BundleReplacement.replace(current: current, next: folder.appendingPathComponent("missing.app"), backup: backup))
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("tabd"), encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))

        try BundleReplacement.replace(current: current, next: next, backup: backup)
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("tabd"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("tabd"), encoding: .utf8), "old")
    }

    func testReplacementRefusesToOverwriteAnExistingBackup() throws {
        let root = try temporaryFolder()
        let current = root.appendingPathComponent("current.app")
        let next = root.appendingPathComponent("next.app")
        let backup = root.appendingPathComponent("previous.app")
        for (path, text) in [(current, "current"), (next, "next"), (backup, "previous")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: path.appendingPathComponent("marker"))
        }
        XCTAssertThrowsError(try BundleReplacement.replace(current: current, next: next, backup: backup))
        for (path, text) in [(current, "current"), (next, "next"), (backup, "previous")] {
            XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("marker"), encoding: .utf8), text)
        }
    }

    func testCleanupKeepsBundlesWhoseServerStillRuns() throws {
        let folder = try temporaryFolder()
        let installation = Installation(bundle: folder.appendingPathComponent("Tab.app"), team: "TESTTEAM00")
        let busy = folder.appendingPathComponent(".tab-update-busy/previous.app")
        let idle = folder.appendingPathComponent(".tab-update-idle/previous.app")
        let kept = folder.appendingPathComponent(".tab-update-pending")
        for path in [installation.bundle, busy.deletingLastPathComponent(), idle, kept] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let server = installation.bundle.appendingPathComponent("Contents/MacOS/sleeper")
        try FileManager.default.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: server)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", server.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        let process = Process()
        process.executableURL = server
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 0.2)
        try FileManager.default.moveItem(at: installation.bundle, to: busy)
        try FileManager.default.createDirectory(at: installation.bundle, withIntermediateDirectories: true)

        installation.cleanUp(keeping: kept)
        XCTAssertTrue(FileManager.default.fileExists(atPath: busy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: idle.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-updater-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.resolvingSymlinksInPath()
    }
}
