import Foundation

/// The SOCKS5 handshake a remote tab's browser speaks to `ServerProxy`
/// (RFC 1928, with RFC 1929 username and password): only CONNECT, only with
/// the proxy's credentials. Each parser reads from the front of a buffer
/// and says how many bytes it used, or that more must arrive.
enum SOCKS5 {
    enum Parse<Value: Equatable>: Equatable {
        case needMore
        /// The bytes break the protocol; reply with `reply` if any, then close.
        case invalid(reply: Data?)
        case done(Value, consumed: Int)
    }

    /// Where a CONNECT goes. Names stay names, so the server resolves them.
    struct Target: Equatable {
        var host: String
        var port: UInt16
    }

    enum Reply: UInt8 {
        case succeeded = 0
        case generalFailure = 1
        case notAllowed = 2
        case networkUnreachable = 3
        case hostUnreachable = 4
        case refused = 5
        case timedOut = 6
        case commandNotSupported = 7
        case addressNotSupported = 8
    }

    static let version: UInt8 = 5
    static let userPassword: UInt8 = 2
    static let noAcceptableMethod: UInt8 = 0xFF

    /// The greeting: whether the client offers username and password.
    static func greeting(_ data: Data) -> Parse<Bool> {
        let bytes = [UInt8](data.prefix(257))
        guard bytes.count >= 2 else { return .needMore }
        guard bytes[0] == version else { return .invalid(reply: nil) }
        let count = Int(bytes[1])
        guard count > 0 else { return .invalid(reply: Data([version, noAcceptableMethod])) }
        guard bytes.count >= 2 + count else { return .needMore }
        return .done(bytes[2 ..< 2 + count].contains(userPassword), consumed: 2 + count)
    }

    /// The username and password: whether they match.
    static func credentials(_ data: Data, username: String, password: String) -> Parse<Bool> {
        let bytes = [UInt8](data.prefix(513))
        guard bytes.count >= 2 else { return .needMore }
        guard bytes[0] == 1 else { return .invalid(reply: Data([1, 1])) }
        let userLength = Int(bytes[1])
        guard bytes.count >= 2 + userLength + 1 else { return .needMore }
        let passwordLength = Int(bytes[2 + userLength])
        let end = 3 + userLength + passwordLength
        guard bytes.count >= end else { return .needMore }
        let user = Data(bytes[2 ..< 2 + userLength])
        let pass = Data(bytes[3 + userLength ..< end])
        let matches = constantTimeEqual(user, Data(username.utf8)) && constantTimeEqual(pass, Data(password.utf8))
        return .done(matches, consumed: end)
    }

    /// The request: a CONNECT's target.
    static func request(_ data: Data) -> Parse<Target> {
        let bytes = [UInt8](data.prefix(262))
        guard bytes.count >= 5 else { return .needMore }
        guard bytes[0] == version, bytes[2] == 0 else { return .invalid(reply: nil) }
        guard bytes[1] == 1 else { return .invalid(reply: reply(.commandNotSupported)) }
        let host: String
        let start: Int
        switch bytes[3] {
        case 1:
            guard bytes.count >= 10 else { return .needMore }
            host = bytes[4 ..< 8].map(String.init).joined(separator: ".")
            start = 8
        case 3:
            let length = Int(bytes[4])
            guard length > 0 else { return .invalid(reply: reply(.addressNotSupported)) }
            guard bytes.count >= 5 + length + 2 else { return .needMore }
            guard let name = String(bytes: bytes[5 ..< 5 + length], encoding: .utf8),
                  !name.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F }) else {
                return .invalid(reply: reply(.addressNotSupported))
            }
            host = name
            start = 5 + length
        case 4:
            guard bytes.count >= 22 else { return .needMore }
            var address = in6_addr()
            withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes[4 ..< 20]) }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else {
                return .invalid(reply: reply(.addressNotSupported))
            }
            host = String(cString: text)
            start = 20
        default:
            return .invalid(reply: reply(.addressNotSupported))
        }
        let port = UInt16(bytes[start]) << 8 | UInt16(bytes[start + 1])
        guard port > 0 else { return .invalid(reply: reply(.notAllowed)) }
        return .done(Target(host: host, port: port), consumed: start + 2)
    }

    /// A reply with an empty IPv4 bound address, which browsers ignore.
    static func reply(_ code: Reply) -> Data {
        Data([version, code.rawValue, 0, 1, 0, 0, 0, 0, 0, 0])
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
