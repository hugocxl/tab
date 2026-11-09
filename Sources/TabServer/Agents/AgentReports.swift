import Foundation
import TabProtocol

/// A worker's settled turn, waiting for the agent that asked for it.
struct AgentHeldReport: Codable, Hashable, Sendable {
    var worker: AgentPeer
    /// The worker turn's user item ID.
    var turn: String
    var outcome: AgentChatTurn.Outcome
    /// The worker's last reply, or what stopped it.
    var reply: String
    /// The agent that asked the coordinator for this work, which the
    /// coordinator's reply then goes back to.
    var upstream: SessionId?
    var settledAt: Date
}

/// How coordinators and workers talk: what each one's model reads, and when
/// a held report can go to its coordinator. Pure, so the rules are testable
/// without a provider.
enum AgentReports {
    /// How long a settled report waits before it is delivered, so a coordinator
    /// that waits for the worker itself reads the reply first and acknowledges it.
    static let grace: TimeInterval = 3
    /// A worker's reply longer than this is cut, pointing at `tab agent read`.
    static let maximumReplyBytes = 16 * 1024
    /// Workers one coordinator may have open at once.
    static let maximumWorkers = 16
    /// Coordinators above a worker, at most: A starts B starts C starts D.
    static let maximumDepth = 3
    /// Agent-driven deliveries in a row, without a message from the user, before
    /// delivery pauses; stops two agents from answering each other forever.
    static let maximumUnattendedDeliveries = 24
    /// Delivery attempts in a row that fail, such as a steer before the
    /// provider's turn exists, before delivery pauses.
    static let maximumDeliveryFailures = 10
    static let retryDelay: TimeInterval = 2

    enum Delivery: Equatable {
        /// Start a turn with the report.
        case start
        /// Add the report to the running turn.
        case steer
        /// Keep it until the coordinator can take it.
        case hold
    }

    /// What to do with a ready report for a coordinator in this state. A
    /// coordinator the user stopped, or one that failed, keeps its reports until
    /// the user sends a message or delivers them by hand (`forced`).
    static func delivery(status: AgentChatStatus, submitting: Bool, hasRuntime: Bool,
                         lastOutcome: AgentChatTurn.Outcome?, paused: Bool, forced: Bool) -> Delivery {
        guard !submitting, !paused || forced else { return .hold }
        switch status {
        case .working: return hasRuntime ? .steer : .hold
        case .idle: return forced || lastOutcome == nil || lastOutcome == .completed ? .start : .hold
        case .failed: return forced ? .start : .hold
        case .waiting, .closed: return .hold
        }
    }

    /// The reply of the turn that `turn` (a user item ID) started, up to the turn
    /// `next` starts: its last assistant message, or for a failed or stopped turn
    /// what stopped it. A message steered into the turn doesn't end it.
    static func reply(turn: String, next: String?, items: [AgentChatItem], outcome: AgentChatTurn.Outcome) -> String {
        let start = items.firstIndex { $0.id == turn }.map { $0 + 1 } ?? items.endIndex
        let end = next.flatMap { id in items.firstIndex { $0.id == id } }.map { max($0, start) } ?? items.endIndex
        let answer = items[start..<end].last { $0.kind == .assistant }?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = items[start..<end].last { $0.workContext?.itemType == "error" }?.text
        var text: String
        switch outcome {
        case .completed:
            text = answer.flatMap { $0.isEmpty ? nil : $0 } ?? "(The worker finished without a reply.)"
        case .failed:
            text = "The worker failed: " + (failure ?? "no reason given") + "."
            if let answer, !answer.isEmpty { text += "\n\nIts last reply:\n\n" + answer }
        case .interrupted:
            text = "The worker was stopped before it finished."
            if let answer, !answer.isEmpty { text += "\n\nIts last reply:\n\n" + answer }
        case .cancelled:
            text = "The worker's pane was closed before it finished."
        default:
            text = answer ?? "The worker's turn ended: \(outcome.rawValue)."
        }
        return clipped(text)
    }

    /// `text` cut to `maximumReplyBytes` at a character boundary.
    static func clipped(_ text: String) -> String {
        guard text.utf8.count > maximumReplyBytes else { return text }
        let note = "\n\n[Cut here. The rest is in the worker's conversation.]"
        var prefix = text.utf8.prefix(maximumReplyBytes - note.utf8.count)
        while let last = prefix.last, last & 0xC0 == 0x80 { prefix = prefix.dropLast() }
        if let last = prefix.last, last >= 0xC0 { prefix = prefix.dropLast() }
        return String(decoding: prefix, as: UTF8.self) + note
    }

    /// What the worker's model reads for a message `from` sent: the text inside a
    /// tag that says who wrote it, so it never mistakes another agent for the user.
    static func message(_ text: String, from: AgentPeer, reports: Bool) -> String {
        var result = "<tab-message from=\"\(attribute(from.name))\" agent=\"\(from.session)\">\n"
            + escaped(text, tag: "tab-message") + "\n</tab-message>\n\n"
            + "This message is from the Tab agent \(from.name), not from the user."
        if reports {
            result += " Your final reply to it goes back to that agent by itself when you finish, so end with a short"
                + " report of what you did and found. Don't send it with `tab agent send`."
        }
        return result
    }

    /// What the coordinator's model reads for a worker's report.
    static func report(_ report: AgentHeldReport, files: [String]) -> String {
        var body = escaped(report.reply, tag: "tab-report")
        if !files.isEmpty {
            let shown = files.prefix(32).joined(separator: ", ")
            body += "\n\nChanged files: " + shown + (files.count > 32 ? " and \(files.count - 32) more" : "")
        }
        return "<tab-report from=\"\(attribute(report.worker.name))\" agent=\"\(report.worker.session)\" "
            + "outcome=\"\(report.outcome.rawValue)\">\n" + body + "\n</tab-report>\n\n"
            + "This is a report from your worker \(report.worker.name), not a message from the user. "
            + "`tab agent read \(report.worker.session) --all` prints its whole conversation."
    }

    /// `name` with every name in `taken` avoided by a `-2`, `-3` … suffix.
    static func unique(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        for suffix in 2... {
            let tail = "-\(suffix)"
            let candidate = String(name.prefix(AgentChatSnapshot.maximumNameLength - tail.count)) + tail
            if !taken.contains(candidate) { return candidate }
        }
        return name
    }

    private static func attribute(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
    }

    /// Keeps the text from closing the tag around it early.
    private static func escaped(_ text: String, tag: String) -> String {
        text.replacingOccurrences(of: "</\(tag)>", with: "<\\/\(tag)>")
    }
}
