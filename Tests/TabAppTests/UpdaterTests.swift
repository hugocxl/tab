import CryptoKit
import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

final class UpdaterTests: XCTestCase {
    @MainActor
    func testAutomaticUpdateChecksFollowHourlySchedule() {
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

    /// A check offers the feed's release unless it doesn't replace the
    /// download waiting to install: a stale feed must not move it back.
    func testChecksOfferOnlyReleasesNewerThanTheDownload() {
        let newest = pendingUpdate("0.10.0").manifest
        XCTAssertEqual(UpdaterController.newerRelease(newest, than: "0.8.0"), newest)
        XCTAssertEqual(UpdaterController.newerRelease(newest, than: nil), newest)
        XCTAssertNil(UpdaterController.newerRelease(nil, than: nil))
        XCTAssertNil(UpdaterController.newerRelease(nil, than: "0.9.0"))
        XCTAssertNil(UpdaterController.newerRelease(pendingUpdate("0.9.0").manifest, than: "0.9.0"))
        XCTAssertNil(UpdaterController.newerRelease(pendingUpdate("0.8.0").manifest, than: "0.9.0"))
    }

    private func pendingUpdate(_ version: String) -> PreparedUpdate {
        let bundle = URL(fileURLWithPath: "/Applications/Tab.app")
        return PreparedUpdate(
            manifest: UpdateManifest(version: version,
                                     url: URL(string: "\(UpdateFeed.releases)/v\(version)/Tab-\(version)-arm64.dmg")!,
                                     sha256: String(repeating: "a", count: 64), protocolVersions: [ProtocolVersion(1)]),
            installation: Installation(bundle: bundle, team: "TESTTEAM00"),
            staging: bundle.deletingLastPathComponent().appendingPathComponent(".tab-update-\(version)"))
    }

    func testBetasUpdateToNewerBetasAndTheirStableReleaseButStableNeverToBetas() throws {
        for version in ["2.0.0-beta.10", "2.1.0-beta.10", "2.0.0", "3.0.0"] {
            XCTAssertNotNil(try UpdateFeed.parse(feed(version), current: "2.0.0-beta.9", systemVersion: sonoma), version)
        }
        for version in ["2.0.0-beta.8", "2.0.0-beta.9", "1.9.9"] {
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

    func testOnlyFeedsSignedWithTheReleaseKeyAreTrusted() throws {
        let key = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let release = UpdateManifest(
            version: "1.1.0", url: URL(string: "https://github.com/hugocxl/tab/releases/download/v1.1.0/Tab-1.1.0-arm64.dmg")!,
            sha256: String(repeating: "a", count: 64), size: 123, minimumSystemVersion: "14.0")
        func signed(_ manifest: UpdateManifest, by signer: Curve25519.Signing.PrivateKey) throws -> UpdateManifest {
            var manifest = manifest
            manifest.signature = try signer.signature(for: manifest.signedMessage).base64EncodedString()
            return manifest
        }
        func parse(_ manifest: UpdateManifest) throws -> UpdateManifest? {
            try UpdateFeed.parse(JSONEncoder().encode(manifest), current: "1.0.0", systemVersion: sonoma,
                                 signedBy: key.publicKey.rawRepresentation)
        }
        XCTAssertEqual(try parse(signed(release, by: key))?.version, "1.1.0")
        XCTAssertThrowsError(try parse(release))
        XCTAssertThrowsError(try parse(signed(release, by: other)))
        var garbled = try signed(release, by: key)
        garbled.signature = "not base64"
        XCTAssertThrowsError(try parse(garbled))
        // Changing anything that decides what installs breaks the signature.
        let tampered: [(inout UpdateManifest) -> Void] = [
            { $0.sha256 = String(repeating: "b", count: 64) },
            { $0.size = 124 },
            { $0.minimumSystemVersion = "13.0" },
            { $0.url = URL(string: "https://github.com/hugocxl/tab/releases/download/v1.1.0/Tab-1.1.0-arm64.zip")! },
        ]
        for change in tampered {
            var manifest = try signed(release, by: key)
            change(&manifest)
            XCTAssertThrowsError(try parse(manifest)) { error in
                XCTAssertEqual(error as? UpdateError, .invalidFeed("The update feed isn't signed with \(Release.appName)'s release key"))
            }
        }
        var renamed = try signed(release, by: key)
        renamed.version = "1.2.0"
        XCTAssertThrowsError(try parse(renamed))
        XCTAssertEqual(UpdateFeed.signingKey.count, 32)
        XCTAssertThrowsError(try UpdateFeed.parse(JSONEncoder().encode(signed(release, by: key)), current: "1.0.0",
                                                  systemVersion: sonoma, signedBy: Data()))
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

        XCTAssertEqual(UpdateDecision.step(compatible: true, sessions: 4), .install)
        XCTAssertEqual(UpdateDecision.step(compatible: false, sessions: 0), .installStoppingIdleServer)
        XCTAssertEqual(UpdateDecision.step(compatible: false, sessions: 4), .confirmEndingTerminals)

        XCTAssertTrue(UpdateDecision.isOutdated(serverVersion: "1.0.0", appVersion: "1.1.0"))
        XCTAssertFalse(UpdateDecision.isOutdated(serverVersion: "1.2.0", appVersion: "1.1.0"))
        XCTAssertFalse(UpdateDecision.isOutdated(serverVersion: nil, appVersion: "1.1.0"))
        XCTAssertTrue(UpdateDecision.shouldReplaceServer(serverVersion: "1.0.0", appVersion: "1.1.0", sessions: 0))
        XCTAssertFalse(UpdateDecision.shouldReplaceServer(serverVersion: "1.0.0", appVersion: "1.1.0", sessions: 1))
        XCTAssertFalse(UpdateDecision.shouldReplaceServer(serverVersion: "1.1.0", appVersion: "1.1.0", sessions: 0))
        XCTAssertFalse(UpdateDecision.shouldReplaceServer(serverVersion: nil, appVersion: "1.1.0", sessions: 0))
    }

    private func chip(
        _ status: UpdaterStatus = .idle, notice: UpdateNotice? = nil, checking: Bool = false, showsDownload: Bool = true,
        available: String? = nil, ready: UpdateChip.Ready? = nil, outdatedServer: String? = nil, sessions: Int = 0
    ) -> UpdateChip? {
        UpdateChip.make(status: status, notice: notice, checking: checking, showsDownload: showsDownload,
                        available: available, ready: ready, outdatedServer: outdatedServer, sessions: sessions)
    }

    /// Only a button the person pressed after a warning that names the
    /// running terminals ends them.
    func testUpdateChipNeverEndsTerminalsWithoutConfirming() throws {
        let compatible = UpdateChip.Ready(version: "1.1.0", compatible: true)
        let incompatible = UpdateChip.Ready(version: "1.1.0", compatible: false)
        XCTAssertEqual(chip(ready: compatible, sessions: 3)?.button?.action, .update)
        XCTAssertEqual(chip(ready: incompatible, sessions: 0)?.button?.action, .update)
        XCTAssertEqual(chip(ready: incompatible, sessions: 2)?.button?.action, .update)

        let confirm = try XCTUnwrap(chip(.ready(version: "1.1.0"), notice: .confirmUpdate, ready: incompatible, sessions: 2))
        XCTAssertEqual(confirm.button?.action, .endTerminalsAndUpdate)
        XCTAssertEqual(confirm.tone, .warning)
        XCTAssertTrue(confirm.message.contains("2 running terminals"))
        // Terminals ended meanwhile: nothing is left to warn about.
        XCTAssertEqual(chip(.ready(version: "1.1.0"), notice: .confirmUpdate, ready: incompatible, sessions: 0)?.button?.title, "Restart")
        XCTAssertEqual(chip(.ready(version: "1.1.0"), notice: .confirmUpdate, ready: compatible, sessions: 2)?.button?.title, "Restart")

        let server = try XCTUnwrap(chip(outdatedServer: "1.0.0", sessions: 1))
        XCTAssertEqual(server.tone, .warning)
        XCTAssertEqual(server.button?.action, .restartServer)
        XCTAssertEqual(chip(notice: .confirmServerRestart, outdatedServer: "1.0.0", sessions: 1)?.button?.action,
                       .endTerminalsAndRestartServer)
        XCTAssertNil(chip(notice: .confirmServerRestart, sessions: 1))

        let installing = try XCTUnwrap(chip(.installing(version: "1.1.0"), notice: .confirmUpdate, ready: incompatible, sessions: 2))
        XCTAssertNil(installing.button)
        XCTAssertNil(installing.dismissal)
    }

    /// Background checks stay quiet; checks the person asks for always answer.
    func testUpdateChipReportsChecksThePersonAskedFor() throws {
        XCTAssertNil(chip(.checking))
        XCTAssertNil(chip(.idle))
        let checking = try XCTUnwrap(chip(.checking, checking: true))
        XCTAssertEqual(checking.tone, .neutral)
        XCTAssertEqual(checking.icon, .spinner)
        XCTAssertNil(checking.dismissal)
        XCTAssertEqual(chip(notice: .upToDate(version: "1.0.0"))?.tone, .success)
        let available = try XCTUnwrap(chip(.available(version: "1.1.0"), available: "1.1.0"))
        XCTAssertEqual(available.button?.action, .download)
        XCTAssertEqual(available.dismissal, .available("1.1.0"))
        XCTAssertEqual(chip(notice: .checkFailed("You’re offline."))?.button?.action, .checkAgain)
        XCTAssertEqual(chip(notice: .downloadFailed(version: "1.1.0", reason: "x"))?.button?.action, .checkAgain)
        XCTAssertEqual(chip(notice: .unavailable("Debug builds don't update themselves."))?.tone, .warning)

        let downloading = try XCTUnwrap(chip(.downloading(version: "1.1.0", progress: 0.426)))
        XCTAssertEqual(downloading.message, "Downloading \(Release.appName) 1.1.0… 42%")
        XCTAssertEqual(downloading.icon, .progress(0.426))
        XCTAssertEqual(downloading.dismissal, .download("1.1.0"))
        XCTAssertEqual(chip(.downloading(version: "1.1.0", progress: nil))?.icon, .spinner)
        XCTAssertNil(chip(.downloading(version: "1.1.0", progress: 0.5), showsDownload: false))
        XCTAssertEqual(chip(.preparing(version: "1.1.0"))?.icon, .spinner)

        XCTAssertEqual(chip(notice: .updated(version: "1.1.0"))?.button?.action, .showChangelog)
        XCTAssertEqual(chip(notice: .updated(version: "1.1.0"))?.tone, .success)
        XCTAssertEqual(UpdateChip.sentence("the server answered 404"), "The server answered 404.")
        XCTAssertEqual(UpdateChip.sentence("You’re offline."), "You’re offline.")
    }

    /// Every sample in the debug preview still produces its chip.
    func testUpdateChipPreviewCoversEveryState() {
        XCTAssertEqual(UpdateChip.previews.count, 21)
        XCTAssertEqual(Set(UpdateChip.previews.map(\.message)).count, 21)
    }

    func testUpdatedMarkerAnnouncesOnlyTheInstalledBuildOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("updated-to-\(UUID().uuidString)")
        UpdatedMarker.save("1.1.0", to: url)
        XCTAssertNil(UpdatedMarker.take(url, current: "1.0.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        UpdatedMarker.save("1.1.0", to: url)
        XCTAssertEqual(UpdatedMarker.take(url, current: "1.1.0"), "1.1.0")
        XCTAssertNil(UpdatedMarker.take(url, current: "1.1.0"))
    }

    /// Older builds require `scheduled`; this build writes it and reads records without it.
    func testPendingUpdateRecordStaysReadableByOlderBuilds() throws {
        let manifest = UpdateManifest(version: "1.1.0", url: URL(string: "https://example.com/Tab.zip")!, sha256: "")
        let data = try JSONEncoder().encode(PendingUpdateRecord.Stored(manifest: manifest, staging: "/tmp/x", scheduled: false))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["scheduled"] as? Bool, false)
        let withoutScheduled = try JSONSerialization.data(withJSONObject: object.filter { $0.key != "scheduled" })
        XCTAssertNoThrow(try JSONDecoder().decode(PendingUpdateRecord.Stored.self, from: withoutScheduled))
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

    func testInstallationsThisAccountCannotChangeAreRefusedBeforeDownloading() throws {
        let root = try temporaryFolder()
        let current = root.appendingPathComponent("Tab.app")
        let staging = root.appendingPathComponent(".tab-update-test")
        let next = staging.appendingPathComponent("Tab.app")
        for folder in [current, next] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        XCTAssertTrue(Installation.canReplace(current))
        // An app an administrator installed: its folder, or the bundle itself,
        // is read-only to this account, and the swap fails exactly then.
        for locked in [root, current] {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            XCTAssertFalse(Installation.canReplace(current), locked.lastPathComponent)
            XCTAssertThrowsError(try BundleReplacement.replace(
                current: current, next: next, backup: staging.appendingPathComponent("previous.app")))
            XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
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
