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
    var providerCommands: [String] = []
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
            .init(id: "outline", title: "/outline", subtitle: "Search prompts in this conversation", icon: .listTodo, kind: .action),
            .init(id: "previous-prompt", title: "/previous-prompt", subtitle: "Go to the previous prompt", icon: .chevronUp, kind: .action),
            .init(id: "next-prompt", title: "/next-prompt", subtitle: "Go to the next prompt", icon: .chevronDown, kind: .action),
            .init(id: "skills", title: "/skills", subtitle: "Browse installed skills", icon: .sparkles, kind: .action),
            .init(id: "status", title: "/status", subtitle: "Show current conversation settings", icon: .info, kind: .action),
            .init(id: "plan", title: "/plan", subtitle: "Turn plan mode on or off", icon: .listTodo, kind: .action),
            .init(id: "copy", title: "/copy", subtitle: "Copy the conversation as Markdown", icon: .copy, kind: .action),
            .init(id: "new", title: "/new", subtitle: "Start a new conversation", icon: .conversationAdd, kind: .action),
            .init(id: "resume", title: "/resume", subtitle: "Continue a Claude Code or Codex conversation from this folder",
                  icon: .history, kind: .action),
            .init(id: "clear-conversation", title: "/clear", subtitle: "Start a new conversation with a fresh context",
                  icon: .conversationAdd, kind: .action),
            .init(id: "model", title: "/model", subtitle: "Choose the model for this conversation", icon: .cpu, kind: .action),
            .init(id: "effort", title: "/effort", subtitle: "Change reasoning effort", icon: .brain, kind: .action),
            .init(id: "attach", title: "/attach", subtitle: "Attach files or images", icon: .paperclip, kind: .action),
            .init(id: "stop", title: "/stop", subtitle: "Stop the current response", icon: .stop, kind: .action),
            .init(id: "clear", title: "/clear-draft", subtitle: "Clear the current draft and attachments", icon: .eraser, kind: .action)
        ]
    }

    /// Claude lists these in headless mode, but they are internal, unavailable outside its
    /// terminal UI, or replaced by a Tab action: its `/clear` would reset the provider's
    /// context underneath a transcript that still shows the old conversation.
    static let hiddenProviderCommands: Set<String> = [
        "agents", "auto-mode-setup", "clear", "color", "extra-usage", "fast", "focus", "heapdump", "workflow-launch-exec"
    ]

    /// The command a prompt starts with, such as `compact` for `/compact now`. A leading
    /// path like `/Users/me/App.swift` is a prompt, not a command.
    static func commandName(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let token = trimmed.dropFirst().prefix { !$0.isWhitespace }
        guard !token.isEmpty, token.allSatisfy({ $0.isLetter || $0.isNumber || "-_:".contains($0) }) else { return nil }
        return String(token)
    }

    /// What Claude's own commands do, for the ones it lists without a description.
    static let providerCommandDescriptions: [String: String] = [
        "compact": "Summarize the conversation to free context",
        "context": "Show what fills the context window",
        "cost": "Show what this conversation has cost",
        "init": "Write a CLAUDE.md that describes this project",
        "review": "Review a pull request",
        "pr-comments": "Show a pull request's comments",
        "security-review": "Review the pending changes for security issues",
        "release-notes": "Show the release notes",
        "todos": "List the current to-dos",
        "insights": "Summarize how you use Claude Code",
        "statusline": "Set up the status line",
    ]

    /// Commands chosen from the menu, newest first, so the usual ones lead an empty `/`.
    /// Shared by every pane for the life of the app.
    static var recentlyUsed: [String] = []

    static func noteUse(_ id: String) {
        recentlyUsed.removeAll { $0 == id }
        recentlyUsed.insert(id, at: 0)
        if recentlyUsed.count > 24 { recentlyUsed.removeLast() }
    }

    /// Recently used items first, each group in its original order.
    static func rankedByUse(_ items: [AgentComposerSuggestion]) -> [AgentComposerSuggestion] {
        let rank = Dictionary(recentlyUsed.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.id] ?? Int.max, right = rank[rhs.element.id] ?? Int.max
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func describeProviderCommand(_ name: String) -> String {
        if let known = Self.providerCommandDescriptions[name] { return known }
        if let skill = skills?.first(where: { $0.name.lowercased() == name.lowercased() }), !skill.description.isEmpty {
            return skill.description
        }
        return (surface.snapshot?.provider.name ?? "Provider") + " command"
    }

    private var visibleProviderCommands: [String] {
        providerCommands.filter { name in
            !name.hasPrefix("__") && !Self.hiddenProviderCommands.contains(name)
                && !actions.contains { $0.title == "/" + name }
        }
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

    func browseSkills() {
        surface.composer.string = "/skill:"
        surface.composer.setSelectedRange(NSRange(location: 7, length: 0))
        surface.refreshComposer()
        changed()
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
            let provided = visibleProviderCommands
            let native = provided.map {
                AgentComposerSuggestion(id: "provider:" + $0, title: "/" + $0, subtitle: describeProviderCommand($0), icon: .terminal,
                                        kind: .providerCommand)
            }
            // The provider already runs its own skills by name; list a file skill once unless
            // the user is explicitly browsing `/skill:`.
            let providedNames = Set(provided.map { $0.lowercased() })
            let browsingSkills = query.lowercased().hasPrefix("skill:")
            let fileSkills = (skills ?? []).filter { browsingSkills || !providedNames.contains($0.name.lowercased()) }
            // What the provider and skills can do comes first; Tab's own navigation follows.
            let candidates = native + fileSkills.map {
                AgentComposerSuggestion(id: $0.id, title: "/skill:\($0.name)", subtitle: $0.description.isEmpty ? "Skill" : $0.description,
                                        icon: .sparkles, kind: .skill)
            } + actions
            return query.isEmpty ? Array(Self.rankedByUse(candidates).prefix(40))
                : Fuzzy.rank(candidates, key: { $0.title }, query: query, limit: 40).map(\.item)
        }
        let threadMatches = query.isEmpty ? Array(threads.prefix(5))
            : Fuzzy.rank(threads, key: { $0.title }, query: query, limit: 8).map(\.item)
        let paths = files ?? []
        // With nothing typed yet, the project's top-level files lead rather than whatever came first.
        let fileMatches = query.isEmpty ? Self.shallowest(paths, limit: 30)
            : Fuzzy.rank(paths, key: { $0 }, query: query, limit: 30).map(\.item)
        return threadMatches.map {
            .init(id: $0.id, title: $0.title, subtitle: "Thread", icon: .conversation, kind: .thread)
        } + fileMatches.map {
            .init(id: $0, title: ($0 as NSString).lastPathComponent,
                  subtitle: ($0 as NSString).deletingLastPathComponent, icon: .file, kind: .file)
        }
    }

    /// The `limit` least nested paths, each level in name order; only the levels used are sorted.
    static func shallowest(_ paths: [String], limit: Int) -> [String] {
        var levels: [Int: [String]] = [:]
        for path in paths { levels[path.utf8.reduce(0) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 }, default: []].append(path) }
        var result: [String] = []
        for depth in levels.keys.sorted() where result.count < limit {
            let level = levels[depth] ?? []
            result += level.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(limit - result.count)
        }
        return result
    }

    private func select(_ item: AgentComposerSuggestion) {
        guard let trigger,
              AgentComposerTrigger.parse(text: surface.composer.string, selection: surface.composer.selectedRange()) == trigger else { return }
        var replacement: String?
        switch item.kind {
        case .action: replacement = ""
        case .providerCommand: replacement = item.title + " "
        case .file:
            replacement = item.id.contains(where: { $0.isWhitespace }) ? "@\"\(item.id)\" " : "@\(item.id) "
        case .thread:
            let thread = threads.first(where: { $0.id == item.id })
            if let session = SessionId(string: item.id),
               surface.insertThreadMention(AgentThreadLink(session: session, project: surface.snapshot?.project),
                                           title: thread?.title ?? item.title, replacing: trigger.range) {
                replacement = nil
            } else { replacement = "@\"\(item.title)\" " }
            if let thread {
                onContext?("Thread-\(thread.id).txt", "Referenced conversation: \(thread.title)\n\n\(thread.context)")
            }
        case .skill:
            replacement = "/skill:\(item.title.replacingOccurrences(of: "/skill:", with: "")) "
            if let skill = skills?.first(where: { $0.id == item.id }) {
                let directory = (skill.path.rawValue as NSString).deletingLastPathComponent
                onContext?("Skill-\(skill.name).md", "Use the following skill instructions for this request. Resolve skill-relative resources from \(directory).\n\n\(skill.instructions)")
            }
        }
        if trigger.kind == .command { Self.noteUse(item.id) }
        if let replacement { surface.composer.insertText(replacement, replacementRange: trigger.range) }
        task?.cancel()
        triggerState.reset()
        hide()
        surface.refreshComposer()
        if item.kind == .action { onAction?(item.id) }
        else { surface.window?.makeFirstResponder(surface.composer) }
    }
}
