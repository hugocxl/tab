import XCTest
@testable import TabProtocol

final class BuildInfoTests: XCTestCase {
    func testBuildMetadataUsesCodeshFieldsAndReadsEarlierTabBuilds() throws {
        let build = BuildInfo(version: "1.2.3")
        let data = try WireJSON.encode(build)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "compatibility", "protocol"])
        XCTAssertEqual(object["compatibility"] as? Int, 21)
        XCTAssertEqual(object["protocol"] as? [Int], [1])
        XCTAssertEqual(try WireJSON.decode(BuildInfo.self, from: data), build)
        XCTAssertEqual(try WireJSON.decode(BuildInfo.self, from: Data(#"{"version":"1.2.3","protocolVersions":[1]}"#.utf8)), build)
        let old = try WireJSON.decode(BuildInfo.self, from: Data(#"{"version":"1.2.3","compatibility":21}"#.utf8))
        XCTAssertTrue(old.protocolVersions.isEmpty)
        XCTAssertFalse(old.sharesProtocol(with: build))
    }
}
