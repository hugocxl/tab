import Foundation
import TabCore

/// The user's computers as their app last described them, kept on disk so
/// agents started while no app is connected still know where they run.
final class InfrastructureStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var current: Infrastructure?

    init(url: URL) {
        self.url = url
        current = Infrastructure.read(from: url)
    }

    var infrastructure: Infrastructure? {
        lock.withLock { current }
    }

    func write(_ infrastructure: Infrastructure) throws {
        let changed = lock.withLock { () -> Bool in
            guard current != infrastructure else { return false }
            current = infrastructure
            return true
        }
        guard changed else { return }
        try infrastructure.write(to: url)
    }
}
