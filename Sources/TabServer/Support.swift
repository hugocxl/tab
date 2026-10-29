import Foundation
import TabCore
import TabProtocol

// MARK: - Errors

extension ServiceError {
    static func unknownSession(_ id: SessionId) -> ServiceError {
        ServiceError(.unknownSession, "Session \(id) does not exist")
    }

    static func unknownProject(_ id: ProjectId? = nil) -> ServiceError {
        ServiceError(.unknownProject, id.map { "Project \($0) does not exist" } ?? "The project no longer exists")
    }

    static func unknownChannel(_ channel: ChannelId) -> ServiceError {
        ServiceError(.unknownChannel, "Channel \(channel) is not attached")
    }

    static let unsupportedRequest = ServiceError(.unsupported, "This server doesn't support the request. Update Tab.")
}

/// The reply for any error a request handler throws.
func errorReply(_ error: Error) -> ErrorReply {
    switch error {
    case let error as ServiceError: ErrorReply(code: error.code, message: error.message)
    case let error as ErrorReply: error
    case let code as ErrorCode: ErrorReply(code: code, message: defaultMessage(code))
    default: ErrorReply(code: .badRequest, message: String(describing: error))
    }
}

private func defaultMessage(_ code: ErrorCode) -> String {
    switch code {
    case .badSize: "The terminal size is not valid"
    case .badPath: "The path is not valid"
    case .unknownProject: "The project no longer exists"
    case .unknownSession: "The session no longer exists"
    case .unknownChannel: "The terminal is no longer attached"
    case .unauthorized: "Not available to paired devices"
    case .unsupported: ServiceError.unsupportedRequest.message
    default: "Invalid request (\(code.rawValue))"
    }
}

// MARK: - Hashing

/// FNV-1a, stable across processes, for cursor tags.
struct StableHash {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
    }

    mutating func combine(_ number: UInt64) {
        withUnsafeBytes(of: number.littleEndian) { combine($0) }
    }

    mutating func combine(_ text: String) {
        combine(text.utf8)
        combine(UInt64(text.utf8.count))
    }

    mutating func combine(_ uuid: UUID) {
        withUnsafeBytes(of: uuid.uuid) { combine($0) }
    }
}

// MARK: - Time

enum Clock {
    /// Unix seconds.
    static func now() -> UInt64 { RelativeTime.unixNow() }

    /// Unix milliseconds.
    static func nowMilliseconds() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1000))
    }
}

// MARK: - Files

enum PrivateFolder {
    /// Creates `url` (and parents) owner-only, or checks that it is a folder.
    static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw ServiceError(.persistenceFailed, "\(url.path) is not a folder")
        }
    }
}

extension ServerPath {
    /// A local path from a server path the server checked.
    var url: URL { URL(fileURLWithPath: rawValue) }

    var isDirectory: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: rawValue, isDirectory: &directory) && directory.boolValue
    }
}
