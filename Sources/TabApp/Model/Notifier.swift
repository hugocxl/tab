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
    private var delivery: ((AgentEvent, ServerId, String) -> Void)?
    private var clearing: (([UInt64], ServerId) -> Void)?

    /// Uses an in-memory notification sink without the macOS notification center.
    init(deliver: @escaping (AgentEvent, ServerId, String) -> Void, clear: @escaping ([UInt64], ServerId) -> Void) {
        delivery = deliver
        clearing = clear
        super.init()
    }

    public override init() {
        super.init()
    }

    /// Whether this process can show notifications.
    public var available: Bool { delivery != nil || center != nil && authorized }

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
        if let delivery { delivery(event, server, title); return }
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
        guard !ids.isEmpty else { return }
        if let clearing { clearing(ids, server); return }
        guard let center else { return }
        let identifiers = ids.map { Self.identifier(server, $0) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
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
