import AppKit
import TabProtocol

/// A sent message put back into the composer: its text and the attachments that could still
/// be read, naming those that couldn't.
struct AgentRestoredPrompt {
    var text: String
    var attachments: [AgentDraftAttachment]
    var missing: [String]

    /// Reads `item`'s attachments through `fetch`, which goes to the conversation's server.
    static func load(_ item: AgentChatItem, fetch: AgentAttachmentCache.Fetch?) async -> AgentRestoredPrompt {
        var restored = AgentRestoredPrompt(text: item.text, attachments: [], missing: [])
        for descriptor in item.attachments ?? [] {
            do {
                guard let fetch else { throw ModelError("Attachments can't be read here.") }
                let data = try await fetch(item.id, descriptor)
                let thumbnail = descriptor.mimeType.hasPrefix("image/")
                    ? await AgentAttachmentImporter.previewImage(data: data, pixels: 160) : nil
                restored.attachments.append(AgentDraftAttachment(name: descriptor.name, mimeType: descriptor.mimeType,
                                                                 data: data, thumbnail: thumbnail))
            } catch {
                restored.missing.append(descriptor.name)
            }
        }
        return restored
    }

    /// Says which attachments are no longer available, or nil when none are missing.
    var missingNotice: String? {
        guard !missing.isEmpty else { return nil }
        let names = missing.prefix(3).map { "“\($0)”" }.joined(separator: ", ") + (missing.count > 3 ? " and \(missing.count - 3) more" : "")
        return (missing.count == 1 ? "An attachment is" : "\(missing.count) attachments are") + " no longer available and wasn't added: " + names + "."
    }
}

/// What Edit from Here would change: the turns from a message on, and whether their files
/// can be put back from valid checkpoints.
struct AgentRewindPlan: Equatable {
    var item: AgentChatItem
    /// The turns the rewind removes, oldest first, beginning with the message's own.
    var turns: [AgentChatTurn]
    /// Their messages' opening lines, for the confirmation.
    var messages: [String]
    /// Files the removed turns changed, by their recorded checkpoints.
    var changedFiles: Int
    /// Why the files can't be restored, or nil when every removed turn has a checkpoint.
    var restoreUnavailable: String?
    /// Attachments of the message that can't be restored into the draft.
    var missingAttachments: [String] = []

    var canRestoreFiles: Bool { restoreUnavailable == nil && changedFiles > 0 }

    /// The plan for editing `snapshot` from its user message `item`, or why it can't be.
    static func make(_ snapshot: AgentChatSnapshot, item: AgentChatItem) -> Result<AgentRewindPlan, AgentRewindUnavailable> {
        guard item.kind == .user, !item.isProviderTurn, item.isComplete else { return .failure(.init("Only a message you sent can be edited from here.")) }
        guard snapshot.provider == .claude else {
            return .failure(.init("\(snapshot.provider.name) can't continue from an earlier message. Use Edit as New Prompt instead."))
        }
        let turns = snapshot.turns ?? []
        guard let index = turns.firstIndex(where: { $0.userItemID == item.id }) else {
            return .failure(.init("This message's turn is no longer kept, so the conversation can't be rewound to it."))
        }
        guard let rewindable = turns[index].rewindable else {
            return .failure(.init("This server can't rewind a conversation. Update Tab on it, then restart it."))
        }
        guard rewindable else { return .failure(.init("Claude Code can't continue from before this message.")) }
        if snapshot.status == .working || snapshot.status == .waiting || snapshot.queuedPrompts?.isEmpty == false
            || snapshot.subagents?.contains(where: { $0.status == .running }) == true {
            return .failure(.init("Stop active work and remove queued prompts before editing from here."))
        }
        let removed = Array(turns[index...])
        let byID = Dictionary(snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let messages = removed.compactMap { byID[$0.userItemID] }.map { item in
            let line = item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let text = line.isEmpty ? "(\(item.attachments?.count ?? 0) attachment\(item.attachments?.count == 1 ? "" : "s"))" : line
            return text.count > 80 ? String(text.prefix(79)) + "…" : text
        }
        var unavailable: String?
        for (offset, turn) in removed.enumerated() where turn.checkpoint == nil {
            let number = index + offset + 1
            switch turn.checkpointPhase {
            case .capturing: unavailable = "Turn \(number)'s changes are still being recorded."
            case .unavailable(let reason, _), .untracked(let reason): unavailable = "Turn \(number)'s changes weren't recorded: \(reason)"
            default: unavailable = "Turn \(number)'s changes weren't recorded."
            }
            break
        }
        let files = removed.reduce(0) { $0 + ($1.checkpoint?.totalFiles ?? 0) }
        return .success(AgentRewindPlan(item: item, turns: removed, messages: messages, changedFiles: files, restoreUnavailable: unavailable))
    }

    /// The confirmation's explanation.
    var summary: String {
        var lines = [turns.count == 1
            ? "This message and its reply are removed from the conversation:"
            : "This message and the \(turns.count - 1) after it are removed from the conversation, with their replies:"]
        lines += messages.prefix(5).map { "• " + $0 }
        if messages.count > 5 { lines.append("• …") }
        lines.append("")
        lines.append("The whole conversation is kept in history, and the message goes back into the composer. Your current draft is kept.")
        if let notice = AgentRestoredPrompt(text: "", attachments: [], missing: missingAttachments).missingNotice { lines.append(notice) }
        if canRestoreFiles {
            lines.append("These turns changed \(changedFiles == 1 ? "1 file" : "\(changedFiles) files"). Keep them as they are, or put them back as they were before this message.")
        } else if let restoreUnavailable, changedFiles > 0 || turns.contains(where: { $0.checkpoint == nil }) {
            lines.append("Files stay as they are. " + restoreUnavailable)
        } else {
            lines.append("These turns changed no files.")
        }
        return lines.joined(separator: "\n")
    }
}

/// Why a conversation can't be rewound to a message.
struct AgentRewindUnavailable: Error, Equatable {
    var reason: String
    init(_ reason: String) { self.reason = reason }
}

/// How the user chose to edit a sent message.
enum AgentEditMode: Equatable {
    case asNewPrompt
    case fromHere
}

/// What the user chose for Edit from Here.
enum AgentRewindChoice: Equatable {
    case keepFiles
    case restoreFiles
}

extension AgentChatTurn {
    /// The phase a turn's changes card shows: nothing while the turn still works.
    var reviewPhase: CheckpointPhase { completedAt == nil ? .unknown : checkpointPhase }
}

extension AgentChatTurn.CheckpointPhase {
    /// A changes card shows changed files, a recording in progress or why there is none.
    var showsCard: Bool {
        switch self {
        case .changed, .capturing, .unavailable, .untracked: true
        case .unknown, .unchanged: false
        }
    }
}

enum AgentRevertAvailability {
    /// Why this conversation's own work stops a revert now, or nil. The server checks again,
    /// with every conversation working in the same folder, when the revert is applied.
    static func reason(_ snapshot: AgentChatSnapshot?, submitting: Bool) -> String? {
        // Without a snapshot the server's own check, made when it applies the revert, decides.
        guard let snapshot else { return submitting ? "Stop the agent first: it may be changing these files." : nil }
        if submitting || snapshot.status == .working || snapshot.status == .waiting
            || snapshot.queuedPrompts?.contains(where: { $0.state == .delivering }) == true {
            return "Stop the agent first: it may be changing these files."
        }
        if snapshot.subagents?.contains(where: { $0.status == .running }) == true {
            return "This conversation's agents are still running and may change these files. Wait for them or stop them first."
        }
        return nil
    }

    /// What a revert did, for a notice.
    static func outcome(_ reply: AgentRevertReply) -> String {
        let unchanged = reply.unchanged?.count ?? 0
        if reply.reverted.isEmpty, unchanged > 0 {
            return unchanged == 1 ? "Already reverted: the file is as it was before this turn." : "Already reverted: these \(unchanged) files are as they were before this turn."
        }
        let reverted = reply.reverted.count == 1 ? "Reverted 1 file." : "Reverted \(reply.reverted.count) files."
        return unchanged == 0 ? reverted : reverted + " \(unchanged == 1 ? "1 file was" : "\(unchanged) files were") already as before."
    }
}

/// A choice in a sent message's edit menu.
final class AgentEditMenuChoice: NSObject {
    let item: AgentChatItem
    let rewind: Bool
    init(item: AgentChatItem, rewind: Bool) {
        self.item = item
        self.rewind = rewind
    }
}
