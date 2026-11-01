import XCTest
@testable import TabApp

final class SidebarElapsedTests: XCTestCase {
    func testElapsedTextAndNextChange() {
        XCTAssertEqual(ActivityCardData.elapsedText(-2), "0s")
        XCTAssertEqual(ActivityCardData.elapsedText(43.9), "43s")
        XCTAssertEqual(ActivityCardData.elapsedText(60), "1m")
        XCTAssertEqual(ActivityCardData.elapsedText(3599), "59m")
        XCTAssertEqual(ActivityCardData.elapsedText(3780), "1h 3m")
        XCTAssertEqual(ActivityCardData.secondsUntilElapsedChanges(43.25), 0.75, accuracy: 0.001)
        XCTAssertEqual(ActivityCardData.secondsUntilElapsedChanges(59.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(ActivityCardData.secondsUntilElapsedChanges(190), 50, accuracy: 0.001)
    }
}
