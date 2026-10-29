import AppKit
import Foundation
import TabCore
import TabProtocol

/// What the shell knows about a project when an AI action is offered.
public struct AIProjectContext: Sendable {
    /// The repository summary; `nil` hides the actions (not a repository yet).
    public var summary: GitSummary?
    /// Whether the branch has a pull request; `nil` while unknown, which hides
    /// Create Pull Request.
    public var hasPullRequest: Bool?
    /// Whether the project's server is connected and listed.
    public var connected: Bool
    /// Whether a Git action of the shell's own is running in the project.
    public var gitBusy: Bool
    /// The project folder on this Mac; `nil` for a project on another
    /// computer, since the AI tool runs here.
    public var localDirectory: URL?
    /// The project whose pull request prompt applies: a worktree's parent.
    public var promptProject: ProjectId
    /// The project's name, for messages about a project not shown.
    public var name: String

    public init(summary: GitSummary?, hasPullRequest: Bool?, connected: Bool, gitBusy: Bool,
                localDirectory: URL?, promptProject: ProjectId, name: String) {
        self.summary = summary
        self.hasPullRequest = hasPullRequest
        self.connected = connected
        self.gitBusy = gitBusy
        self.localDirectory = localDirectory
        self.promptProject = promptProject
        self.name = name
    }
}

/// Whether an action can run now.
public enum AIAvailability: Equatable, Sendable {
    case available(AIProvider)
    /// Shown but disabled, with why.
    case disabled(String)
    case hidden
}

/// How an action ended, ready for a toast or notification.
public enum AIActionResult: Equatable, Sendable {
    /// `url` is the new pull request's.
    case succeeded(title: String, detail: String, url: String?)
    case failed(title: String, detail: String)
}

/// The shell side of AI actions.
@MainActor
public protocol AIActionsHost: AnyObject {
    /// The AI section of the current settings.
    var aiSettings: AISettings { get }
    /// What the shell knows about `project`, or `nil` when it is gone.
    func aiContext(for project: ProjectId) -> AIProjectContext?
    /// Git and files on the project's server, or `nil` when not connected.
    func aiRepository(for project: ProjectId) -> RepositoryGit?
    /// Remembers the provider and options a commit was confirmed with
    /// (`AISettings.providers["commit"]` and `Settings.saveCommitChoices`).
    func saveAICommitChoices(_ choices: CommitChoices, provider: AIProvider)
    /// The window the confirmation sheet attaches to.
    var aiSheetWindow: NSWindow? { get }
    /// A run started, moved to another step, or ended in `project`.
    func aiActionsDidChange(project: ProjectId)
    /// A run ended; the shell shows it and refreshes the project's Git state.
    func aiAction(_ action: RepositoryAction, in project: ProjectId, didFinish result: AIActionResult)
}

/// Runs AI commit and pull request actions, one per project at a time.
@MainActor
public final class AIActionsController {
    public weak var host: AIActionsHost?
    /// The tools found at the last refresh.
    public private(set) var installed: [AIProvider]

    private struct Run {
        var id: Int
        var action: RepositoryAction
        var step: RepositoryStep
        var cancellation: AICancellation
    }

    private var runs: [ProjectId: Run] = [:]
    private var nextRun = 0
    private var confirming = false

    public init(host: AIActionsHost?, installed: [AIProvider] = AIProvider.installed()) {
        self.host = host
        self.installed = installed
    }

    /// Looks for installed tools again, including the login shell's `PATH`.
    public func refreshProviders() async {
        installed = await AIProvider.discover()
    }

    public func isRunning(_ project: ProjectId) -> Bool { runs[project] != nil }
    public func runningAction(_ project: ProjectId) -> RepositoryAction? { runs[project]?.action }
    public func runningStep(_ project: ProjectId) -> RepositoryStep? { runs[project]?.step }

    /// Whether `action` can run in `project` now, and with which tool.
    public func availability(_ action: RepositoryAction, project: ProjectId) -> AIAvailability {
        guard let host, let context = host.aiContext(for: project), let summary = context.summary else { return .hidden }
        if action == .createPullRequest && context.hasPullRequest != false { return .hidden }
        if let running = runs[project]?.action {
            return .disabled(running == action ? "\(action.settingsTitle) is running" : "Wait for the current AI action to finish")
        }
        if !context.connected { return .disabled("Connect to the server first") }
        if context.localDirectory == nil {
            return .disabled("AI actions run on this Mac and need the project folder here")
        }
        if context.gitBusy { return .disabled("Wait for the current Git action to finish") }
        if summary.branch == nil {
            return .disabled(action == .commit
                ? "Switch to a branch before committing" : "Switch to a branch before creating a pull request")
        }
        if summary.conflicted > 0 { return .disabled("Resolve merge conflicts first") }
        if summary.changed == 0 { return .disabled("The working tree is clean.") }
        switch AIProvider.resolve(action, settings: host.aiSettings, installed: installed) {
        case .success(let provider): return .available(provider)
        case .failure(let error): return .disabled(error.message)
        }
    }

    /// Asks to confirm `action` in a sheet, then runs it.
    public func start(_ action: RepositoryAction, project: ProjectId) {
        guard !confirming, let host else { return }
        let provider: AIProvider
        switch availability(action, project: project) {
        case .available(let available): provider = available
        case .disabled(let reason):
            host.aiAction(action, in: project, didFinish: .failed(title: "Couldn't start \(action.settingsTitle)", detail: reason))
            return
        case .hidden: return
        }
        guard let summary = host.aiContext(for: project)?.summary, let branch = summary.branch else { return }
        let confirmation = AIConfirmation(
            action: action, provider: provider, providers: action == .commit ? installed : [],
            choices: host.aiSettings.commit, staged: summary.staged > 0, branch: branch
        )
        confirming = true
        AIConfirmSheet.present(confirmation, on: host.aiSheetWindow) { [weak self] response in
            guard let self else { return }
            confirming = false
            guard let response else { return }
            var confirmed = confirmation
            confirmed.confirm(response)
            if action == .commit {
                self.host?.saveAICommitChoices(confirmed.choices, provider: confirmed.provider)
            }
            run(action, project: project, provider: confirmed.provider, choices: confirmed.commitChoices,
                branch: branch, head: summary.head, additionalPrompt: response.prompt)
        }
    }

    /// Runs a confirmed action unless the repository moved since.
    public func run(_ action: RepositoryAction, project: ProjectId, provider: AIProvider, choices: CommitChoices,
                    branch: String, head: String?, additionalPrompt: String = "") {
        guard let host else { return }
        let context = host.aiContext(for: project)
        guard case .available = availability(action, project: project),
              let context, context.summary?.branch == branch, context.summary?.head == head,
              let directory = context.localDirectory, let git = host.aiRepository(for: project)
        else {
            host.aiAction(action, in: project, didFinish: .failed(
                title: "\(action.settingsTitle) is no longer available. Try again.", detail: ""
            ))
            return
        }
        let configured = RepositoryActions.configuredPrompt(action, settings: host.aiSettings,
                                                            promptProject: context.promptProject)
        let instructions = RepositoryActions.instructions(configured: configured, additional: additionalPrompt)
        nextRun += 1
        let id = nextRun
        let cancellation = AICancellation()
        runs[project] = Run(id: id, action: action, step: .reading, cancellation: cancellation)
        host.aiActionsDidChange(project: project)
        let report: @Sendable (RepositoryStep) -> Void = { [weak self] step in
            Task { @MainActor in self?.advance(project, id: id, to: step) }
        }
        Task { [weak self] in
            let result: Result<RepositoryActions.Outcome, RepositoryActions.Failure>
            do {
                let plan = try await RepositoryActions.prepare(git, project: project, action: action, choices: choices,
                                                               branch: branch, head: head)
                report(.writing)
                let prompt = RepositoryActions.prompt(plan, instructions: instructions)
                let output = try await Task.detached(priority: .userInitiated) {
                    try provider.generate(prompt: prompt, in: directory, cancellation: cancellation)
                }.value
                let draft = try RepositoryActions.parseDraft(plan, output: output)
                result = await RepositoryActions.apply(git, plan: plan, draft: draft, report: report)
            } catch {
                let message = (error as? AIActionError)?.message ?? error.localizedDescription
                result = .failure(RepositoryActions.Failure(
                    action == .commit ? "Couldn't commit" : "Couldn't create pull request", message
                ))
            }
            self?.finish(action, project: project, id: id, result: result)
        }
    }

    /// Stops the run in `project`, if any.
    public func cancel(project: ProjectId) {
        runs[project]?.cancellation.cancel()
    }

    /// Stops every run, such as when the app quits.
    public func cancelAll() {
        runs.values.forEach { $0.cancellation.cancel() }
        BoundedProcess.terminateAll()
    }

    private func advance(_ project: ProjectId, id: Int, to step: RepositoryStep) {
        guard runs[project]?.id == id else { return }
        runs[project]?.step = step
        host?.aiActionsDidChange(project: project)
    }

    private func finish(_ action: RepositoryAction, project: ProjectId, id: Int,
                        result: Result<RepositoryActions.Outcome, RepositoryActions.Failure>) {
        if runs[project]?.id == id { runs[project] = nil }
        host?.aiActionsDidChange(project: project)
        host?.aiAction(action, in: project, didFinish: Self.describe(result))
    }

    static func describe(_ result: Result<RepositoryActions.Outcome, RepositoryActions.Failure>) -> AIActionResult {
        switch result {
        case .success(.committed(let hash, let branch, let pushed)):
            let short = RepositoryActions.short(hash)
            guard let pushed else {
                return .succeeded(title: "Committed locally", detail: "\(short) on \(branch)", url: nil)
            }
            return .succeeded(title: "Committed and pushed", detail: "\(short) → \(pushed.remote)/\(pushed.branch)", url: nil)
        case .success(.pullRequest(let url)):
            return .succeeded(title: "Pull request created", detail: url, url: url)
        case .failure(let failure):
            return .failed(title: failure.title, detail: failure.detail)
        }
    }
}

/// What the confirmation sheet asks, captured before it shows and checked
/// again before anything changes.
struct AIConfirmation {
    var action: RepositoryAction
    var provider: AIProvider
    /// Tools a commit can switch to before confirming.
    var providers: [AIProvider]
    /// The commit options to remember, even when `staged` overrides one.
    var choices: CommitChoices
    /// Whether anything is staged, so a commit can leave unstaged changes out.
    var staged: Bool
    var branch: String

    struct Response {
        var prompt = ""
        var provider: AIProvider?
        var includeUnstaged: Bool?
        var push: Bool?
    }

    var title: String {
        action == .commit ? "Commit to \"\(branch)\"?" : "Create a pull request from \"\(branch)\"?"
    }

    var message: String {
        switch action {
        case .commit:
            return "Tab will ask the AI provider for a commit message, then commit."
        case .createPullRequest:
            return "Tab will stage all changes, ask \(provider.name) for a branch name, title, and summary, then create the branch, commit, push, and open the pull request on GitHub."
        }
    }

    /// Takes the tool and options the sheet was confirmed with.
    mutating func confirm(_ response: Response) {
        if let picked = response.provider, providers.contains(picked) { provider = picked }
        if let includeUnstaged = response.includeUnstaged, staged { choices.includeUnstaged = includeUnstaged }
        if let push = response.push { choices.push = push }
    }

    /// What the action commits and whether it pushes. Pull requests always
    /// include every change and push.
    var commitChoices: CommitChoices {
        switch action {
        case .commit: return CommitChoices(includeUnstaged: choices.includeUnstaged || !staged, push: choices.push)
        case .createPullRequest: return CommitChoices()
        }
    }
}

/// The sheet confirming an AI action: provider and commit options for a
/// commit, and room for extra instructions.
@MainActor
enum AIConfirmSheet {
    static func present(_ confirmation: AIConfirmation, on parent: NSWindow?,
                        completion: @escaping (AIConfirmation.Response?) -> Void) {
        let theme = AppTheme.shared
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                            styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true)
        sheet.appearance = theme.nsAppearance
        var response = AIConfirmation.Response()
        var finished = false
        let finish = { (confirmed: Bool) in
            guard !finished else { return }
            finished = true
            if let parent, sheet.sheetParent == parent { parent.endSheet(sheet) } else { sheet.close() }
            completion(confirmed ? response : nil)
        }

        let title = makeLabel(confirmation.title, font: AppFont.title)
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 0
        let message = makeLabel(confirmation.message, font: AppFont.small, color: theme.fgMuted)
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 0
        var rows: [NSView] = []
        if confirmation.action == .commit {
            if !confirmation.providers.isEmpty {
                let picker = PopUp(
                    items: confirmation.providers.map { PopUp.Item(id: $0.id, title: $0.name) },
                    selected: confirmation.provider.id, label: "AI Provider"
                ) { id in response.provider = AIProvider.provider(id: id) }
                rows.append(CardRow(id: "provider", label: "AI Provider", control: picker))
            }
            let unstaged = Switch(isOn: confirmation.commitChoices.includeUnstaged, label: "Include unstaged changes") {
                response.includeUnstaged = $0
            }
            unstaged.isEnabled = confirmation.staged
            rows.append(CardRow(id: "unstaged", label: "Include unstaged changes", control: unstaged))
            rows.append(CardRow(id: "push", label: "Push after committing",
                                control: Switch(isOn: confirmation.choices.push, label: "Push after committing") {
                                    response.push = $0
                                }))
        }
        let prompt = InsetTextField(value: "", placeholder: "Additional instructions (optional)",
                                    label: "Additional instructions", width: nil, height: 56, multiline: true)
        prompt.onChange = { response.prompt = String($0.prefix(RepositoryActions.additionalPromptLimit)) }
        let cancel = PillButton("Cancel") { finish(false) }
        let confirm = PillButton(confirmation.action.settingsTitle, style: .primary) { finish(true) }
        let buttons = NSStackView(views: [NSView(), cancel, confirm])
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.controlGap

        let stack = NSStackView(views: [title, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        if !rows.isEmpty { stack.addArrangedSubview(Card(rows: rows)) }
        stack.addArrangedSubview(prompt)
        stack.addArrangedSubview(buttons)
        stack.setCustomSpacing(14, after: message)
        stack.setCustomSpacing(16, after: prompt)
        for view in stack.arrangedSubviews where view !== title && view !== message {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        title.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let background = ThemedBackground(color: { $0.raised })
        background.addSubview(stack)
        stack.pinEdges(to: background, insets: NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20))
        background.widthAnchor.constraint(equalToConstant: 420).isActive = true
        sheet.contentView = background
        sheet.initialFirstResponder = prompt.field
        guard let parent else {
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
            return
        }
        parent.beginSheet(sheet)
    }
}
