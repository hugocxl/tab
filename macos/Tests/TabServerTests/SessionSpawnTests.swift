import Foundation
import TabCore
import TabProtocol
import TabTerminal
import XCTest
@testable import TabServer

final class SessionSpawnTests: XCTestCase {
    private let environment = ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"]

    private func spawn(_ startup: [String], command: String? = nil) -> SpawnRequest {
        SessionSpawn.request(settings: ServerSettingsDoc(startupCommand: startup, shellIntegration: false), integration: nil,
                             directory: "/tmp", size: Size(cols: 80, rows: 24), command: command, extra: [:],
                             server: ServerId(), session: SessionId(), inherited: environment)
    }

    func testStartupCommandRunsAsGivenAndAShellAloneStaysALoginShell() {
        let login = spawn([])
        XCTAssertEqual(login.program, "/bin/zsh")
        XCTAssertEqual(login.arguments, ["-l"])

        let bash = spawn(["bash"])
        XCTAssertEqual(bash.program, "/bin/bash", "a program name is found on PATH")
        XCTAssertEqual(bash.arguments, ["-l"])
        XCTAssertEqual(bash.environment["SHELL"], "/bin/bash")

        let custom = spawn(["/bin/bash", "--norc", "-i"])
        XCTAssertEqual(custom.arguments, ["--norc", "-i"])

        let program = spawn(["/bin/cat", "-u"])
        XCTAssertEqual(program.program, "/bin/cat")
        XCTAssertEqual(program.arguments, ["-u"])
        XCTAssertEqual(program.environment["SHELL"], "/bin/zsh")
    }

    func testPaneCommandsRunInTheStartupShellOrTheLoginShell() {
        let inShell = spawn(["/bin/bash", "--norc"], command: "make test")
        XCTAssertEqual(inShell.program, "/bin/bash")
        XCTAssertEqual(inShell.arguments, ["-l", "-c", "make test"])

        let notAShell = spawn(["/bin/cat"], command: "make test")
        XCTAssertEqual(notAShell.program, "/bin/zsh")
        XCTAssertEqual(notAShell.arguments, ["-l", "-c", "make test"])

        let missing = spawn(["no-such-program-for-tab"])
        XCTAssertEqual(missing.program, "/bin/zsh", "a startup command that no longer resolves falls back to the login shell")
    }
}
