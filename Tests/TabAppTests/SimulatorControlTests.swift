import XCTest
@testable import TabApp

final class SimulatorControlTests: XCTestCase {
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
        let devices = try SimulatorControl.parse(Data(json.utf8))
        XCTAssertEqual(devices.map(\.udid), ["B", "D", "A"])
        XCTAssertEqual(devices[0].state, .booted)
        XCTAssertEqual(devices[1].runtime, "iOS 27.1")
        XCTAssertEqual(SimulatorControl.runtimeName("com.apple.CoreSimulator.SimRuntime.xrOS-3-0"), "xrOS 3.0")
        XCTAssertEqual(SimulatorControl.runtimeName("custom"), "custom")
    }

    func testOrientationMapsWhatYouSeeOntoThePortraitPanel() throws {
        let topLeft = CGPoint(x: 0, y: 0)
        XCTAssertEqual(DeviceOrientation.portrait.panelPoint(topLeft), CGPoint(x: 0, y: 0))
        XCTAssertEqual(DeviceOrientation.landscapeLeft.panelPoint(topLeft), CGPoint(x: 1, y: 0))
        XCTAssertEqual(DeviceOrientation.portraitUpsideDown.panelPoint(topLeft), CGPoint(x: 1, y: 1))
        XCTAssertEqual(DeviceOrientation.landscapeRight.panelPoint(topLeft), CGPoint(x: 0, y: 1))
        XCTAssertEqual(DeviceOrientation(quarterTurns: -1), .landscapeRight)
        XCTAssertEqual(DeviceOrientation(quarterTurns: 5), .landscapeLeft)
        let json = #"{"info": {"outcome": "success"}, "result": {"deviceOrientation": "faceUp", "deviceOrientationNonFlat": "landscapeLeft"}}"#
        XCTAssertEqual(try SimulatorControl.parseOrientation(Data(json.utf8)), .landscapeLeft)
    }
}
