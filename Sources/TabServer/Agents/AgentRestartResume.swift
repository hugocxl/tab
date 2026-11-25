import Foundation
import TabProtocol

/// Carrying on a turn the server stopping cut short. The provider process ends with the
/// server, so the next server relaunches it on the same provider conversation and asks it to
/// continue, in a turn the pane shows as a note rather than the user's message.
enum AgentRestartResume {
    /// Automatic resumes in a row, without the agent replying or running a tool in between,
    /// after which a stopped turn waits for the user, so a turn that brings the server down
    /// doesn't do it again on every start.
    static let maxAttempts = 3

    /// What the conversation shows when the server stops during a turn that carries on.
    static let stoppedNotice = "Agent interrupted when the server stopped. It continues when the server starts again."
    /// What it shows when the turn waits for the user instead.
    static let interruptedNotice = "Agent interrupted when the server stopped. Send a message to resume."

    /// The row opening the resumed turn.
    static let note = "Tab's server restarted, so the agent continues where it left off."

    /// What the provider is told.
    static let prompt = """
        Tab's server restarted while you were working, which stopped your previous turn before it finished. \
        Continue the task from where you left off. A command or tool that was running was cut short, and a \
        permission request or question that was pending went unanswered, so check where things stand and run \
        or ask again as needed. Don't repeat work that already finished.
        """

    /// Whether a turn in `snapshot`, stopped with the server, carries on by itself: the
    /// provider can pick its conversation up again, and earlier automatic resumes made progress.
    static func resumes(_ snapshot: AgentChatSnapshot, handoff: Bool) -> Bool {
        guard snapshot.status == .working || snapshot.status == .waiting,
              snapshot.providerSession != nil || handoff else { return false }
        return attemptsWithoutProgress(snapshot.items) < maxAttempts
    }

    /// Resume rows since the agent last replied, ran a tool, or the user last wrote.
    static func attemptsWithoutProgress(_ items: [AgentChatItem]) -> Int {
        var count = 0
        for item in items.reversed() {
            if item.kind == .assistant || item.kind == .tool { break }
            guard item.kind == .user else { continue }
            guard item.isRestartResume else { break }
            count += 1
        }
        return count
    }
}
