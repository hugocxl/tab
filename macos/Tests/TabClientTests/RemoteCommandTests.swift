import Foundation
import TabCore
import XCTest
@testable import TabClient

final class RemoteCommandTests: XCTestCase {
    func testCommandsPreserveAuthenticationAndHostKeyFailures() async throws {
        for (message, reason) in [
            ("Permission denied (publickey,password).", RemoteReason.authenticationFailed),
            ("Host key verification failed.", .hostKeyUnknown),
            ("REMOTE HOST IDENTIFICATION HAS CHANGED", .hostKeyChanged),
        ] {
            let target = try SSHTarget.customCommand("/bin/sh -c 'echo \"\(message)\" >&2; exit 255'")
            do {
                _ = try await RemoteServer.run("unused", on: target)
                XCTFail("The command must fail")
            } catch let error as ClientError {
                guard case .remote(let failure) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(failure.reason, reason)
                XCTAssertFalse(error.recoverable)
            }
        }
    }

    func testCommandsUseTheCustomPrefixAndKeepOutput() async throws {
        let target = try SSHTarget.customCommand("/bin/sh -c")
        let output = try await RemoteServer.run("printf 'remote output'", on: target)
        XCTAssertEqual(output, "remote output")
        do {
            _ = try await RemoteServer.run("echo 'download failed' >&2; exit 22", on: target)
            XCTFail("The command must fail")
        } catch let error as RemoteInstallError {
            XCTAssertEqual(error, .failed("download failed"))
        }
    }

    func testAFailedDownloadNeverExecutesAPartialInstaller() async throws {
        let root = URL(fileURLWithPath: "/tmp/tab-install-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let curl = root.appendingPathComponent("curl")
        let marker = root.appendingPathComponent("executed")
        let script = """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
            if [ "$1" = -o ]; then
                shift
                printf 'touch "\(marker.path)"\\n' > "$1"
                exit 22
            fi
            shift
        done
        exit 2
        """
        try script.write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: curl.path)
        let target = try SSHTarget.customCommand("/usr/bin/env PATH=\(root.path):/usr/bin:/bin TMPDIR=\(root.path) /bin/sh -c")
        do {
            _ = try await RemoteInstall.install(on: target, version: "1.4.0")
            XCTFail("The failed download must fail the install")
        } catch is RemoteInstallError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["curl"], "the partial installer is removed")
    }
}
