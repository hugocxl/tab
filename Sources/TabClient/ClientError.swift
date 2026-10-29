import Foundation
import TabProtocol

/// Why a request or a connection failed.
public enum ClientError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The connection closed, or was never open.
    case disconnected
    /// The server didn't answer in time.
    case timeout
    /// The server shares no protocol version with this build; it speaks `server`.
    case versionUnsupported(server: [ProtocolVersion])
    /// The server, or this build, can't do what was asked.
    case unsupported(String)
    /// The other side broke the protocol, so the connection closed.
    case protocolViolation(String)
    /// The server refused the request.
    case server(ErrorReply)
    /// The server answered with a reply that doesn't fit the request.
    case unexpectedReply(String)
    /// The request failed validation before it was sent.
    case invalid(ErrorCode)
    /// A system call or the transport failed.
    case transport(String)
    /// A server on another computer couldn't be reached.
    case remote(RemoteFailure)

    public var description: String {
        switch self {
        case .disconnected: "disconnected from the server"
        case .timeout: "the server didn't answer in time"
        case .versionUnsupported:
            "This Tab and the running server can't talk to each other. Restarting the server will end its terminals."
        case .unsupported(let message): message
        case .protocolViolation(let message): "protocol violation: \(message)"
        case .server(let error): error.message.isEmpty ? error.code.rawValue : error.message
        case .unexpectedReply(let type): "unexpected reply: \(type)"
        case .invalid(let code): "invalid request: \(code.rawValue)"
        case .transport(let message): "connection failed: \(message)"
        case .remote(let failure): failure.description
        }
    }

    /// Whether connecting again may work without the user's help. A refused
    /// login, an untrusted host key, or a missing or incompatible Tab on the
    /// other computer can't recover by itself, and repeated failed logins can
    /// get this computer blocked.
    public var recoverable: Bool {
        switch self {
        case .remote(let failure): failure.reason.recoverable
        case .versionUnsupported: false
        default: true
        }
    }

    /// The server's error code, if the server refused the request.
    public var serverCode: ErrorCode? {
        if case .server(let reply) = self { return reply.code }
        return nil
    }

    init(_ error: Error) {
        switch error {
        case let error as ClientError: self = error
        case let error as ErrorReply: self = .server(error)
        case let error as ErrorCode: self = .invalid(error)
        case TransportError.closed: self = .disconnected
        case let error as TransportError: self = .transport(error.description)
        case let error as FramingError: self = .protocolViolation(error.description)
        case is DecodingError: self = .protocolViolation("malformed message")
        default: self = .transport(String(describing: error))
        }
    }
}

extension ClientError: LocalizedError {
    public var errorDescription: String? { description }
}

/// A server on another computer that couldn't be reached, and why.
public struct RemoteFailure: Hashable, Sendable, CustomStringConvertible {
    public var reason: RemoteReason
    /// The other computer as the user named it, such as an SSH destination.
    public var destination: String
    /// What the transport reported, such as ssh's last line of errors.
    public var detail: String

    public init(reason: RemoteReason, destination: String, detail: String) {
        self.reason = reason
        self.destination = destination
        self.detail = detail
    }

    public var description: String {
        let destination = destination
        switch reason {
        case .hostKeyUnknown:
            return "\(destination) isn't a trusted SSH host yet. Run ssh \(destination) once to check and trust its key."
        case .hostKeyChanged:
            return "The SSH host key for \(destination) changed. If you expect that, run ssh \(destination) and follow its steps to update known_hosts."
        case .authenticationFailed:
            return "SSH refused the login to \(destination). Use ssh-agent, a key in ~/.ssh/config, a certificate, or password login."
        case .unreachable:
            return "Can't reach \(destination): \(detail)"
        case .notInstalled:
            return "Tab isn't installed on \(destination) (looked on PATH and in ~/.local/bin)."
        case .notRunning:
            return "Tab's server isn't running on \(destination)."
        case .sshMissing:
            return "Tab needs \(detail) to reach \(destination), but it isn't installed."
        case .unexpectedOutput where detail.isEmpty:
            return "The shell on \(destination) printed output before Tab could start. Keep its startup files quiet when it isn't interactive."
        case .unexpectedOutput:
            return "The shell on \(destination) printed \"\(detail)\" before Tab could start. Keep its startup files quiet when it isn't interactive."
        case .bridgeFailed:
            return "Tab on \(destination) failed: \(detail)"
        case .timeout where detail.isEmpty:
            return "Timed out connecting to \(destination)."
        case .timeout:
            return "Timed out connecting to \(destination): \(detail)"
        case .incompatible:
            return "Tab on \(destination) can't accept connections from this version of Tab (\(detail)). Install the same version on both computers."
        case .passwordNeeded:
            return "\(destination) needs a password to log in."
        }
    }
}

/// Why a server on another computer couldn't be reached, so apps can offer
/// the right fix.
public enum RemoteReason: String, Hashable, Sendable, CaseIterable {
    /// SSH has no trusted key for the host yet.
    case hostKeyUnknown
    /// The host's key differs from the one SSH trusted before.
    case hostKeyChanged
    /// SSH refused every key, agent, certificate and password it tried.
    case authenticationFailed
    /// The host can't be resolved or reached.
    case unreachable
    /// The remote shell can't find `tab`.
    case notInstalled
    /// No server runs there, and this connection must not start one.
    case notRunning
    /// This computer can't run ssh, or the custom command's program.
    case sshMissing
    /// The remote shell printed output instead of starting the bridge.
    case unexpectedOutput
    /// The bridge on the other computer reported an error.
    case bridgeFailed
    /// The bridge didn't answer in time.
    case timeout
    /// The other computer runs a Tab whose bridge or server this build can't use.
    case incompatible
    /// Password login is set up, but no password was typed this session.
    case passwordNeeded

    /// Whether connecting again may work without the user's help: the
    /// network or the other computer can recover, a login or host key can't.
    public var recoverable: Bool {
        switch self {
        case .unreachable, .timeout, .bridgeFailed: true
        default: false
        }
    }
}
