import Foundation
import CryptoKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

final class UpdaterProcessTests: XCTestCase {
    func testCodeshPlatformManifestAndChannelFeed() throws {
        let asset: [String: Any] = [
            "url": "https://github.com/hugocxl/tab/releases/download/v1.1.0/Tab-1.1.0-arm64.dmg",
            "size": 123,
            "sha256": String(repeating: "a", count: 64),
        ]
        var feed: [String: Any] = ["schema": 1, "version": "1.1.0", "platforms": ["macos-aarch64": asset]]
        let data = try JSONSerialization.data(withJSONObject: feed)
        let manifest = try XCTUnwrap(UpdateFeed.parse(data, current: "1.0.0"))
        XCTAssertEqual(manifest.size, 123)
        XCTAssertEqual(manifest.protocolVersions, [])
        XCTAssertEqual(UpdateFeed.url(channel: .beta).path, "/hugocxl/tab/releases/download/beta/update.json")
        XCTAssertEqual(UpdateFeed.url(channel: .stable).path, "/hugocxl/tab/releases/latest/download/update.json")
        feed["schema"] = 2
        XCTAssertThrowsError(try UpdateFeed.parse(JSONSerialization.data(withJSONObject: feed), current: "1.0.0"))
        feed["schema"] = 1
        feed["platforms"] = ["macos-x86_64": asset]
        XCTAssertThrowsError(try UpdateFeed.parse(JSONSerialization.data(withJSONObject: feed), current: "1.0.0"))
    }

    private func fixture() throws -> (root: URL, archive: URL, manifest: UpdateManifest) {
        let root = URL(fileURLWithPath: "/tmp/tab-update-test").appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source/Tab.app")
        let macOS = source.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let build = BuildInfo(version: "1.1.0", protocolVersions: [ProtocolVersion(2)])
        let json = String(decoding: try JSONEncoder().encode(build), as: UTF8.self)
        for name in [Executable.app, Executable.cli, Executable.server] {
            let binary = macOS.appendingPathComponent(name)
            try "#!/bin/sh\nprintf '%s' '\(json)'\n".write(to: binary, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        let info: [String: Any] = [
            "CFBundleIdentifier": Release.bundleIdentifier,
            "CFBundleExecutable": Executable.app,
            "CFBundleShortVersionString": "1.1.0",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: source.appendingPathComponent("Contents/Info.plist"))
        let archive = root.appendingPathComponent("release.zip")
        try Installation.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, archive.path])
        let hash = try UpdateDownloader.sha256(of: archive)
        let size = (try fm.attributesOfItem(atPath: archive.path)[.size] as! NSNumber).int64Value
        let manifest = UpdateManifest(version: "1.1.0", url: URL(string: "https://github.com/hugocxl/tab/releases/download/v1.1.0/Tab.zip")!,
                                      sha256: hash, size: size)
        return (root, archive, manifest)
    }

    func testLocalHTTPDownloadRejectsCorruptionAndBoundsBothResponses() async throws {
        let (root, archive, release) = try fixture()
        let fm = FileManager.default
        let hash = release.sha256
        let size = try XCTUnwrap(release.size)
        let feed: [String: Any] = ["schema": 1, "version": "1.1.0", "platforms": ["macos-aarch64": [
            "url": "https://github.com/hugocxl/tab/releases/download/v1.1.0/Tab-1.1.0-arm64.dmg",
            "size": size, "sha256": hash,
        ]]]
        try JSONSerialization.data(withJSONObject: feed).write(to: root.appendingPathComponent("update.json"))
        try Data(repeating: 32, count: UpdateFeed.maximumFeedSize + 1).write(to: root.appendingPathComponent("oversize.json"))
        let server = try startHTTP(in: root)
        defer { server.process.terminate(); server.process.waitUntilExit() }
        let downloads = root.appendingPathComponent("downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        var manifest = UpdateManifest(version: "1.1.0", url: server.url.appendingPathComponent("release.zip"), sha256: hash, size: size)
        let downloader = UpdateDownloader()
        let latest = try await downloader.latest(current: "1.0.0", feedURL: server.url.appendingPathComponent("update.json"))
        XCTAssertEqual(latest?.version, "1.1.0")
        do {
            _ = try await downloader.latest(current: "1.0.0", feedURL: server.url.appendingPathComponent("oversize.json"))
            XCTFail("accepted an oversized feed")
        } catch {
            XCTAssertEqual(error as? UpdateError, .invalidFeed("The update feed is too large"))
        }
        let download = try await downloader.download(manifest, into: downloads)
        XCTAssertEqual(try Data(contentsOf: download), try Data(contentsOf: archive))
        manifest.sha256 = String(repeating: "0", count: 64)
        do {
            _ = try await downloader.download(manifest, into: downloads)
            XCTFail("accepted a corrupt download")
        } catch {
            XCTAssertEqual(error as? UpdateError, .checksumMismatch)
        }
        XCTAssertFalse(fm.fileExists(atPath: download.path))
        manifest.sha256 = hash
        manifest.size = size - 1
        do {
            _ = try await downloader.download(manifest, into: downloads)
            XCTFail("accepted an oversized download")
        } catch {
            XCTAssertEqual(error as? UpdateError, .sizeMismatch)
        }
        XCTAssertFalse(fm.fileExists(atPath: download.path))
        manifest.size = size
        _ = try await downloader.download(manifest, into: downloads)
    }

    func testLocalArchiveExtractionSignatureRejectionSwapAndRollback() throws {
        let (root, verified, manifest) = try fixture()
        let fm = FileManager.default
        try UpdateDownloader.verify(verified, sha256: manifest.sha256, size: manifest.size)
        let candidate = root.appendingPathComponent(".tab-update-fixture/Tab.app")
        try fm.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Installation.extract(verified, appName: "Tab.app", to: candidate)
        try Installation.checkContents(candidate, version: "1.1.0")
        XCTAssertEqual(try BundledBuild.check(in: candidate.appendingPathComponent("Contents/MacOS"), version: "1.1.0"),
                       BuildInfo(version: "1.1.0", protocolVersions: [ProtocolVersion(2)]))
        let current = root.appendingPathComponent("Tab.app")
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("old bundle".utf8).write(to: current.appendingPathComponent("marker"))
        let installation = Installation(bundle: current, team: "TESTTEAM00")
        XCTAssertThrowsError(try installation.verifyApp(candidate, version: "1.1.0"))
        XCTAssertThrowsError(try installation.prepare(archive: verified, manifest: manifest))
        let unsignedImage = root.appendingPathComponent("unsigned.dmg")
        try fm.copyItem(at: verified, to: unsignedImage)
        XCTAssertThrowsError(try installation.prepare(archive: unsignedImage, manifest: manifest)) { error in
            XCTAssertEqual(error as? UpdateError, .invalidBundle("The update disk image isn't signed by the same developer as this app."))
        }
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("marker"), encoding: .utf8), "old bundle")
        let backup = candidate.deletingLastPathComponent().appendingPathComponent("previous.app")
        struct RelaunchFailure: Error {}
        XCTAssertThrowsError(try BundleReplacement.replace(current: current, next: candidate, backup: backup) { throw RelaunchFailure() })
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent("marker").path))
        try BundleReplacement.replace(current: current, next: candidate, backup: backup)
        try Installation.checkContents(current, version: "1.1.0")
        XCTAssertTrue(fm.fileExists(atPath: backup.appendingPathComponent("marker").path))
    }

    func testStreamingDownloadVerificationAndRemovalWithoutASocket() async throws {
        let (root, _, _) = try fixture()
        let data = UpdateHTTPFixture.payload
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateHTTPFixture.self]
        let downloader = UpdateDownloader(configuration: configuration)
        var manifest = UpdateManifest(version: "1.1.0", url: URL(string: "https://updates.test/release.zip")!,
                                      sha256: hash, size: Int64(data.count))
        let downloaded = try await downloader.download(manifest, into: root)
        XCTAssertEqual(try Data(contentsOf: downloaded), data)
        manifest.sha256 = String(repeating: "0", count: 64)
        do {
            _ = try await downloader.download(manifest, into: root)
            XCTFail("accepted a corrupt response")
        } catch {
            XCTAssertEqual(error as? UpdateError, .checksumMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloaded.path))
        manifest.sha256 = hash
        manifest.size = Int64(data.count - 1)
        do {
            _ = try await downloader.download(manifest, into: root)
            XCTFail("accepted an oversized response")
        } catch {
            XCTAssertEqual(error as? UpdateError, .sizeMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloaded.path))
    }

    private func startHTTP(in directory: URL) throws -> (process: Process, url: URL) {
        let script = #"""
        import http.server, os, pathlib, sys
        os.chdir(sys.argv[1])
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args): pass
        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        pathlib.Path('port').write_text(str(server.server_port))
        server.serve_forever()
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", script, directory.path]
        process.standardInput = FileHandle.nullDevice
        let error = Pipe()
        process.standardError = error
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let portFile = directory.appendingPathComponent("port")
        for _ in 0..<100 {
            if let port = try? String(contentsOf: portFile, encoding: .utf8), let url = URL(string: "http://127.0.0.1:\(port)") {
                return (process, url)
            }
            if !process.isRunning {
                let reason = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if reason.contains("Operation not permitted") || reason.contains("Permission denied") {
                    throw XCTSkip("Sandbox refused the local HTTP listener: \(reason)")
                }
                XCTFail(reason)
                throw UpdateError.download("HTTP fixture did not start")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.terminate()
        process.waitUntilExit()
        throw UpdateError.download("HTTP fixture timed out")
    }
}

/// Exercises the HTTP stream without requiring a sandbox listener entitlement.
private final class UpdateHTTPFixture: URLProtocol, @unchecked Sendable {
    static let payload = Data(repeating: 65, count: 130_000)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "updates.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                                   headerFields: ["Content-Length": String(Self.payload.count)]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: Self.payload.count, by: 8192) {
            client?.urlProtocol(self, didLoad: Self.payload.subdata(in: offset..<min(offset + 8192, Self.payload.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
