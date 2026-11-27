import XCTest
@testable import TabProtocol

final class SessionNameTests: XCTestCase {
    func testNamesAreStableAcrossBuildsAndShapedLikeNames() throws {
        let session = try XCTUnwrap(SessionId(string: "3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
        // Every build must derive this same name; changing the lists renames users' terminals.
        XCTAssertEqual(SessionName.of(session), "mossy-hawk")
        XCTAssertEqual(SessionName.adjectives.count, 128)
        XCTAssertEqual(SessionName.nouns.count, 128)
        XCTAssertEqual(Set(SessionName.adjectives).count, 128)
        XCTAssertEqual(Set(SessionName.nouns).count, 128)
        for _ in 0 ..< 100 { XCTAssertTrue(SessionName.isName(SessionName.of(SessionId()))) }
        XCTAssertFalse(SessionName.isName("3f2504e0"))
        XCTAssertFalse(SessionName.isName("Wispy-cedar"))
    }
}
