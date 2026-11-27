import Foundation

// A tunnel is a TCP connection the server makes for a client, such as a
// browser page loading `localhost:3000` from a remote tab. Its bytes travel
// as `stream` frames on its own channel, both ways, under credit: each side
// starts with `Limits.tunnelWindow` bytes it may send, and the reader grants
// more with a `credit` message as it writes bytes to its socket. Either side
// ends its direction with `streamEnd`; the server frees the channel with
// `streamClosed` once both directions ended or the connection failed, and
// the client frees it at once with `closeTunnel`.

/// Why a tunnel didn't open or stopped.
public enum TunnelFailure: OpenEnum, Error {
    /// Nothing listens on the port.
    case refused
    /// The host or its network can't be reached.
    case unreachable
    /// The name doesn't resolve on the server.
    case nameNotFound
    case timedOut
    /// The connection has as many tunnels as it may.
    case tooMany
    /// The connection reset or failed after opening.
    case failed
    case unknown(String)

    public static let knownCases: [TunnelFailure] = [.refused, .unreachable, .nameNotFound, .timedOut, .tooMany, .failed]

    public var rawValue: String {
        switch self {
        case .refused: "refused"
        case .unreachable: "unreachable"
        case .nameNotFound: "nameNotFound"
        case .timedOut: "timedOut"
        case .tooMany: "tooMany"
        case .failed: "failed"
        case .unknown(let value): value
        }
    }

    /// A sentence for people.
    public var message: String {
        switch self {
        case .refused: "Nothing is listening on that port"
        case .unreachable: "The host can't be reached"
        case .nameNotFound: "The name doesn't resolve"
        case .timedOut: "Connecting timed out"
        case .tooMany: "Too many open connections"
        case .failed, .unknown: "The connection failed"
        }
    }
}

extension Validation {
    /// A host name or address a tunnel connects to.
    static func tunnelHost(_ host: String) throws(ErrorCode) {
        if host.isEmpty || host.utf8.count > Limits.maxTunnelHost || hasNul(host) { throw .badRequest }
        if host.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0 == " " }) {
            throw .badRequest
        }
    }
}
