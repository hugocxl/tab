import AppKit
import TabProtocol

/// Navigation uses retained item identities; it never needs to mount the whole transcript.
enum AgentPromptNavigation {
    static func entries(_ items: [AgentChatItem]) -> [AgentSearchPicker.Entry] {
        items.filter { $0.kind == .user }.enumerated().map { index, item in
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
        let prompts = (snapshot?.items ?? []).lazy.filter { $0.kind == .user }
        if let outlineSource, prompts.elementsEqual(outlineSource) { return }
        let source = Array(prompts)
        outlineSource = source
        picker.update(AgentPromptNavigation.entries(source), note: "Prompts retained in this conversation")
    }

    func closeOutline() { outlinePicker?.close(); outlinePicker = nil; outlineSource = nil }

    func navigatePrompt(previous: Bool) {
        let prompts = (snapshot?.items ?? []).filter { $0.kind == .user }
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
        if let id { revealPrompt(id) }
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
            target = nil; title = ""; return
        }
        target = itemID
        let step = list.steps.first { $0.status == .running } ?? list.steps.first { $0.status == .pending }
        let paused = snapshot.status != .working && snapshot.status != .waiting
        title = (paused ? "Paused · " : "") + list.progress + (step.map { " · " + $0.text } ?? "")
    }
}
