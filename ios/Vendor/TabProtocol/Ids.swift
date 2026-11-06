import Foundation

/// An identifier backed by a UUID, encoded as its lowercase string.
public protocol UUIDIdentifier: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    var uuid: UUID { get }
    init(uuid: UUID)
}

extension UUIDIdentifier {
    /// A new random identifier.
    public init() { self.init(uuid: UUID()) }

    /// Parses a UUID string in either case; `nil` when it isn't one.
    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.init(uuid: uuid)
    }

    public var description: String { uuid.uuidString.lowercased() }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let uuid = UUID(uuidString: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a UUID: \(text)")
        }
        self.init(uuid: uuid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A project on one server.
public struct ProjectId: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// A terminal session on one server.
public struct SessionId: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// A server's identity, stable across restarts of the same profile.
public struct ServerId: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// One client process (an app, a CLI run, a phone).
public struct ClientId: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// An idempotency key for a mutation a client may retry, or an upload.
public struct OperationId: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// A paired phone.
public struct DeviceId: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// Matches a reply to its request on the control channel.
public struct RequestId: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ value: UInt32) { self.rawValue = value }
    public var description: String { String(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A frame channel: 0 is control, every other one an attached session.
public struct ChannelId: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ value: UInt32) { self.rawValue = value }
    public var description: String { String(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The control channel, which carries `Message`s.
    public static let control = ChannelId(0)
    public var isControl: Bool { rawValue == 0 }
}

/// A position in a session's history, counted in rows from the oldest kept row.
public struct HistoryCursor: RawRepresentable, Hashable, Comparable, Codable, Sendable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public init(_ value: UInt64) { self.rawValue = value }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
