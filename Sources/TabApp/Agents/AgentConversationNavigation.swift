import AppKit
import TabProtocol

/// Navigation uses retained item identities; it never needs to mount the whole transcript.
enum AgentPromptNavigation {
    static func entries(_ items: [AgentChatItem]) -> [AgentSearchPicker.Entry] {
        items.filter { $0.kind == .user && !$0.isAutomaticTurn }.enumerated().map { index, item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(id: item.id, title: text.isEmpty ? "Attachments" : text.replacingOccurrences(of: "\n", with: " "),
                         detail: "Prompt \(index + 1)" + ((item.attachments?.isEmpty == false) ? " · \(item.attachments?.count ?? 0) attachments" : ""))
        }
    }

    static func destination(ids: [String], current: String?, previous: Bool) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return previous ? ids.last : ids.first }
        let next = index + (previous ? -1 : 1)
        return ids.indices.contains(next) ? ids[next] : nil
    }
}

extension AgentPaneView {
    func showOutline() {
        closeOutline()
        let picker = AgentSearchPicker(title: "Conversation prompts", placeholder: "Search prompts…", theme: theme)
        picker.onSelect = { [weak self] id in
            guard let self else { return }
            self.revealPrompt(id)
        }
        picker.onClose = { [weak self] in self?.outlinePicker = nil }
        outlinePicker = picker
        updateOutline()
        picker.present(in: window)
    }

    func updateOutline() {
        guard let picker = outlinePicker else { return }
        let prompts = (snapshot?.items ?? []).lazy.filter { $0.kind == .user && !$0.isAutomaticTurn }
        if let outlineSource, prompts.elementsEqual(outlineSource) { return }
        let source = Array(prompts)
        outlineSource = source
        picker.update(AgentPromptNavigation.entries(source), note: (snapshot?.omittedItems ?? 0) > 0
            ? "Prompts currently loaded. Load earlier messages above the transcript to include older prompts." : "All retained conversation prompts")
    }

    func closeOutline() { outlinePicker?.close(); outlinePicker = nil; outlineSource = nil }

    @discardableResult
    func navigatePrompt(previous: Bool) -> Bool {
        let prompts = (snapshot?.items ?? []).filter { $0.kind == .user && !$0.isAutomaticTurn }
        let visibleTop = transcriptScroll.contentView.bounds.minY
        let id: String?
        if let current = navigationPromptID {
            id = AgentPromptNavigation.destination(ids: prompts.map(\.id), current: current, previous: previous)
        } else {
            let positions = prompts.compactMap { item -> (String, CGFloat)? in
                guard let entry = transcript.entryID(showing: item.id), let frame = transcript.frameForEntry(entry) else { return nil }
                return (item.id, frame.minY)
            }
            id = previous ? positions.last(where: { $0.1 < visibleTop - 1 })?.0
                : positions.first(where: { $0.1 > visibleTop + 1 })?.0
        }
        guard let id else { return false }
        revealPrompt(id)
        return true
    }

    private func revealPrompt(_ id: String) {
        if let entry = transcript.entryID(showing: id) {
            var states = transcript.rowStates
            var state = states[entry] ?? AgentTimelineRowState()
            state.expanded = true
            states[entry] = state
            transcript.rowStates = states
        }
        if reveal(.item(id)) { navigationPromptID = id }
    }
}

/// Decode a changed todo list once, not on each unrelated streamed token.
struct AgentTaskProgress {
    private var itemID: String?
    private var detail: String?
    private var list: AgentTodoList?
    private var status: AgentChatStatus?
    private(set) var title = ""
    /// The current or next step, beside the title.
    private(set) var step: String?
    /// How much of the list is done, 0...1.
    private(set) var fraction: CGFloat = 0
    /// The agent isn't working through the list now.
    private(set) var paused = false
    private(set) var target: String?

    mutating func update(_ snapshot: AgentChatSnapshot) {
        let item = snapshot.items.last { $0.workContext?.itemType == "todo_list" }
        let changed = itemID != item?.id || detail != item?.detail
        guard changed || status != snapshot.status else { return }
        status = snapshot.status
        if changed {
            itemID = item?.id
            detail = item?.detail
            list = AgentTodoList(detail: item?.detail)
        }
        guard let list, !list.steps.isEmpty, list.completedCount < list.steps.count else {
            target = nil; title = ""; step = nil; fraction = 0; return
        }
        target = itemID
        paused = snapshot.status != .working && snapshot.status != .waiting
        step = (list.steps.first { $0.status == .running } ?? list.steps.first { $0.status == .pending })?.text
        fraction = CGFloat(list.completedCount) / CGFloat(list.steps.count)
        title = (paused ? "Paused · " : "") + list.progress
    }
}
