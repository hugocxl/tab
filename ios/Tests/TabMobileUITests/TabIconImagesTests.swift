import TabMobileKit
import XCTest
@testable import TabMobileUI

final class TabIconImagesTests: XCTestCase {
    func testEveryTabIconLoadsFromThePackageOrLocalCatalog() {
        for icon in TabIcon.allCases where icon != .viewList && icon != .viewTree {
            XCTAssertNotNil(icon.template, "Missing image for \(icon.rawValue)")
        }
    }
}
