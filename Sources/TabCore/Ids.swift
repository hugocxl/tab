@_exported import TabProtocol
import Foundation

// Shared ids (ProjectId, SessionId, ServerId, OperationId, ClientId, DeviceId)
// come from TabProtocol, re-exported here. The ids below exist only in apps.

extension UUIDIdentifier {
    /// Parses a UUID with or without hyphens, in any case, as hand-edited
    /// settings and `uuidgen` output spell them.
    public init?(_ text: String) {
        guard let uuid = parseUUID(text) else { return nil }
        self.init(uuid: uuid)
    }

    /// For `CodingKeyRepresentable`: ids are JSON object keys.
    public var codingKey: CodingKey { IdentifierCodingKey(stringValue: description) }

    public init?<T: CodingKey>(codingKey: T) { self.init(codingKey.stringValue) }
}

extension ProjectId: CodingKeyRepresentable {}
extension SessionId: CodingKeyRepresentable {}
extension ServerId: CodingKeyRepresentable {}
extension OperationId: CodingKeyRepresentable {}

extension ServerId {
    /// This computer's server, as the app lists it.
    public static let local = ServerId(uuid: UUID(uuid: (
        0x9E, 0xED, 0xD6, 0x33, 0x57, 0xB5, 0x43, 0x59,
        0xB7, 0x6E, 0x76, 0x2C, 0x6B, 0xC2, 0x77, 0x5C
    )))

    public var isLocal: Bool { self == .local }
}

private struct IdentifierCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

func parseUUID(_ text: String) -> UUID? {
    if let uuid = UUID(uuidString: text) { return uuid }
    let hex = text.replacingOccurrences(of: "-", with: "")
    guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
    let characters = Array(hex)
    let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(characters[$0]) }
    return UUID(uuidString: groups.joined(separator: "-"))
}

/// A pane in a split layout.
public struct PaneId: UUIDIdentifier, CodingKeyRepresentable {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }

    /// The operation that creates this pane's terminal, so a cancelled
    /// creation can be named before the server answers.
    public var creationToken: OperationId { OperationId(uuid: uuid) }
}

/// A tab: one split layout of panes.
public struct TabId: UUIDIdentifier, CodingKeyRepresentable {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// A client-owned group of projects shown together in the sidebar.
public struct WorkspaceId: UUIDIdentifier, CodingKeyRepresentable {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}
