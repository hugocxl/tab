import Darwin
import Foundation
import TabCore

/// ssh's `ProxyCommand` while the proxy applies to the whole app: ssh runs
/// the app's own executable with `ProxyTunnel.argument`, the host and the
/// port; it reads the proxy from its environment, connects through it (or
/// straight there when the proxy bypasses the host), and relays ssh's bytes.
public enum ProxyTunnel {
    /// The app runs as ssh's proxy command when this is its first argument.
    public static let argument = "--tab-proxy-tunnel"
    /// Which proxy the tunnel uses. It is only in the environment of the
    /// app's own ssh runs.
    static let settingsVariable = "TAB_PROXY"
    /// Covers connecting to the proxy and its handshake.
    static let timeout: TimeInterval = 10
    /// The longest proxy reply header accepted.
    static let maxReply = 16 * 1024

    /// Runs the tunnel when this process was started as one, and returns its
    /// exit status; `nil` otherwise. Call it first thing in `main`.
    public static func runIfRequested(arguments: [String] = CommandLine.arguments,
                                      environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32? {
        guard arguments.count > 1, arguments[1] == argument else { return nil }
        do {
            guard arguments.count >= 4 else { throw TunnelError("missing host or port") }
            guard let port = UInt16(arguments[3]) else { throw TunnelError("invalid port") }
            guard let json = environment[settingsVariable],
                  let proxy = try? JSONDecoder().decode(ProxySettings.self, from: Data(json.utf8))
            else { throw TunnelError("missing proxy") }
            let socket = try connect(proxy, host: arguments[2], port: port)
            relay(socket)
            return 0
        } catch {
            FileHandle.standardError.write(Data("Tab proxy: \(error)\n".utf8))
            return 1
        }
    }

    /// A connected socket to `host:port` through `proxy`, or straight there
    /// when `proxy` bypasses it, ready for the caller's bytes.
    static func connect(_ proxy: ProxySettings, host: String, port: UInt16) throws -> Int32 {
        try proxy.validate()
        guard port > 0, !host.isEmpty,
              !host.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control })
        else { throw TunnelError("invalid destination") }
        if proxy.bypasses(host) { return try open(host, port) }
        let socket = try open(proxy.host, UInt16(clamping: proxy.port))
        do {
            setTimeout(socket, timeout)
            switch proxy.kind {
            case .http: try httpConnect(socket, proxy: proxy, host: host, port: port)
            case .socks5: try socks5Connect(socket, proxy: proxy, host: host, port: port)
            }
            setTimeout(socket, 0)
            return socket
        } catch {
            close(socket)
            throw error
        }
    }

    // MARK: Sockets

    private static func open(_ host: String, _ port: UInt16) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        guard status == 0, let first = list else {
            throw TunnelError("could not reach \(host):\(port): \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(list) }
        var last = "\(host) has no address"
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            cursor = info.pointee.ai_next
            let socket = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard socket >= 0 else { continue }
            var noSigpipe: Int32 = 1
            setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            if connectWithTimeout(socket, info.pointee.ai_addr, info.pointee.ai_addrlen) {
                return socket
            }
            last = String(cString: strerror(errno))
            close(socket)
        }
        throw TunnelError("could not reach \(host):\(port): \(last)")
    }

    private static func connectWithTimeout(_ socket: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ length: socklen_t) -> Bool {
        let flags = fcntl(socket, F_GETFL)
        _ = fcntl(socket, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(socket, F_SETFL, flags) }
        if Darwin.connect(socket, address, length) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var descriptor = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) == 1 else {
            errno = ETIMEDOUT
            return false
        }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &size)
        errno = error
        return error == 0
    }

    private static func setTimeout(_ socket: Int32, _ seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &value, size)
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &value, size)
    }

    private static func writeAll(_ socket: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw TunnelError("the proxy closed the connection: \(String(cString: strerror(errno)))") }
            offset += written
        }
    }

    private static func readExact(_ socket: Int32, _ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let got = bytes[offset...].withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
            if got < 0 && errno == EINTR { continue }
            guard got > 0 else { throw TunnelError("the proxy closed the connection") }
            offset += got
        }
        return bytes
    }

    // MARK: Handshakes

    private static func httpConnect(_ socket: Int32, proxy: ProxySettings, host: String, port: UInt16) throws {
        let authority = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n"
        if !proxy.username.isEmpty {
            let credentials = Data("\(proxy.username):\(proxy.password)".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(credentials)\r\n"
        }
        request += "\r\n"
        try writeAll(socket, Array(request.utf8))
        var reply: [UInt8] = []
        let end: [UInt8] = [13, 10, 13, 10]
        while !reply.ends(with: end) {
            guard reply.count < maxReply else { throw TunnelError("the proxy's reply is too long") }
            reply += try readExact(socket, 1)
        }
        let status = String(decoding: reply, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let code = status.split(separator: " ").dropFirst().first ?? ""
        guard status.hasPrefix("HTTP/1."), code.count == 3, code.hasPrefix("2") else {
            throw TunnelError("the proxy refused \(authority): \(status)")
        }
    }

    private static func socks5Connect(_ socket: Int32, proxy: ProxySettings, host: String, port: UInt16) throws {
        let login = !proxy.username.isEmpty
        try writeAll(socket, login ? [5, 2, 0, 2] : [5, 1, 0])
        let choice = try readExact(socket, 2)
        guard choice[0] == 5 else { throw TunnelError("the proxy doesn't speak SOCKS5") }
        switch choice[1] {
        case 0:
            break
        case 2 where login:
            let user = Array(proxy.username.utf8)
            let password = Array(proxy.password.utf8)
            guard user.count <= 255, password.count <= 255 else {
                throw TunnelError("the proxy user name or password is too long")
            }
            try writeAll(socket, [1, UInt8(user.count)] + user + [UInt8(password.count)] + password)
            let authentication = try readExact(socket, 2)
            guard authentication[0] == 1, authentication[1] == 0 else {
                throw TunnelError("the proxy refused the user name or password")
            }
        default:
            throw TunnelError("the proxy needs a login it wasn't given")
        }
        var request: [UInt8] = [5, 1, 0]
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            request.append(1)
            request += withUnsafeBytes(of: &v4) { Array($0) }
        } else if inet_pton(AF_INET6, host, &v6) == 1 {
            request.append(4)
            request += withUnsafeBytes(of: &v6) { Array($0) }
        } else {
            let name = Array(host.utf8)
            guard name.count <= 255 else { throw TunnelError("the host name is too long") }
            request += [3, UInt8(name.count)] + name
        }
        request += [UInt8(port >> 8), UInt8(port & 0xFF)]
        try writeAll(socket, request)
        let reply = try readExact(socket, 4)
        guard reply[0] == 5, reply[2] == 0 else { throw TunnelError("the proxy doesn't speak SOCKS5") }
        guard reply[1] == 0 else {
            throw TunnelError("the proxy refused \(host):\(port): \(socks5Failure(reply[1]))")
        }
        let length: Int
        switch reply[3] {
        case 1: length = 4
        case 4: length = 16
        case 3: length = Int(try readExact(socket, 1)[0])
        default: throw TunnelError("the proxy sent an unknown address type")
        }
        _ = try readExact(socket, length + 2)
    }

    private static func socks5Failure(_ code: UInt8) -> String {
        switch code {
        case 2: return "not allowed by its rules"
        case 3: return "network unreachable"
        case 4: return "host unreachable"
        case 5: return "connection refused"
        case 6: return "timed out"
        default: return "connection failed"
        }
    }

    // MARK: Relay

    /// Copies standard input to `socket` and `socket` to standard output
    /// until the other computer closes the connection.
    private static func relay(_ socket: Int32) {
        let upstream = Thread {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let got = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if got < 0 && errno == EINTR { continue }
                guard got > 0, (try? writeAll(socket, Array(buffer[0..<got]))) != nil else { break }
            }
            shutdown(socket, SHUT_WR)
        }
        upstream.start()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let got = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
            if got < 0 && errno == EINTR { continue }
            guard got > 0, (try? writeAll(STDOUT_FILENO, Array(buffer[0..<got]))) != nil else { return }
        }
    }
}

struct TunnelError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private extension Array where Element == UInt8 {
    func ends(with suffix: [UInt8]) -> Bool {
        count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix
    }
}
