import Foundation

/// Why a request failed. Also the error type of validation.
public enum ErrorCode: OpenEnum, Error {
    case unknownProject
    case catalogChanged
    case unknownSession
    case unknownChannel
    case badSize
    case badPath
    case spawnFailed
    case badRequest
    case savedContentUnavailable
    case staleHistoryCursor
    case historyUnavailable
    case persistenceFailed
    case unauthorized
    /// The other side's build doesn't support this request or can't read its reply.
    case unsupported
    case unknown(String)

    public static let knownCases: [ErrorCode] = [
        .unknownProject, .catalogChanged, .unknownSession, .unknownChannel, .badSize, .badPath,
        .spawnFailed, .badRequest, .savedContentUnavailable, .staleHistoryCursor, .historyUnavailable,
        .persistenceFailed, .unauthorized, .unsupported,
    ]

    public var rawValue: String {
        switch self {
        case .unknownProject: "unknownProject"
        case .catalogChanged: "catalogChanged"
        case .unknownSession: "unknownSession"
        case .unknownChannel: "unknownChannel"
        case .badSize: "badSize"
        case .badPath: "badPath"
        case .spawnFailed: "spawnFailed"
        case .badRequest: "badRequest"
        case .savedContentUnavailable: "savedContentUnavailable"
        case .staleHistoryCursor: "staleHistoryCursor"
        case .historyUnavailable: "historyUnavailable"
        case .persistenceFailed: "persistenceFailed"
        case .unauthorized: "unauthorized"
        case .unsupported: "unsupported"
        case .unknown(let value): value
        }
    }
}

/// A failed request's reply.
public struct ErrorReply: Hashable, Codable, Sendable, Error {
    public var code: ErrorCode
    public var message: String

    public init(code: ErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

extension ErrorReply: LocalizedError {
    public var errorDescription: String? { message }
}
