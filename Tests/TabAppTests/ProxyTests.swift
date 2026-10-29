import Darwin
import Foundation
import TabClient
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class ProxyTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func proxy(_ kind: ProxyKind = .http, port: Int = 8080, global: Bool = true) -> ProxySettings {
        ProxySettings(kind: kind, host: "127.0.0.1", port: port, username: "me", password: "secret",
                      bypass: "localhost, .corp.example", global: global)
    }

    func testFormExplainsWhatToFix() {
        func message(host: String = "proxy.local", port: String = "3128", user: String = "", password: String = "") -> String? {
            switch ProxyForm.settings(kind: .http, host: host, port: port, username: user, password: password, bypass: "", global: false) {
            case .success: return nil
            case .failure(let error): return error.message
            }
        }
        XCTAssertEqual(message(host: "http://proxy.local"), "Enter the proxy's host name or address, without http://")
        XCTAssertEqual(message(port: "http"), "Enter a port from 1 to 65535")
        XCTAssertEqual(message(port: "70000"), "Enter a port from 1 to 65535")
        XCTAssertEqual(message(password: "pw"), "Enter the user name for this password")
        guard case .success(let settings) = ProxyForm.settings(kind: .socks5, host: " proxy.local ", port: " 1080 ",
                                                               username: "me", password: " keep spaces ", bypass: " a, b ", global: true)
        else { return XCTFail("valid form refused") }
        XCTAssertEqual(settings, ProxySettings(kind: .socks5, host: "proxy.local", port: 1080, username: "me",
                                               password: " keep spaces ", bypass: "a, b", global: true))
    }

    func testSavedProxyIsPrivateAndRemovable() throws {
        let file = folder.appendingPathComponent("proxy.json")
        let model = ProxyModel(file: file)
        XCTAssertNil(model.settings)
        try model.save(proxy())
        var info = stat()
        XCTAssertEqual(stat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(ProxyModel(file: file).settings, proxy())
        try model.save(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(ProxyModel(file: file).settings)
    }

    func testUnreadableFileReportsWithoutQuotingIt() throws {
        let file = folder.appendingPathComponent("proxy.json")
        try Data(#"{"host":"x","password":"hunter2","port":"#.utf8).write(to: file)
        let model = ProxyModel(file: file)
        XCTAssertNil(model.settings)
        let error = try XCTUnwrap(model.loadError)
        XCTAssertFalse(error.contains("hunter2"))
    }

    func testNewTerminalsFollowTheWholeAppChoiceUnlessThePaneChose() throws {
        let model = ProxyModel(file: folder.appendingPathComponent("proxy.json"))
        let pane = PaneId()
        XCTAssertFalse(model.creationEnvironment(for: pane, localServer: true, serverSupportsEnvironment: true).proxied)
        try model.save(proxy(global: true))
        let local = model.creationEnvironment(for: pane, localServer: true, serverSupportsEnvironment: true)
        XCTAssertTrue(local.proxied)
        XCTAssertEqual(local.environment["https_proxy"], "http://me:secret@127.0.0.1:8080")
        XCTAssertEqual(local.environment["no_proxy"], "localhost,.corp.example")
        XCTAssertFalse(model.creationEnvironment(for: pane, localServer: false, serverSupportsEnvironment: true).proxied)
        XCTAssertFalse(model.creationEnvironment(for: pane, localServer: true, serverSupportsEnvironment: false).proxied)
        model.choose(pane, proxy: false)
        XCTAssertFalse(model.creationEnvironment(for: pane, localServer: true, serverSupportsEnvironment: true).proxied)
        try model.save(proxy(global: false))
        model.choose(pane, proxy: true)
        XCTAssertTrue(model.creationEnvironment(for: pane, localServer: false, serverSupportsEnvironment: true).proxied)
        model.forget(pane)
        XCTAssertFalse(model.creationEnvironment(for: pane, localServer: true, serverSupportsEnvironment: true).proxied)
    }

    func testTerminalMenuOffersSetUpApplyOrRemove() throws {
        let model = ProxyModel(file: folder.appendingPathComponent("proxy.json"))
        XCTAssertEqual(model.menuItem(paneUsesProxy: false, canRestart: true, serverSupportsEnvironment: true), .setUp)
        try model.save(proxy(global: false))
        XCTAssertEqual(model.menuItem(paneUsesProxy: false, canRestart: true, serverSupportsEnvironment: true), .apply(enabled: true))
        XCTAssertEqual(model.menuItem(paneUsesProxy: false, canRestart: true, serverSupportsEnvironment: false), .apply(enabled: false))
        XCTAssertEqual(model.menuItem(paneUsesProxy: true, canRestart: false, serverSupportsEnvironment: true), .remove(enabled: false))
        try model.save(nil)
        XCTAssertEqual(model.menuItem(paneUsesProxy: true, canRestart: true, serverSupportsEnvironment: true).title, "Remove Proxy")
    }

    func testSSHAndDownloadsUseOnlyAWholeAppProxy() throws {
        XCTAssertNil(try ProxyEnvironment.sshCommand(proxy(global: false), program: "/Applications/Tab.app/Contents/MacOS/Tab"))
        XCTAssertNil(try ProxyEnvironment.sshCommand(nil, program: "/x"))
        let command = try XCTUnwrap(try ProxyEnvironment.sshCommand(proxy(), program: "/Applications/Tab.app/Contents/MacOS/Tab"))
        XCTAssertEqual(command.arguments, [ProxyTunnel.argument])
        let json = try XCTUnwrap(command.environment[ProxyTunnel.settingsVariable])
        XCTAssertEqual(try JSONDecoder().decode(ProxySettings.self, from: Data(json.utf8)), proxy())

        XCTAssertTrue(ProxyEnvironment.sessionConfiguration(proxy(global: false)).proxyConfigurations.isEmpty)
        XCTAssertEqual(ProxyEnvironment.sessionConfiguration(proxy()).proxyConfigurations.count, 1)
        XCTAssertEqual(ProxyEnvironment.excludedDomain(".corp.example"), "corp.example")
        XCTAssertNil(ProxyEnvironment.excludedDomain("10.0.0.0/8"))
        XCTAssertNil(ProxyEnvironment.excludedDomain("*"))
    }
}

/// The tunnel ssh runs through the proxy, against fake proxies on loopback.
final class ProxyTunnelTests: XCTestCase {
    private let banner = Array("SSH-2.0-test\r\n".utf8)

    private func settings(_ kind: ProxyKind, port: UInt16) -> ProxySettings {
        ProxySettings(kind: kind, host: "127.0.0.1", port: Int(port), username: "me", password: "secret")
    }

    func testHTTPProxiesTunnelWithBasicAuthAndKeepTheFirstBytes() throws {
        let server = try FakeServer { socket in
            let request = try FakeServer.readHeader(socket)
            try FakeServer.write(socket, Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8) + self.banner)
            return request
        }
        let socket = try ProxyTunnel.connect(settings(.http, port: server.port), host: "box.example", port: 22)
        XCTAssertEqual(try FakeServer.read(socket, banner.count), banner)
        try FakeServer.write(socket, Array("ping".utf8))
        XCTAssertEqual(try FakeServer.read(socket, 4), Array("ping".utf8))
        close(socket)
        let request = String(decoding: try server.result(), as: UTF8.self)
        XCTAssertTrue(request.hasPrefix("CONNECT box.example:22 HTTP/1.1\r\n"))
        XCTAssertTrue(request.contains("\r\nProxy-Authorization: Basic bWU6c2VjcmV0\r\n"))
    }

    func testHTTPProxyRefusalsExplainThemselves() throws {
        let server = try FakeServer { socket in
            let request = try FakeServer.readHeader(socket)
            try FakeServer.write(socket, Array("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n".utf8))
            return request
        }
        XCTAssertThrowsError(try ProxyTunnel.connect(settings(.http, port: server.port), host: "::1", port: 22)) { error in
            XCTAssertTrue("\(error)".contains("407"), "\(error)")
        }
        XCTAssertTrue(String(decoding: try server.result(), as: UTF8.self).hasPrefix("CONNECT [::1]:22 HTTP/1.1\r\n"))
    }

    func testSOCKS5ProxiesLogInAndConnectByName() throws {
        let server = try FakeServer { socket in
            var seen = try FakeServer.read(socket, 4)
            try FakeServer.write(socket, [5, 2])
            seen += try FakeServer.read(socket, 2 + 2 + 1 + 6)
            try FakeServer.write(socket, [1, 0])
            seen += try FakeServer.read(socket, 5)
            seen += try FakeServer.read(socket, Int(seen[seen.count - 1]) + 2)
            try FakeServer.write(socket, [5, 0, 0, 3, 3] + Array("box".utf8) + [0, 22] + self.banner)
            return seen
        }
        let socket = try ProxyTunnel.connect(settings(.socks5, port: server.port), host: "box.example", port: 2222)
        XCTAssertEqual(try FakeServer.read(socket, banner.count), banner)
        close(socket)
        var expected: [UInt8] = [5, 2, 0, 2, 1, 2] + Array("me".utf8) + [6] + Array("secret".utf8)
        expected += [5, 1, 0, 3, 11] + Array("box.example".utf8) + [0x08, 0xAE]
        XCTAssertEqual(try server.result(), expected)
    }

    func testBypassedHostsAreReachedDirectly() throws {
        let server = try FakeServer { socket in
            try FakeServer.write(socket, self.banner)
            return []
        }
        var proxy = settings(.http, port: 1)
        proxy.bypass = "127.0.0.1"
        let socket = try ProxyTunnel.connect(proxy, host: "127.0.0.1", port: server.port)
        XCTAssertEqual(try FakeServer.read(socket, banner.count), banner)
        close(socket)
        _ = try server.result()
    }
}

/// A loopback server that answers one connection with `serve`, then echoes.
private final class FakeServer: @unchecked Sendable {
    let port: UInt16
    private let done = DispatchSemaphore(value: 0)
    private var outcome: Result<[UInt8], Error> = .success([])

    init(serve: @escaping @Sendable (Int32) throws -> [UInt8]) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw TunnelError("listen failed") }
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        Thread { [self] in
            let client = accept(listener, nil, nil)
            defer {
                close(client)
                close(listener)
                done.signal()
            }
            do {
                outcome = .success(try serve(client))
                var buffer = [UInt8](repeating: 0, count: 64)
                while true {
                    let got = Darwin.read(client, &buffer, buffer.count)
                    guard got > 0 else { break }
                    try Self.write(client, Array(buffer[0..<got]))
                }
            } catch {
                outcome = .failure(error)
            }
        }.start()
    }

    func result() throws -> [UInt8] {
        _ = done.wait(timeout: .now() + 10)
        return try outcome.get()
    }

    static func read(_ socket: Int32, _ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let got = bytes[offset...].withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) }
            guard got > 0 else { throw TunnelError("closed") }
            offset += got
        }
        return bytes
    }

    static func readHeader(_ socket: Int32) throws -> [UInt8] {
        var bytes: [UInt8] = []
        while !(bytes.count >= 4 && Array(bytes.suffix(4)) == [13, 10, 13, 10]) {
            bytes += try read(socket, 1)
        }
        return bytes
    }

    static func write(_ socket: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
            guard written > 0 else { throw TunnelError("closed") }
            offset += written
        }
    }
}
