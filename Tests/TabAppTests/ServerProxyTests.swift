import TabProtocol
import XCTest
@testable import TabApp

/// The SOCKS5 handshake of a remote tab's browser proxy, and the reserved
/// names that keep `localhost` going through it.
final class ServerProxyTests: XCTestCase {
    func testTheHandshakeNeedsThePasswordMethodAndTheProxysCredentials() {
        XCTAssertEqual(SOCKS5.greeting(Data([5])), .needMore)
        XCTAssertEqual(SOCKS5.greeting(Data([5, 2, 0, 2])), .done(true, consumed: 4))
        XCTAssertEqual(SOCKS5.greeting(Data([5, 1, 0])), .done(false, consumed: 3), "no password offered")
        XCTAssertEqual(SOCKS5.greeting(Data([4, 1, 0])), .invalid(reply: nil), "SOCKS4 is refused")

        func auth(_ user: String, _ pass: String) -> Data {
            Data([1, UInt8(user.utf8.count)] + Array(user.utf8) + [UInt8(pass.utf8.count)] + Array(pass.utf8))
        }
        XCTAssertEqual(SOCKS5.credentials(auth("u", "secret"), username: "u", password: "secret"), .done(true, consumed: 10))
        XCTAssertEqual(SOCKS5.credentials(auth("u", "guess!"), username: "u", password: "secret"), .done(false, consumed: 10))
        XCTAssertEqual(SOCKS5.credentials(auth("other", "secret"), username: "u", password: "secret"),
                       .done(false, consumed: 14))
        XCTAssertEqual(SOCKS5.credentials(auth("u", "secret").prefix(5), username: "u", password: "secret"), .needMore)
        XCTAssertEqual(SOCKS5.credentials(Data([2, 0, 0]), username: "u", password: "p"), .invalid(reply: Data([1, 1])))
    }

    func testConnectRequestsKeepNamesForTheServerToResolve() {
        let name = Data([5, 1, 0, 3, 9] + Array("localhost".utf8) + [0x0B, 0xB8])
        XCTAssertEqual(SOCKS5.request(name), .done(SOCKS5.Target(host: "localhost", port: 3000), consumed: 16))
        XCTAssertEqual(SOCKS5.request(name.prefix(10)), .needMore)
        let ipv4 = Data([5, 1, 0, 1, 127, 0, 0, 1, 0x1F, 0x91])
        XCTAssertEqual(SOCKS5.request(ipv4), .done(SOCKS5.Target(host: "127.0.0.1", port: 8081), consumed: 10))
        let ipv6 = Data([5, 1, 0, 4] + [UInt8](repeating: 0, count: 15) + [1, 0, 80])
        XCTAssertEqual(SOCKS5.request(ipv6), .done(SOCKS5.Target(host: "::1", port: 80), consumed: 22))
        XCTAssertEqual(SOCKS5.request(Data([5, 2, 0, 1, 1, 2, 3, 4, 0, 80])), .invalid(reply: SOCKS5.reply(.commandNotSupported)),
                       "only CONNECT")
        XCTAssertEqual(SOCKS5.request(Data([5, 1, 0, 9, 0])), .invalid(reply: SOCKS5.reply(.addressNotSupported)))
        XCTAssertEqual(SOCKS5.request(Data([5, 1, 0, 3, 3] + Array("a\nb".utf8) + [0, 80])),
                       .invalid(reply: SOCKS5.reply(.addressNotSupported)), "control characters aren't names")
        XCTAssertEqual(SOCKS5.request(Data([5, 1, 0, 1, 1, 2, 3, 4, 0, 0])), .invalid(reply: SOCKS5.reply(.notAllowed)))
    }

    func testLoopbackLoadsUnderReservedNamesAndShowsTheRealOnes() {
        XCTAssertEqual(RemoteLoopback.proxied("http://localhost:3000/a?b=1"), "http://localhost.tab-remote:3000/a?b=1")
        XCTAssertEqual(RemoteLoopback.proxied("http://127.0.0.1:8081/"), "http://127.0.0.1.tab-remote:8081/")
        XCTAssertEqual(RemoteLoopback.proxied("http://[::1]:5173/"), "http://ip6-localhost.tab-remote:5173/")
        XCTAssertEqual(RemoteLoopback.proxied("https://example.com/"), "https://example.com/")
        for url in ["http://localhost:3000/a?b=1", "http://127.0.0.1:8081/", "http://[::1]:5173/"] {
            XCTAssertEqual(RemoteLoopback.unproxied(RemoteLoopback.proxied(url)), url)
        }
        XCTAssertEqual(RemoteLoopback.unproxied("http://evil.tab-remote/"), "http://evil.tab-remote/")
        XCTAssertEqual(RemoteLoopback.serverHost("LOCALHOST.tab-remote"), "localhost")
        XCTAssertEqual(RemoteLoopback.serverHost("ip6-localhost.tab-remote"), "::1")
        XCTAssertEqual(RemoteLoopback.serverHost("example.com"), "example.com")
    }

    func testEachProfileGetsItsOwnStableStoreOnEachServer() {
        let server = ServerId()
        let first = BrowserProfiles.remoteIdentifier(profile: "", server: server)
        XCTAssertEqual(first, BrowserProfiles.remoteIdentifier(profile: "", server: server))
        XCTAssertNotEqual(first, BrowserProfiles.remoteIdentifier(profile: "work", server: server))
        XCTAssertNotEqual(first, BrowserProfiles.remoteIdentifier(profile: "", server: ServerId()))
    }
}
