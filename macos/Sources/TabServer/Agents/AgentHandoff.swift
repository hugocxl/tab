import Foundation
import TabProtocol

/// A conversation taken over by another provider. One provider can't resume another's
/// conversation, so the new one gets the whole transcript ahead of the next message,
/// until it names a conversation of its own.
struct AgentHandoff: Sendable {
    /// The provider the conversation ran before the switch, as Settings › Agents names it.
    var previousProvider: String
    /// The transcript before the message that switched providers.
    var items: [AgentChatItem]
    /// Items the conversation dropped past its size limit, one JSON line each.
    var earlierFile: URL

    /// A tool's input or output past this many bytes is cut, keeping the transcript about
    /// what was said rather than every file the agent read.
    static let toolTextLimit = 4 * 1024

    /// `message` preceded by the transcript, read from disk, so call it off the sessions queue.
    func prompt(for message: String, archive: AgentEarlierArchive) -> String {
        var earlier: [AgentChatItem] = []
        if let lines = archive.lines(of: earlierFile) {
            let decoder = JSONDecoder()
            earlier = (0..<lines.count).compactMap { try? decoder.decode(AgentChatItem.self, from: lines[$0]) }
        }
        return Self.prompt(for: message, previousProvider: previousProvider, items: earlier + items)
    }

    static func prompt(for message: String, previousProvider: String, items: [AgentChatItem]) -> String {
        let entries = items.compactMap(entry)
        guard !entries.isEmpty else { return message }
        return """
        <conversation_history>
        This conversation began with another agent (\(previousProvider)), and you are taking it over. \
        Here is the conversation so far, oldest first. Long tool inputs and outputs are cut. \
        Treat it as context you already have, then answer the user's new message below it.

        \(entries.joined(separator: "\n\n"))
        </conversation_history>

        \(message)
        """
    }

    private static func entry(_ item: AgentChatItem) -> String? {
        switch item.kind {
        case .user:
            let attached = (item.attachments ?? []).map(\.name)
            let files = attached.isEmpty ? "" : "\n(Attached: \(attached.joined(separator: ", ")))"
            return (item.isProviderTurn || item.isRestartResume ? "[Event]\n" : "[User]\n") + item.text + files
        case .assistant:
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : "[Assistant]\n" + text
        case .tool:
            let tool = item.tool
            let status = tool?.status.map { " · \($0.rawValue)" } ?? ""
            var lines = ["[Tool: \(tool?.name ?? item.text)\(status)]"]
            if !item.text.isEmpty, item.text != tool?.name { lines.append(item.text) }
            if let input = tool?.input, !input.isEmpty { lines.append("Input:\n" + clipped(input)) }
            if let output = tool?.output ?? item.detail, !output.isEmpty { lines.append("Output:\n" + clipped(output)) }
            return lines.joined(separator: "\n")
        case .approval, .notice:
            return nil
        }
    }

    private static func clipped(_ text: String) -> String {
        guard text.utf8.count > toolTextLimit else { return text }
        return AgentSessions.utf8Prefix(text, bytes: toolTextLimit) + "\n[…cut]"
    }
}
