import Foundation
import Network

/// Why an automatic background download is paused until the network changes.
public enum UpdateDownloadHold: Equatable, Sendable {
    case lowDataMode
    case hotspot
}

/// What the updater needs to know about the current network path.
public struct UpdateNetworkState: Equatable, Sendable {
    public var isOnline: Bool
    public var hold: UpdateDownloadHold?

    public init(isOnline: Bool = true, hold: UpdateDownloadHold? = nil) {
        self.isOnline = isOnline
        self.hold = hold
    }

    public static let unconstrained = UpdateNetworkState(isOnline: true, hold: nil)
}

/// Follows macOS network path changes so background update downloads pause on
/// Low Data Mode or hotspots and resume automatically once unconstrained.
@MainActor
final class UpdateNetworkMonitor {
    private let queue = DispatchQueue(label: "com.hugocorta.tab.update-network")
    private var monitor: NWPathMonitor?
    private let onChange: @MainActor (UpdateNetworkState) -> Void

    init(onChange: @escaping @MainActor (UpdateNetworkState) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let state = Self.state(from: path)
            Task { @MainActor [weak self] in
                self?.onChange(state)
            }
        }
        self.monitor = monitor
        monitor.start(queue: queue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    nonisolated static func state(from path: NWPath) -> UpdateNetworkState {
        let online = path.status == .satisfied
        let hold: UpdateDownloadHold?
        if path.isConstrained {
            hold = .lowDataMode
        } else if path.isExpensive {
            hold = .hotspot
        } else {
            hold = nil
        }
        return UpdateNetworkState(isOnline: online, hold: hold)
    }
}
