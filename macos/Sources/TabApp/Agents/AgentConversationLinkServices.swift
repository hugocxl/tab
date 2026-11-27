import AppKit
import TabProtocol

/// A per-conversation cache of lazily requested link details. Each key is requested
/// at most once while it is cached; concurrent observers share the request, and a
/// request nobody observes any more is cancelled and forgotten. A failure is dropped
/// with its last observer and otherwise retried by a subscription 30 seconds later.
@MainActor
final class AgentLazyRequestCache<Value: Equatable> {
    enum State: Equatable {
        case loading
        case loaded(Value)
        case failed(String)
    }
    typealias Fetch = @MainActor (String) async throws -> Value
    typealias Observer = @MainActor (State) -> Void

    /// Performs one request; unset, every request fails without leaving the app.
    var fetch: Fetch?
    private var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var observers: [String: [Int: Observer]] = [:]
    private var nextObserver = 0
    private var failureTimes: [String: Date] = [:]
    /// How long a failure is served before the next subscription retries.
    static var failureLifetime: TimeInterval { 30 }
    /// The clock failures are timed with.
    var now: () -> Date = { Date() }
    /// Requests started over the cache's lifetime.
    private(set) var requestCount = 0

    func state(for key: String) -> State? { states[key] }

    /// Reports the current state now and every later change, starting the request
    /// when `key` is neither cached nor loading. Cancel the observation when the
    /// observing view goes away.
    func observe(_ key: String, _ observer: @escaping Observer) -> AgentLazyRequestObservation {
        nextObserver += 1
        let id = nextObserver
        observers[key, default: [:]][id] = observer
        let observation = AgentLazyRequestObservation { [weak self] in self?.release(key, observer: id) }
        if case .failed = states[key], let failedAt = failureTimes[key], now().timeIntervalSince(failedAt) >= Self.failureLifetime {
            states[key] = nil
            failureTimes[key] = nil
        }
        if let state = states[key] {
            observer(state)
            return observation
        }
        start(key)
        if let state = states[key] { observer(state) }
        return observation
    }

    /// Forgets every result and cancels every request, for a different conversation.
    func reset() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        states.removeAll()
        failureTimes.removeAll()
        observers.removeAll()
    }

    private func start(_ key: String) {
        guard let fetch else {
            states[key] = .failed("This conversation cannot load link details.")
            return
        }
        requestCount += 1
        states[key] = .loading
        tasks[key] = Task { [weak self] in
            let result: State
            do { result = .loaded(try await fetch(key)) }
            catch is CancellationError { return }
            catch { result = .failed(error.message) }
            guard !Task.isCancelled, let self else { return }
            self.tasks[key] = nil
            self.states[key] = result
            if case .failed = result { self.failureTimes[key] = self.now() }
            let current = self.observers[key].map { Array($0.values) } ?? []
            for observer in current { observer(result) }
        }
    }

    private func release(_ key: String, observer id: Int) {
        observers[key]?[id] = nil
        guard observers[key]?.isEmpty != false else { return }
        observers[key] = nil
        if case .failed = states[key] {
            states[key] = nil
            failureTimes[key] = nil
            return
        }
        guard states[key] == .loading else { return }
        tasks.removeValue(forKey: key)?.cancel()
        states[key] = nil
    }
}

/// Ends one cache observation; cancelling twice is harmless.
@MainActor
final class AgentLazyRequestObservation {
    private var onCancel: (() -> Void)?
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }

    func cancel() {
        let cancel = onCancel
        onCancel = nil
        cancel?()
    }
}

/// What an assistant response needs to enrich its links: lazily loaded pull-request
/// previews and file metadata, cached for one conversation, and the actions that
/// open a link or put an artifact template's prompt in the composer.
@MainActor
final class AgentConversationLinkServices {
    typealias FileMetadata = AgentConversationFileActions.Metadata?

    let pullRequests = AgentLazyRequestCache<GitPullRequestPreview>()
    let fileMetadata = AgentLazyRequestCache<FileMetadata>()
    var openLink: ((String) -> Void)?
    /// Images, video and audio of assistant Markdown; nil keeps them ordinary text.
    var mediaLoader: AgentMediaLoader?
    /// Opens a message's images as a gallery, starting at the index.
    var previewMedia: (([AgentMarkdownMedia], Int) -> Void)?
    /// Plays a video or audio reference.
    var playMedia: ((AgentMarkdownMedia) -> Void)?
    var useTemplate: ((AgentArtifactTemplate) -> Void)?
    /// Writes plain text to the clipboard through the conversation actions; unset, copies go to the general pasteboard.
    var copyText: ((String) throws -> Void)?

    /// Copies `text`, reporting whether the clipboard accepted it.
    func copy(_ text: String) -> Bool {
        if let copyText { return (try? copyText(text)) != nil }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
    /// Opens a clicked file link at its line and column; nil falls back to the row's file callback.
    var openFile: ((AgentConversationFileTarget) -> Void)?
    /// Runs a link context-menu item and reports its failure to the conversation.
    var performLinkAction: ((AgentLinkMenu.Item, AgentLinkMenu.Target) -> Void)?
    /// Whether the conversation's project is on this Mac, so Finder and local files apply.
    var isLocalProject: () -> Bool = { false }
    /// Titles of other conversations of the project, for thread link chips.
    var threadTitles: [String: String] = [:]
    /// The project folder that relative file links are shown against.
    var workspaceRoot: String?
    var onPullRequestHostsChanged: (() -> Void)?
    /// Hosts whose pull-request links become cards: github.com and the origin's host.
    var pullRequestHosts: Set<String> = AgentPullRequestLink.hosts(origin: nil) {
        didSet { if oldValue != pullRequestHosts { onPullRequestHostsChanged?() } }
    }

    /// Clears every cached result when the surface shows another conversation.
    func reset() {
        pullRequests.reset()
        fileMetadata.reset()
        mediaLoader?.reset()
    }
}
