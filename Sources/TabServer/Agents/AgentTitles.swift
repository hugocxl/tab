import Foundation
import TabProtocol

/// The short titles Claude Code and Codex give their own sessions, for the
/// activity native chats report. Looked up on a queue of its own when a chat
/// is first seen and when each turn ends, never on the queues serving input.
final class AgentTitles: @unchecked Sendable {
    /// The history a conversation's provider saves in, by provider ID and kind.
    private let history: @Sendable (String?, AgentChatProvider) -> AgentHistory
    private let queue = DispatchQueue(label: "tab.agents.titles", qos: .utility)
    private let lock = NSLock()
    private var titles: [String: String] = [:]
    private var statuses: [String: AgentChatStatus] = [:]
    /// Called outside the lock after a lookup finds a new title.
    var onChange: (@Sendable () -> Void)?

    /// Providers write a title a little after the turn that earns it.
    private static let retryDelay: TimeInterval = 10

    init(history: @escaping @Sendable (String?, AgentChatProvider) -> AgentHistory) {
        self.history = history
    }

    convenience init(history: AgentHistory) {
        self.init { _, _ in history }
    }

    /// The title known for `snapshot`'s provider session, if any. Starts a
    /// lookup when the chat is new here or its turn just ended, as titles
    /// arrive after a first answer and change with a rename.
    func title(for snapshot: AgentChatSnapshot, directory: String) -> String? {
        guard let session = snapshot.providerSession else { return nil }
        let key = "\(snapshot.providerID ?? snapshot.provider.rawValue):\(session)"
        let (title, lookUp) = lock.withLock { () -> (String?, Bool) in
            let previous = statuses.updateValue(snapshot.status, forKey: key)
            let turnEnded = previous == .working && snapshot.status != .working
            return (titles[key], previous == nil || turnEnded)
        }
        if lookUp {
            let provider = snapshot.provider, id = snapshot.providerID
            queue.async { [self] in look(key: key, id: id, provider: provider, session: session, directory: directory) }
            queue.asyncAfter(deadline: .now() + Self.retryDelay) { [self] in
                look(key: key, id: id, provider: provider, session: session, directory: directory)
            }
        }
        return title
    }

    private func look(key: String, id: String?, provider: AgentChatProvider, session: String, directory: String) {
        guard let found = history(id, provider).sessionTitle(provider: provider, session: session, directory: directory) else { return }
        let changed = lock.withLock { titles.updateValue(found, forKey: key) != found }
        if changed { onChange?() }
    }
}
