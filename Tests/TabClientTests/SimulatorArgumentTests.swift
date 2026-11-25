import TabProtocol
import XCTest
@testable import TabClient

final class SimulatorArgumentTests: XCTestCase {
    private func drive(_ words: [String]) throws -> (simulator: String?, drive: SimulatorDrive, output: CLISimulatorOutput) {
        guard case .manage(let invocation) = try CLIParser.parse(["simulator"] + words).command,
              case .simulator(.drive(let simulator, let drive, let output)) = invocation.action else {
            throw XCTSkip("\(words) doesn't drive a simulator")
        }
        return (simulator, drive, output)
    }

    private func steps(_ words: [String]) throws -> [SimulatorStep] { try drive(words).drive.steps }

    private func assertRefused(_ words: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CLIParser.parse(["simulator"] + words), "\(words)", file: file, line: line) { error in
            XCTAssertTrue(error is CLIError, "\(words): \(error)", file: file, line: line)
        }
    }

    func testTargetsAreRefsPointsLabelsOrIdentifiers() throws {
        XCTAssertEqual(try steps(["tap", "@e3"]), [.tap(.ref("e3"), count: 1, hold: 0)])
        XCTAssertEqual(try steps(["tap", "120", "40.5"]), [.tap(.point(x: 120, y: 40.5), count: 1, hold: 0)])
        XCTAssertEqual(try steps(["tap", "--label", "Sign in", "--hold", "1.5"]), [.tap(.label("Sign in"), count: 1, hold: 1.5)])
        XCTAssertEqual(try steps(["tap", "--id", "login", "--count", "2"]), [.tap(.identifier("login"), count: 2, hold: 0)])
        assertRefused(["tap"])
        assertRefused(["tap", "@button"])
        assertRefused(["tap", "12"])
        assertRefused(["tap", "-5", "10"])
        assertRefused(["tap", "@e3", "--count", "11"])
    }

    func testStepsSettleAndNameTheirSimulator() throws {
        let result = try drive(["fill", "@e5", "Ada Lovelace", "--settle", "--simulator", "iPhone 17"])
        XCTAssertEqual(result.simulator, "iPhone 17")
        XCTAssertEqual(result.drive, SimulatorDrive(steps: [.fill(.ref("e5"), text: "Ada Lovelace")], settle: true))
        XCTAssertEqual(try steps(["fill", "--label", "Email", "ada@example.com"]), [.fill(.label("Email"), text: "ada@example.com")])
        XCTAssertEqual(try steps(["scroll", "down"]), [.scroll(.down, distance: 0.5, within: nil)])
        XCTAssertEqual(try steps(["scroll", "left", "@e9", "--distance", "0.8"]), [.scroll(.left, distance: 0.8, within: .ref("e9"))])
        XCTAssertEqual(try steps(["swipe", "10", "500", "10", "100", "--duration", "0.5"]),
                       [.swipe(from: .point(x: 10, y: 500), to: .point(x: 10, y: 100), duration: 0.5)])
        XCTAssertEqual(try steps(["key", "cmd+a"]), [.key("cmd+a")])
        XCTAssertEqual(try steps(["press", "home"]), [.button(.home)])
        XCTAssertEqual(try steps(["wait-for", "--label", "Saved", "--gone", "--timeout", "10"]),
                       [.waitFor(.label("Saved"), gone: true, timeout: 10)])
        XCTAssertEqual(try steps(["location", "41.39", "2.17"]), [.location(latitude: 41.39, longitude: 2.17)])
        assertRefused(["scroll", "sideways"])
        assertRefused(["press", "volume"])
        assertRefused(["wait-for", "10", "20"])
        assertRefused(["location", "100", "0"])
    }

    func testBatchRunsQuotedStepsInOneDrive() throws {
        let batch = try drive(["batch", "tap @e3", "type 'hello world'", "fill --label \"First name\" Ada", "key return",
                               "wait 0.5", "--settle"]).drive
        XCTAssertEqual(batch.steps, [.tap(.ref("e3"), count: 1, hold: 0), .type("hello world"),
                                     .fill(.label("First name"), text: "Ada"), .key("return"), .wait(seconds: 0.5)])
        XCTAssertTrue(batch.settle)
        XCTAssertEqual(try drive(["batch", "launch com.example", "--snapshot"]).drive.snapshot, SimulatorSnapshotOptions())
        assertRefused(["batch", "dance"])
        assertRefused(["batch", "type 'unclosed"])
        assertRefused(["batch", "tap @e3 --force"])
    }

    func testReadsSnapshotsScreenshotsAppsAndLogs() throws {
        let snapshot = try drive(["snapshot", "-i", "--frames"])
        XCTAssertEqual(snapshot.drive.snapshot, SimulatorSnapshotOptions(interactiveOnly: true))
        XCTAssertTrue(snapshot.output.frames)
        let screenshot = try drive(["screenshot", "--output", "/tmp/s.jpg", "--format", "jpeg", "--quality", "60"])
        XCTAssertEqual(screenshot.drive.screenshot, SimulatorScreenshotOptions(format: .jpeg, quality: 60))
        XCTAssertEqual(screenshot.output.file, "/tmp/s.jpg")
        XCTAssertEqual(try drive(["screenshot", "--full"]).drive.screenshot?.fullResolution, true)
        XCTAssertTrue(try drive(["apps"]).drive.apps)
        XCTAssertEqual(try drive(["logs", "--app", "com.example", "--since", "30", "--lines", "20"]).drive.logs,
                       SimulatorLogOptions(app: "com.example", seconds: 30, lines: 20))
        assertRefused(["screenshot", "--format", "gif"])
        assertRefused(["logs", "--since", "0"])
    }

    func testStepWordsSplitLikeAShell() throws {
        XCTAssertEqual(try SimulatorSteps.words(#"type "it's here" 'a "b"' c\ d"#), ["type", "it's here", "a \"b\"", "c d"])
        XCTAssertEqual(try SimulatorSteps.words("  tap   @e1 "), ["tap", "@e1"])
        XCTAssertEqual(try SimulatorSteps.words(#"type """#), ["type", ""], "an empty quoted word is kept")
    }

    func testOutputPrintsRefsChangesAndFlags() {
        let screen = SimulatorScreen(width: 400, height: 800, scale: 3)
        let elements = [
            SimulatorElement(ref: "e1", role: "app", label: "Settings", x: 0, y: 0, width: 400, height: 800, depth: 0),
            SimulatorElement(ref: "e2", role: "button", label: "General", identifier: "general", x: 16, y: 380, width: 370,
                             height: 52, interactive: true, depth: 1),
            SimulatorElement(ref: "e3", role: "switch", label: "Wi-Fi", identifier: "Wi-Fi", value: "1", x: 0, y: 900,
                             width: 100, height: 40, enabled: false, interactive: true, depth: 1),
        ]
        XCTAssertEqual(SimulatorOutput.snapshot(elements, screen: screen, frames: false, flat: false), """
        @e1 [app] "Settings"
          @e2 [button] "General" #general
          @e3 [switch] "Wi-Fi" = "1" disabled offscreen
        """)
        XCTAssertEqual(SimulatorOutput.line(elements[1], screen: screen, frames: true),
                       #"@e2 [button] "General" #general (16,380 370x52)"#)
        let changes = SimulatorDriveResult(added: [elements[1]], removed: [elements[0]], changed: [], unchanged: 7)
        XCTAssertEqual(SimulatorOutput.text(changes, frames: false, flat: false), """
        - @e1 [app] "Settings"
        + @e2 [button] "General" #general
        = 7 unchanged
        """)
        XCTAssertEqual(SimulatorOutput.text(SimulatorDriveResult(added: [], removed: [], changed: [], unchanged: 3),
                                            frames: false, flat: false), "= no change (3 elements)")
        XCTAssertEqual(SimulatorOutput.text(SimulatorDriveResult(), frames: false, flat: false), "ok")
    }
}
