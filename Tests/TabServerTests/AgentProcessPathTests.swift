import XCTest
@testable import TabServer

final class AgentProcessPathTests: XCTestCase {
    /// launchd hands GUI apps `/usr/bin:/bin:...`; agents' git hooks then ran macOS's Python 3.9.
    func testHomebrewBeatsSystemDirectoriesFromLaunchdPath() {
        let path = AgentProcess.path(inherited: "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", home: "/h")
            .split(separator: ":").map(String.init)
        XCTAssertLessThan(path.firstIndex(of: "/opt/homebrew/bin")!, path.firstIndex(of: "/usr/bin")!)
        XCTAssertLessThan(path.firstIndex(of: "/h/.local/share/mise/shims")!, path.firstIndex(of: "/usr/bin")!)
        XCTAssertEqual(Array(path.suffix(4)), ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        XCTAssertEqual(path.count, Set(path).count)
    }

    func testInheritedUserOrderStaysFirst() {
        let path = AgentProcess.path(inherited: "/custom/bin:/usr/bin:/opt/homebrew/bin", home: "/h")
            .split(separator: ":").map(String.init)
        XCTAssertEqual(Array(path.prefix(2)), ["/custom/bin", "/opt/homebrew/bin"])
    }
}
