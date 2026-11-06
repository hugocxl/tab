import XCTest
import TabProtocol
@testable import TabSimulators

final class IOSSimulatorControlTests: XCTestCase {
    func testParsesSimctlListingBootedFirstThenMostRecentlyUsed() throws {
        let json = #"""
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {"udid": "A", "name": "iPhone 17", "state": "Shutdown", "isAvailable": true, "lastUsedAt": "2026-10-01T10:00:00Z"},
            {"udid": "B", "name": "iPhone 18 Pro", "state": "Booted", "isAvailable": true},
            {"udid": "C", "name": "Broken", "state": "Shutdown", "isAvailable": false}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
            {"udid": "D", "name": "iPhone Duo", "state": "Shutdown", "lastUsedAt": "2026-10-30T16:15:39Z", "extra": 1}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-12-0": []
        }}
        """#
        let simulators = try IOSSimulatorControl.parse(Data(json.utf8))
        XCTAssertEqual(simulators.map(\.udid), ["B", "D", "A"])
        XCTAssertEqual(simulators[0].state, .booted)
        XCTAssertEqual(simulators[1].runtime, "iOS 27.1")
        XCTAssertEqual(IOSSimulatorControl.runtimeName("com.apple.CoreSimulator.SimRuntime.xrOS-3-0"), "xrOS 3.0")
        XCTAssertEqual(IOSSimulatorControl.runtimeName("custom"), "custom")
    }

    func testOrientationMapsWhatYouSeeOntoThePortraitPanel() throws {
        let topLeft = CGPoint(x: 0, y: 0)
        XCTAssertEqual(SimulatorOrientation.portrait.panelPoint(topLeft), CGPoint(x: 0, y: 0))
        XCTAssertEqual(SimulatorOrientation.landscapeLeft.panelPoint(topLeft), CGPoint(x: 1, y: 0))
        XCTAssertEqual(SimulatorOrientation.portraitUpsideDown.panelPoint(topLeft), CGPoint(x: 1, y: 1))
        XCTAssertEqual(SimulatorOrientation.landscapeRight.panelPoint(topLeft), CGPoint(x: 0, y: 1))
        XCTAssertEqual(SimulatorOrientation(quarterTurns: -1), .landscapeRight)
        XCTAssertEqual(SimulatorOrientation(quarterTurns: 5), .landscapeLeft)
        let json = #"{"info": {"outcome": "success"}, "result": {"simulatorOrientation": "faceUp", "deviceOrientationNonFlat": "landscapeLeft"}}"#
        XCTAssertEqual(try IOSSimulatorControl.parseOrientation(Data(json.utf8)), .landscapeLeft)
    }
}
