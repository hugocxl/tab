import AppKit
import TabProtocol
import XCTest
@testable import TabApp

/// Updates reuse the rows of unchanged turns; they must lay out exactly what a fresh
/// transcript would.
@MainActor
final class AgentTranscriptIncrementalTests: XCTestCase {
    /// Seeded, so a failing sequence can be replayed.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private struct Conversation {
        var items: [AgentChatItem] = []
        var turns: [AgentChatTurn] = []
        var next = 0
        var clock = 0.0

        mutating func id(_ prefix: String) -> String { next += 1; return "\(prefix)\(next)" }

        mutating func startTurn(provider: Bool = false) {
            completeTurn()
            let user = id("u")
            clock += 1
            items.append(AgentChatItem(id: user, kind: .user, text: "Question \(next)"))
            turns.append(AgentChatTurn(userItemID: user, startedAt: Date(timeIntervalSince1970: clock), status: .working))
        }

        mutating func completeTurn(failed: Bool = false) {
            guard let last = turns.indices.last, turns[last].completedAt == nil else { return }
            clock += 1
            turns[last].completedAt = Date(timeIntervalSince1970: clock)
            turns[last].status = failed ? .failed : .idle
        }

        mutating func addTool(status: AgentToolActivity.Status = .running) {
            items.append(AgentChatItem(id: id("t"), kind: .tool, text: "Read file",
                                       tool: .init(name: "Read", category: .read, status: status)))
        }

        mutating func addAssistant() {
            items.append(AgentChatItem(id: id("a"), kind: .assistant, text: "Answer", isComplete: false))
        }

        mutating func addTodo() {
            let native = id("todo")
            items.append(AgentChatItem(id: native, kind: .tool, text: "TodoWrite",
                                       tool: .init(name: "TodoWrite", category: .other, status: .completed)))
            items.append(AgentChatItem(id: "todo_list:" + native, kind: .tool, text: "Todo",
                                       detail: #"{"steps":[{"id":"1","text":"Do it","status":"pending"}]}"#,
                                       workContext: .init(itemType: "todo_list")))
        }

        mutating func addMisc(_ random: inout SplitMix) {
            switch Int.random(in: 0..<4, using: &random) {
            case 0: items.append(AgentChatItem(id: id("n"), kind: .notice, text: "Notice"))
            case 1: items.append(AgentChatItem(id: id("e"), kind: .tool, text: "Failed", workContext: .init(itemType: "error")))
            case 2: items.append(AgentChatItem(id: id("q"), kind: .user, text: "A note sent while working"))
            default: items.append(AgentChatItem(id: id("p"), kind: .approval, text: "Allow?", isComplete: Bool.random(using: &random)))
            }
        }

        mutating func stream() {
            guard let last = items.indices.last(where: { items[$0].kind == .assistant }) else { return }
            items[last].text += " more"
        }

        mutating func finishTools() {
            for index in items.indices where items[index].tool?.status == .running { items[index].tool?.status = .completed }
        }
    }

    func testIncrementalUpdatesMatchAFreshBuild() {
        for seed in UInt64(1)...8 {
            var random = SplitMix(state: seed)
            var conversation = Conversation()
            let document = AgentTranscriptDocument(frame: .zero)
            let whole = AgentTranscriptDocument(frame: .zero)
            whole.reusesUnchangedTurns = false
            for each in [document, whole] { each.provider = .claude }
            for step in 0..<220 {
                let before = conversation.items
                switch Int.random(in: 0..<14, using: &random) {
                case 0, 1: conversation.startTurn()
                case 2: conversation.completeTurn(failed: Bool.random(using: &random))
                case 3, 4: conversation.addTool()
                case 5: conversation.finishTools()
                case 6, 7: conversation.addAssistant()
                case 8, 9: conversation.stream()
                case 10: conversation.addTodo()
                case 11: conversation.addMisc(&random)
                case 12 where !conversation.items.isEmpty:
                    // An item in an earlier turn changes.
                    let index = Int.random(in: 0..<conversation.items.count, using: &random)
                    conversation.items[index].text += " edited"
                default: conversation.stream()
                }
                // What the pane passes: at most the items known to be those of the last update.
                let unchanged = (0..<min(before.count, conversation.items.count)).first { before[$0] != conversation.items[$0] }
                    ?? min(before.count, conversation.items.count)
                let lead = Int.random(in: 0...unchanged, using: &random)
                for each in [document, whole] {
                    each.update(conversation.items, omittedCount: 0, turns: conversation.turns, unchangedLead: lead)
                }
                if step % 37 == 36, let work = document.entryDescriptions.first(where: { $0.hasPrefix("Entry(id: \"work:") }) {
                    // Unfolding an earlier turn's work rebuilds from that turn.
                    let user = String(work.dropFirst("Entry(id: \"work:".count).prefix { $0 != "\"" })
                    if let start = conversation.items.firstIndex(where: { $0.id == user }),
                       let tool = conversation.items[start...].first(where: { $0.kind == .tool }) {
                        for each in [document, whole] { _ = each.anchor(revealing: .item(tool.id)) }
                    }
                }
                let reused = document.entryDescriptions, rebuilt = whole.entryDescriptions
                guard reused != rebuilt else { continue }
                let index = (0..<min(reused.count, rebuilt.count)).first { reused[$0] != rebuilt[$0] } ?? min(reused.count, rebuilt.count)
                return XCTFail("Seed \(seed), step \(step), entry \(index) of \(reused.count)/\(rebuilt.count):\n"
                    + (index < reused.count ? reused[index] : "none") + "\n" + (index < rebuilt.count ? rebuilt[index] : "none"))
            }
        }
    }

    func testStreamingIntoALongConversationRebuildsOnlyItsLastTurns() {
        var conversation = Conversation()
        for _ in 0..<400 {
            conversation.startTurn()
            conversation.addTool(status: .completed)
            conversation.addTool(status: .completed)
            conversation.addAssistant()
            conversation.completeTurn()
        }
        conversation.startTurn()
        conversation.addTool()
        conversation.addAssistant()
        let document = AgentTranscriptDocument(frame: .zero)
        document.update(conversation.items, omittedCount: 0, turns: conversation.turns)
        XCTAssertGreaterThan(document.rebuiltEntryCount, 1_000)
        let before = conversation.items.count
        conversation.stream()
        document.update(conversation.items, omittedCount: 0, turns: conversation.turns, unchangedLead: before - 3)
        XCTAssertLessThan(document.rebuiltEntryCount, 12, "Only the newest turns are rebuilt")
        conversation.completeTurn()
        conversation.startTurn()
        document.update(conversation.items, omittedCount: 0, turns: conversation.turns, unchangedLead: before)
        XCTAssertLessThan(document.rebuiltEntryCount, 12, "A new turn rebuilds the one before it, not all of them")
    }
}
