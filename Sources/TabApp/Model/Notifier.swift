import AppKit
import TabCore
import TabProtocol
import UserNotifications

/// Delivers macOS notifications when an agent needs attention or finishes,
/// and opens the pane when one is clicked. Only a bundled app can use the
/// notification center; elsewhere nothing is delivered.
@MainActor
public final class Notifier: NSObject {
    weak var model: AppModel?
    private var center: UNUserNotificationCenter?
    private var authorized = false

    public override init() {
        super.init()
    }

    /// Whether this process can show notifications.
    public var available: Bool { center != nil && authorized }

    private static var canUseCenter: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func start() {
        guard center == nil, Self.canUseCenter else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        self.center = center
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    static func identifier(_ server: ServerId, _ id: UInt64) -> String {
        server.isLocal ? "\(id)" : "\(server):\(id)"
    }

    func deliver(_ event: AgentEvent, server: ServerId, title: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = event.kind.displayDescription
        content.sound = .default
        content.userInfo = ["server": server.description, "session": event.session.description]
        let request = UNNotificationRequest(identifier: Self.identifier(server, event.id), content: content, trigger: nil)
        center.add(request)
    }

    func clear(_ ids: [UInt64], server: ServerId) {
        guard let center, !ids.isEmpty else { return }
        let identifiers = ids.map { Self.identifier(server, $0) }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let server = (info["server"] as? String).flatMap { UUID(uuidString: $0) }.map { ServerId(uuid: $0) }
        let session = (info["session"] as? String).flatMap { UUID(uuidString: $0) }.map { SessionId(uuid: $0) }
        Task { @MainActor [weak self] in
            if let server, let session { self?.model?.openNotification(server: server, session: session) }
            completionHandler()
        }
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
