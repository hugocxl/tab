@_exported import TabProtocol
import Foundation

// Shared ids (ProjectId, SessionId, ServerId, OperationId, ClientId, DeviceId,
// PaneId, TabId) and their parsing come from TabProtocol, re-exported here. The
// ids below exist only in apps.

extension ServerId {
    /// This computer's server, as the app lists it.
    public static let local = ServerId(uuid: UUID(uuid: (
        0x9E, 0xED, 0xD6, 0x33, 0x57, 0xB5, 0x43, 0x59,
        0xB7, 0x6E, 0x76, 0x2C, 0x6B, 0xC2, 0x77, 0x5C
    )))

    public var isLocal: Bool { self == .local }
}

/// A client-owned group of projects shown together in the sidebar.
public struct WorkspaceId: UUIDIdentifier, CodingKeyRepresentable {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}
