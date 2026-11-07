import TabProtocol
import XCTest
@testable import TabMobileUI

/// Where a finger lands on the simulator, however it is turned.
@MainActor
final class SimulatorScreenTests: XCTestCase {
    func testTheScreenFitsCentered() {
        let rect = SimulatorScreenView.screenRect(upright: CGSize(width: 1000, height: 2000),
                                                  in: CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(rect, CGRect(x: 100, y: 0, width: 200, height: 400))
    }

    func testTouchesLandOnThePanelAsHeld() {
        let rect = CGRect(x: 100, y: 0, width: 200, height: 400)
        XCTAssertEqual(SimulatorScreenView.panelPoint(CGPoint(x: 150, y: 100), screen: rect, orientation: .portrait),
                       .touch(x: 0.25, y: 0.25, down: true))
        // Turned left, the upright top left is the panel's top right.
        XCTAssertEqual(SimulatorScreenView.panelPoint(CGPoint(x: 100, y: 0), screen: rect, orientation: .landscapeLeft),
                       .touch(x: 1, y: 0, down: true))
        XCTAssertEqual(SimulatorScreenView.panelPoint(CGPoint(x: -50, y: 900), screen: rect, orientation: .portrait),
                       .touch(x: 0, y: 1, down: true), "a drag off the screen stays on its edge")
    }
}
