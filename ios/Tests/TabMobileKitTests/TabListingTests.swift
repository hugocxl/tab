import TabProtocol
import XCTest
@testable import TabMobileKit

/// The card titles follow the desktop sidebar's reading of terminal titles.
@MainActor
final class TabListingTests: XCTestCase {
    func testIdleShellTitlesNameTheirFolder() {
        XCTAssertEqual(ServerModel.idleDirectory("~/repos/tabios"), "tabios")
        XCTAssertEqual(ServerModel.idleDirectory("hugo@mac:~/code/app/"), "app")
        XCTAssertEqual(ServerModel.idleDirectory("(mac) /usr/local"), "local")
        XCTAssertEqual(ServerModel.idleDirectory("/"), "/")
        XCTAssertNil(ServerModel.idleDirectory("npm run dev"))
        XCTAssertNil(ServerModel.idleDirectory("~/a b"))
    }

    func testAgentTaskDropsSpinnersAndBareNames() {
        XCTAssertEqual(ServerModel.taskTitle("✳ Fix the login bug", provider: .claude), "Fix the login bug")
        XCTAssertNil(ServerModel.taskTitle("✳ Claude Code", provider: .claude))
    }

    func testElapsedTimeReadsLikeTheDesktop() {
        XCTAssertEqual(ServerModel.elapsedText(43), "43s")
        XCTAssertEqual(ServerModel.elapsedText(185), "3m")
        XCTAssertEqual(ServerModel.elapsedText(3780), "1h 3m")
        XCTAssertEqual(ServerModel.secondsUntilElapsedChanges(61.5), 58.5, accuracy: 0.001)
    }

    func testTheHostThatAnsweredLastIsTriedFirst() {
        var server = PairedServer(id: ServerId(), name: "Mac", hosts: ["192.168.1.2", "100.64.0.3", "mac.local"],
                                  port: 7419, fingerprint: Data(count: 32), device: DeviceId())
        XCTAssertEqual(server.orderedHosts, ["192.168.1.2", "100.64.0.3", "mac.local"])
        server.lastHost = "100.64.0.3"
        XCTAssertEqual(server.orderedHosts, ["100.64.0.3", "192.168.1.2", "mac.local"])
        server.lastHost = "gone.local"
        XCTAssertEqual(server.orderedHosts.first, "192.168.1.2")
    }
}
