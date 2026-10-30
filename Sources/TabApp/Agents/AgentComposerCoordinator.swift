import AppKit
import TabCore
import TabProtocol

struct AgentMentionThread: Sendable {
    var id: String
    var title: String
    var context: String
}

/// Keeps async context search separate from editing, so stale results cannot replace a new query.
@MainActor
final class AgentComposerCoordinator {
    var loadFiles: (() async throws -> [String])?
    var loadThreads: (() async throws -> [AgentMentionThread])?
    var loadSkills: (() async throws -> [AgentComposerSkill])?
    var onAction: ((String) -> Void)?
    var onContext: ((String, String) -> Void)?
    var onError: ((String) -> Void)?
    private let surface: AgentPaneView
    private var task: Task<Void, Never>?
    private var trigger: AgentComposerTrigger?
    private var triggerState = AgentComposerTriggerState()
    private var files: [String]?
    private var threads: [AgentMentionThread] = []
    private var threadsLoaded = false
    private var skills: [AgentComposerSkill]?
    private var loadedAt = Date.distantPast
    private var actions: [AgentComposerSuggestion] {
        [
            .init(id: "model", title: "/model", subtitle: "Choose the model for this conversation", symbol: "cpu", kind: .action),
            .init(id: "effort", title: "/effort", subtitle: "Change reasoning effort", symbol: "dial.low", kind: .action),
            .init(id: "access", title: "/access", subtitle: "Change tool permissions", symbol: "lock.shield", kind: .action),
            .init(id: "attach", title: "/attach", subtitle: "Attach files or images", symbol: "paperclip", kind: .action),
            .init(id: "stop", title: "/stop", subtitle: "Stop the current response", symbol: "stop.circle", kind: .action),
            .init(id: "clear", title: "/clear", subtitle: "Clear the current draft and attachments", symbol: "eraser", kind: .action)
        ]
    }

    init(surface: AgentPaneView) {
        self.surface = surface
        surface.suggestions.onSelect = { [weak self] in self?.select($0) }
    }

    func invalidate() {
        task?.cancel()
        files = nil
        skills = nil
        threads = []
        threadsLoaded = false
        loadedAt = .distantPast
        triggerState.reset()
        hide()
    }

    func changed() {
        task?.cancel()
        let editor = surface.composer
        guard !editor.hasMarkedText(),
              let next = triggerState.resolve(AgentComposerTrigger.parse(text: editor.string, selection: editor.selectedRange())) else {
            hide()
            return
        }
        trigger = next
        if Date().timeIntervalSince(loadedAt) > 30 { files = nil; skills = nil; threadsLoaded = false }
        show(matches(next), loading: true)
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                guard let self else { return }
                if next.kind == .mention {
                    if self.files == nil {
                        let files = try await self.loadFiles?() ?? []
                        try Task.checkCancellation()
                        self.files = files
                        self.show(self.matches(next), loading: true)
                    }
                    if !self.threadsLoaded {
                        let threads = try await self.loadThreads?() ?? []
                        try Task.checkCancellation()
                        self.threads = threads
                        self.threadsLoaded = true
                    }
                } else if self.skills == nil {
                    let skills = try await self.loadSkills?() ?? []
                    try Task.checkCancellation()
                    self.skills = skills
                }
                try Task.checkCancellation()
                self.loadedAt = Date()
                guard self.trigger == next else { return }
                self.show(self.matches(next))
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                if let self, self.trigger == next { self.show(self.matches(next)) }
                self?.onError?("Could not load composer suggestions: \(error.localizedDescription)")
            }
        }
    }

    func handle(_ selector: Selector) -> Bool {
        guard !surface.suggestions.isHidden, !surface.composer.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            surface.suggestions.moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            surface.suggestions.moveSelection(-1)
        case #selector(NSResponder.insertTab(_:)):
            _ = surface.suggestions.acceptSelection()
        case #selector(NSResponder.insertNewline(_:)):
            guard !NSEvent.modifierFlags.contains(.shift) else { return false }
            _ = surface.suggestions.acceptSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default: return false
        }
        return true
    }

    func performTypedAction() -> Bool {
        let text = surface.composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let action = actions.first(where: { $0.title == text }) else { return false }
        surface.composer.selectAll(nil)
        surface.composer.insertText("", replacementRange: surface.composer.selectedRange())
        dismiss()
        onAction?(action.id)
        return true
    }

    func dismiss() { triggerState.dismiss(trigger); task?.cancel(); hide() }

    private func hide() {
        trigger = nil
        surface.suggestions.isHidden = true
        surface.needsLayout = true
    }

    private func show(_ items: [AgentComposerSuggestion], loading: Bool = false) {
        surface.suggestions.emptyStateText = loading ? "Searching…" : "No matches"
        surface.suggestions.update(items, theme: surface.theme)
        surface.suggestions.isHidden = false
        surface.needsLayout = true
    }

    private func matches(_ trigger: AgentComposerTrigger) -> [AgentComposerSuggestion] {
        let query = trigger.query
        if trigger.kind == .command {
            let candidates = actions + (skills ?? []).map {
                AgentComposerSuggestion(id: $0.id, title: "/skill:\($0.name)", subtitle: $0.description,
                                        symbol: "sparkles", kind: .skill)
            }
            return query.isEmpty ? Array(candidates.prefix(40))
                : Fuzzy.rank(candidates, key: { $0.title }, query: query, limit: 40).map(\.item)
        }
        let threadMatches = query.isEmpty ? Array(threads.prefix(5))
            : Fuzzy.rank(threads, key: { $0.title }, query: query, limit: 8).map(\.item)
        let paths = files ?? []
        let fileMatches = query.isEmpty ? Array(paths.prefix(30))
            : Fuzzy.rank(paths, key: { $0 }, query: query, limit: 30).map(\.item)
        return threadMatches.map {
            .init(id: $0.id, title: $0.title, subtitle: "Thread", symbol: "bubble.left.and.bubble.right", kind: .thread)
        } + fileMatches.map {
            .init(id: $0, title: ($0 as NSString).lastPathComponent,
                  subtitle: ($0 as NSString).deletingLastPathComponent, symbol: "doc", kind: .file)
        }
    }

    private func select(_ item: AgentComposerSuggestion) {
        guard let trigger,
              AgentComposerTrigger.parse(text: surface.composer.string, selection: surface.composer.selectedRange()) == trigger else { return }
        let replacement: String
        switch item.kind {
        case .action: replacement = ""
        case .file:
            replacement = item.id.contains(where: { $0.isWhitespace }) ? "@\"\(item.id)\" " : "@\(item.id) "
        case .thread:
            replacement = "@\"\(item.title)\" "
            if let thread = threads.first(where: { $0.id == item.id }) {
                onContext?("Thread-\(thread.id).txt", "Referenced conversation: \(thread.title)\n\n\(thread.context)")
            }
        case .skill:
            replacement = "/skill:\(item.title.replacingOccurrences(of: "/skill:", with: "")) "
            if let skill = skills?.first(where: { $0.id == item.id }) {
                let directory = (skill.path.rawValue as NSString).deletingLastPathComponent
                onContext?("Skill-\(skill.name).md", "Use the following skill instructions for this request. Resolve skill-relative resources from \(directory).\n\n\(skill.instructions)")
            }
        }
        surface.composer.insertText(replacement, replacementRange: trigger.range)
        task?.cancel()
        triggerState.reset()
        hide()
        surface.refreshComposer()
        if item.kind == .action { onAction?(item.id) }
        else { surface.window?.makeFirstResponder(surface.composer) }
    }
}
