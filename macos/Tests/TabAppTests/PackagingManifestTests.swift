import CryptoKit
import Foundation
import TabProtocol
import XCTest
@testable import TabApp

final class PackagingManifestTests: XCTestCase {
    func testGeneratedManifestIsAcceptedByUpdaterAndHashesFinalBytes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(try fixture.generate(), 0)
        let data = try Data(contentsOf: fixture.output)
        let manifest = try XCTUnwrap(UpdateFeed.parse(data, current: "0.1.0",
            systemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)))
        XCTAssertEqual(manifest.version, "1.2.3")
        XCTAssertEqual(manifest.url.absoluteString,
            "https://github.com/hugocxl/tab/releases/download/v1.2.3/Tab-1.2.3-arm64.dmg")
        XCTAssertEqual(manifest.size, Int64(fixture.bytes.count))
        XCTAssertEqual(manifest.sha256, SHA256.hash(data: fixture.bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(manifest.protocolVersions, [ProtocolVersion(1)])
        XCTAssertEqual(manifest.minimumSystemVersion, "14.0")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["teamID"] as? String, "ABCDEFGHIJ")
        let build = try XCTUnwrap(object["buildInfo"] as? [String: Any])
        XCTAssertEqual(build["version"] as? String, manifest.version)
        XCTAssertEqual(build["compatibility"] as? Int, 21)
    }

    func testReleaseKeySignsTheFeedOfABetaThatTheUpdaterTrusts() throws {
        let fixture = try Fixture(version: "1.2.3-beta.45")
        defer { fixture.remove() }
        let key = Curve25519.Signing.PrivateKey()
        XCTAssertEqual(try fixture.generate(signingKey: key.rawRepresentation.base64EncodedString()), 0)
        let data = try Data(contentsOf: fixture.output)
        let manifest = try XCTUnwrap(UpdateFeed.parse(data, current: "1.2.3-beta.44",
            systemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
            signedBy: key.publicKey.rawRepresentation))
        XCTAssertEqual(manifest.url.absoluteString,
            "https://github.com/hugocxl/tab/releases/download/v1.2.3-beta.45/Tab-1.2.3-beta.45-arm64.dmg")
        XCTAssertThrowsError(try UpdateFeed.parse(data, current: "1.2.3-beta.44",
            systemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
            signedBy: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        XCTAssertNotEqual(try fixture.generate(signingKey: "not a key"), 0)
    }

    func testMismatchedPackagedBuildsCannotProduceAFeed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.executable("tab", version: "1.2.4")
        XCTAssertNotEqual(try fixture.generate(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
    }

    private struct Fixture {
        let root: URL
        let app: URL
        let dmg: URL
        let output: URL
        let bytes = Data("final signed and stapled disk image bytes".utf8)

        init(version: String = "1.2.3") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-packaging-\(UUID().uuidString)")
            app = root.appendingPathComponent("Tab.app")
            dmg = root.appendingPathComponent("Tab-\(version)-arm64.dmg")
            output = root.appendingPathComponent("update.json")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let info = ["CFBundleShortVersionString": "1.2.3", "TabVersion": version, "LSMinimumSystemVersion": "14.0"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            try bytes.write(to: dmg)
            try executable("tab", version: version)
            try executable("tabd", version: version)
        }

        func executable(_ name: String, version: String) throws {
            let url = app.appendingPathComponent("Contents/MacOS/\(name)")
            let script = "#!/bin/sh\nprintf '%s' '{\"version\":\"\(version)\",\"protocol\":[1],\"compatibility\":21}'\n"
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func generate(signingKey: String? = nil) throws -> Int32 {
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
            process.arguments = [repository.appendingPathComponent("scripts/release-metadata.swift").path,
                app.path, dmg.path, "ABCDEFGHIJ", output.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["UPDATE_SIGNING_KEY"] = signingKey
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
