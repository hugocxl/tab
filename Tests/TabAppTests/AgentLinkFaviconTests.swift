import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentLinkFaviconTests: XCTestCase {
    func testHostClassificationMatchesSource() throws {
        struct Fixture: Decodable { let host: String; let `public`: Bool }
        for fixture in try JSONDecoder().decode([Fixture].self, from: Data(Self.hosts.utf8)) {
            XCTAssertEqual(AgentFaviconHost.isPublic(fixture.host), fixture.public, fixture.host)
        }
    }

    func testURLCanonicalizationAndRequestMatchSource() throws {
        struct Fixture: Decodable { let url: String; let host: String; let request: String? }
        for fixture in try JSONDecoder().decode([Fixture].self, from: Data(Self.urls.utf8)) {
            let host = try XCTUnwrap(AgentLinkFavicon.host(for: XCTUnwrap(URL(string: fixture.url))))
            XCTAssertEqual(host, fixture.host, fixture.url)
            XCTAssertEqual(AgentLinkFavicon.requestURL(host: host)?.absoluteString, fixture.request, fixture.url)
        }
    }

    func testProviderArtworkAndPrivateFallbackDoNotFetch() throws {
        _ = NSApplication.shared
        var fetched = false
        let icons = AgentLinkFavicon(fetch: { _ in fetched = true; throw URLError(.badURL) })
        for host in ["github.com", "docs.github.com", "gitlab.com", "bitbucket.org", "codeberg.org", "git.cafe", "localhost", "10.0.0.1"] {
            let image = try XCTUnwrap(icons.image(for: XCTUnwrap(URL(string: "https://" + host)), color: .blue))
            XCTAssertEqual(image.size, NSSize(width: 14, height: 14), host)
        }
        XCTAssertFalse(fetched)
        XCTAssertNil(AgentLinkFavicon.brand(for: "notgithub.com"))
    }

    func testFetchIsCoalescedAndFailureSticks() async throws {
        var calls = 0
        let icons = AgentLinkFavicon(fetch: { _ in calls += 1; throw URLError(.cannotLoadFromNetwork) })
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        // A globe holds the place while the icon loads, so the link shows no gap.
        XCTAssertNotNil(icons.image(for: url, color: .blue))
        XCTAssertNotNil(icons.image(for: url, color: .blue))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(icons.image(for: url, color: .blue))
        XCTAssertEqual(calls, 1)
    }

    func testSuccessfulImageIsReused() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        var calls = 0
        let icons = AgentLinkFavicon(fetch: { _ in calls += 1; return data })
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let placeholder = try XCTUnwrap(icons.image(for: url, color: .blue))
        for _ in 0..<100 {
            if icons.image(for: url, color: .blue).map({ $0 !== placeholder && $0.size == NSSize(width: 14, height: 14) && calls == 1 }) == true,
               try XCTUnwrap(icons.image(for: url, color: .blue)) === icons.image(for: url, color: .red) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let image = try XCTUnwrap(icons.image(for: url, color: .blue))
        XCTAssertTrue(image === icons.image(for: url, color: .red))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(image.size, NSSize(width: 14, height: 14))
    }

    // Captured from source e5909e53 hostClassification.ts and favicon.ts.
    private static let hosts = ########"""
    [
      {
        "host": "isPublicFaviconHost",
        "public": false
      },
      {
        "host": "github.com",
        "public": true
      },
      {
        "host": "www.google.com",
        "public": true
      },
      {
        "host": "t3.chat",
        "public": true
      },
      {
        "host": "sub.domain.example.co.uk",
        "public": true
      },
      {
        "host": "8.8.8.8",
        "public": true
      },
      {
        "host": "1.1.1.1",
        "public": true
      },
      {
        "host": "100.200.1.1",
        "public": true
      },
      {
        "host": "172.32.0.1",
        "public": true
      },
      {
        "host": "192.167.1.1",
        "public": true
      },
      {
        "host": "11.0.0.1",
        "public": true
      },
      {
        "host": "0.0.0.0",
        "public": false
      },
      {
        "host": "10.0.0.1",
        "public": false
      },
      {
        "host": "10.255.255.255",
        "public": false
      },
      {
        "host": "127.0.0.1",
        "public": false
      },
      {
        "host": "192.168.1.10",
        "public": false
      },
      {
        "host": "172.16.0.1",
        "public": false
      },
      {
        "host": "172.31.255.255",
        "public": false
      },
      {
        "host": "169.254.1.1",
        "public": false
      },
      {
        "host": "100.64.0.1",
        "public": false
      },
      {
        "host": "100.100.100.100",
        "public": false
      },
      {
        "host": "100.126.17.15",
        "public": false
      },
      {
        "host": "100.127.255.255",
        "public": false
      },
      {
        "host": "100.63.255.255",
        "public": true
      },
      {
        "host": "100.128.0.1",
        "public": true
      },
      {
        "host": "localhost",
        "public": false
      },
      {
        "host": "air",
        "public": false
      },
      {
        "host": "printer.local",
        "public": false
      },
      {
        "host": "api.internal",
        "public": false
      },
      {
        "host": "router.home.arpa",
        "public": false
      },
      {
        "host": "home.arpa",
        "public": false
      },
      {
        "host": "box.tailnet.ts.net",
        "public": false
      },
      {
        "host": "AIR.TAILE8BEA7.TS.NET",
        "public": false
      },
      {
        "host": "::1",
        "public": false
      },
      {
        "host": "[::1]",
        "public": false
      },
      {
        "host": "fd00::1",
        "public": false
      },
      {
        "host": "fc00::1",
        "public": false
      },
      {
        "host": "fe80::1",
        "public": false
      },
      {
        "host": "FD12:3456::1",
        "public": false
      },
      {
        "host": "2606:4700:4700::1111",
        "public": true
      },
      {
        "host": "::ffff:192.168.1.10",
        "public": false
      },
      {
        "host": "::ffff:10.0.0.1",
        "public": false
      },
      {
        "host": "::ffff:100.126.17.15",
        "public": false
      },
      {
        "host": "[::ffff:192.168.1.10]",
        "public": false
      },
      {
        "host": "::ffff:c0a8:010a",
        "public": false
      },
      {
        "host": "::ffff:a00:1",
        "public": false
      },
      {
        "host": "::ffff:8.8.8.8",
        "public": true
      },
      {
        "host": "::ffff:808:808",
        "public": true
      },
      {
        "host": "localhost.",
        "public": false
      },
      {
        "host": "printer.local.",
        "public": false
      },
      {
        "host": "api.internal.",
        "public": false
      },
      {
        "host": "box.tailnet.ts.net.",
        "public": false
      },
      {
        "host": "air.",
        "public": false
      },
      {
        "host": "github.com.",
        "public": true
      },
      {
        "host": "app.localhost",
        "public": false
      },
      {
        "host": "api.app.localhost",
        "public": false
      },
      {
        "host": "APP.LOCALHOST",
        "public": false
      },
      {
        "host": "",
        "public": false
      },
      {
        "host": "10.0.0.999",
        "public": true
      },
      {
        "host": "10.0.0",
        "public": true
      },
      {
        "host": "corp.example.com",
        "public": false
      },
      {
        "host": "foo.intranet.org",
        "public": false
      },
      {
        "host": "example.com..",
        "public": false
      },
      {
        "host": "192.0.0.9",
        "public": false
      },
      {
        "host": "192.0.2.1",
        "public": false
      },
      {
        "host": "192.88.99.1",
        "public": false
      },
      {
        "host": "198.51.100.1",
        "public": false
      },
      {
        "host": "203.0.113.1",
        "public": false
      },
      {
        "host": "224.0.0.1",
        "public": false
      },
      {
        "host": "::ffff:8.8.8.8",
        "public": true
      },
      {
        "host": "64:ff9b::808:808",
        "public": true
      },
      {
        "host": "64:ff9b::a00:1",
        "public": false
      },
      {
        "host": "2001:1::1",
        "public": true
      },
      {
        "host": "2001:1::4",
        "public": false
      },
      {
        "host": "2001:3::1",
        "public": true
      },
      {
        "host": "2001:4:112::1",
        "public": true
      },
      {
        "host": "2001:20::1",
        "public": true
      },
      {
        "host": "2001:30::1",
        "public": true
      },
      {
        "host": "2001:db8::1",
        "public": false
      },
      {
        "host": "2002::1",
        "public": false
      },
      {
        "host": "3fff::1",
        "public": false
      },
      {
        "host": "3fff:1000::1",
        "public": true
      }
    ]
    """########

    // Captured from source e5909e53 hostClassification.ts and favicon.ts.
    private static let urls = ########"""
    [
      {
        "url": "https://example.com/a",
        "host": "example.com",
        "request": "https://www.google.com/s2/favicons?domain=example.com&sz=32"
      },
      {
        "url": "http://LOCALHOST:3000/a",
        "host": "localhost",
        "request": null
      },
      {
        "url": "http://127.1",
        "host": "127.0.0.1",
        "request": null
      },
      {
        "url": "http://2130706433",
        "host": "127.0.0.1",
        "request": null
      },
      {
        "url": "http://0x7f000001",
        "host": "127.0.0.1",
        "request": null
      },
      {
        "url": "http://0177.0.0.1",
        "host": "127.0.0.1",
        "request": null
      },
      {
        "url": "https://8.8.8.8",
        "host": "8.8.8.8",
        "request": "https://www.google.com/s2/favicons?domain=8.8.8.8&sz=32"
      },
      {
        "url": "https://[2606:4700:4700::1111]",
        "host": "[2606:4700:4700::1111]",
        "request": "https://www.google.com/s2/favicons?domain=%5B2606%3A4700%3A4700%3A%3A1111%5D&sz=32"
      },
      {
        "url": "https://github.com.",
        "host": "github.com.",
        "request": "https://www.google.com/s2/favicons?domain=github.com.&sz=32"
      },
      {
        "url": "https://api.internal.example.com",
        "host": "api.internal.example.com",
        "request": null
      },
      {
        "url": "https://bücher.de",
        "host": "xn--bcher-kva.de",
        "request": "https://www.google.com/s2/favicons?domain=xn--bcher-kva.de&sz=32"
      },
      {
        "url": "https://[0:0:0:0:0:ffff:8.8.8.8]",
        "host": "[::ffff:808:808]",
        "request": "https://www.google.com/s2/favicons?domain=%5B%3A%3Affff%3A808%3A808%5D&sz=32"
      },
      {
        "url": "https://[0:0:0:0:0:ffff:192.168.1.1]",
        "host": "[::ffff:c0a8:101]",
        "request": null
      },
      {
        "url": "https://[2001:0000:0000:1:0000:0000:1:1]",
        "host": "[2001::1:0:0:1:1]",
        "request": null
      }
    ]
    """########
}
