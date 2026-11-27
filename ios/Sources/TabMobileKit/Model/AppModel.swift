import Foundation
import Observation
import TabProtocol
import TabShared

/// Every paired Mac, and pairing new ones.
@MainActor
@Observable
public final class AppModel {
    public private(set) var servers: [ServerModel] = []

    @ObservationIgnored private let store: PairedServerStore
    @ObservationIgnored public let clientId: ClientId
    @ObservationIgnored private var active = false

    public init(store: PairedServerStore = PairedServerStore(), defaults: UserDefaults = .standard) {
        self.store = store
        clientId = Self.clientId(defaults)
        servers = store.load().sorted { $0.pairedAt < $1.pairedAt }
            .map { ServerModel(server: $0, store: store, clientId: clientId) }
    }

    /// One id for this installation, so the server recognizes reconnects.
    private static func clientId(_ defaults: UserDefaults) -> ClientId {
        let key = "clientId"
        if let value = defaults.string(forKey: key), let uuid = UUID(uuidString: value) { return ClientId(uuid: uuid) }
        let id = ClientId()
        defaults.set(id.uuid.uuidString, forKey: key)
        return id
    }

    public func server(_ id: ServerId) -> ServerModel? { servers.first { $0.id == id } }

    /// The app came to the foreground: connect everything.
    public func resume() {
        active = true
        for server in servers { server.start() }
    }

    /// The app went to the background: let go of connections iOS would cut anyway.
    public func suspend() {
        active = false
        for server in servers { server.suspend() }
    }

    /// The network changed; don't wait out a backoff.
    public func networkChanged() {
        for server in servers { server.retryNow() }
    }

    /// Pairs with the Mac a `tab://pair` link names.
    @discardableResult
    public func pair(link: String, deviceName: String) async throws -> ServerModel {
        let invite: PairingInvite
        do {
            invite = try PairingInvite(link: link.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw ConnectError.failed("That isn't a Tab pairing code.")
        }
        let (server, token, client) = try await Connector.pair(invite, deviceName: deviceName, clientId: clientId)
        // Pairing ends this connection's admission; the model connects afresh.
        client.close()
        try store.save(server, token: token)
        if let existing = servers.firstIndex(where: { $0.id == server.id }) {
            servers[existing].suspend()
            servers.remove(at: existing)
        }
        let model = ServerModel(server: server, store: store, clientId: clientId)
        servers.append(model)
        if active { model.start() }
        return model
    }

    public func forget(_ id: ServerId) {
        server(id)?.suspend()
        server(id)?.forgetCache()
        servers.removeAll { $0.id == id }
        store.remove(id)
    }
}
