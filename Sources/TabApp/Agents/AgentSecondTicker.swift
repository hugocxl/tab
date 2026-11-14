import Foundation

/// One clock for every live elapsed time in agent panes: the working line and the
/// running-agents panel. It ticks once a second, only while a view on screen
/// subscribes, so idle panes cost nothing and many rows share one timer.
@MainActor
final class AgentSecondTicker {
    static let shared = AgentSecondTicker()

    private final class Subscriber {
        weak var owner: AnyObject?
        let tick: () -> Void
        init(owner: AnyObject, tick: @escaping () -> Void) { self.owner = owner; self.tick = tick }
    }

    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    private var timer: Timer?

    var isRunning: Bool { timer != nil }

    /// Calls `tick` each second until `unsubscribe(owner)` or `owner` goes away.
    func subscribe(_ owner: AnyObject, tick: @escaping () -> Void) {
        subscribers[ObjectIdentifier(owner)] = Subscriber(owner: owner, tick: tick)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func unsubscribe(_ owner: AnyObject) {
        subscribers[ObjectIdentifier(owner)] = nil
        stopIfIdle()
    }

    private func fire() {
        subscribers = subscribers.filter { $0.value.owner != nil }
        for subscriber in Array(subscribers.values) { subscriber.tick() }
        stopIfIdle()
    }

    private func stopIfIdle() {
        guard subscribers.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }
}
