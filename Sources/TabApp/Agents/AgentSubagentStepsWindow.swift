import AppKit
import TabClient
import TabProtocol

/// One agent's own steps, its tool calls and text, in a nested transcript. The pane
/// reads them again when its snapshot says the agent's steps changed (their content
/// revision, or their count from a server that predates revisions) or the agent finished,
/// so a running agent's window follows it without polling; reads that come in while one
/// is in flight become one more read. Steps older than the newest the server keeps load
/// in pages above them. A background shell's one step is its command and the end of its
/// output, which has no step count, so its window reads it again every few seconds while
/// the shell runs and the window is open.
@MainActor
final class AgentSubagentStepsWindow: NSWindowController, NSWindowDelegate {
    typealias Fetch = (String) async throws -> AgentSubagentSteps
    /// Saved steps before an archive position, or the newest when nil.
    typealias FetchEarlier = (String, Int?) async throws -> AgentEarlierItems
    let toolUseID: String
    private let fetch: Fetch
    private let fetchEarlier: FetchEarlier?
    private let scroll = NSScrollView()
    private let transcript = AgentTranscriptDocument(frame: .zero)
    private let message = makeLabel("", font: AppFont.body)
    private let background = ThemedBackground(color: { $0.paneBackground })
    private var loadTask: Task<Void, Never>?
    private var reloadPending = false
    private var outputRefresh: Timer?
    private var isShell = false
    private(set) var items: [AgentChatItem] = []
    /// The step count the shown items were read at.
    private(set) var loadedSteps: Int?
    /// The content revision the shown items were read at, from a server that sends one.
    private(set) var loadedRevision: UInt64?
    /// How many reads went to the server.
    private(set) var fetchCount = 0
    private var status: AgentSubagent.Status?
    private var earlier = AgentEarlierTimeline()
    private var earlierTask: Task<Void, Never>?
    private var earlierUnavailable = false
    private var latest: AgentSubagentSteps?
    var onClose: (() -> Void)?

    init(subagent: AgentSubagent, toolUseID: String, theme: AppTheme, fetch: @escaping Fetch,
         fetchEarlier: FetchEarlier? = nil) {
        self.toolUseID = toolUseID
        self.fetch = fetch
        self.fetchEarlier = fetchEarlier
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)
        window.delegate = self
        window.appearance = theme.nsAppearance
        transcript.isNested = true
        transcript.theme = theme
        background.theme = theme
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = transcript
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        message.alignment = .center
        message.textColor = theme.fgDim
        background.addSubview(scroll)
        background.addSubview(message)
        scroll.translatesAutoresizingMaskIntoConstraints = true
        message.translatesAutoresizingMaskIntoConstraints = true
        scroll.autoresizingMask = [.width, .height]
        message.autoresizingMask = [.width, .minYMargin]
        window.contentView = background
        scroll.frame = background.bounds.insetBy(dx: 16, dy: 0)
        message.frame = NSRect(x: 0, y: background.bounds.midY - 10, width: background.bounds.width, height: 20)
        update(subagent)
        window.center()
        // The listing may already have started the first read.
        if loadTask == nil { reload() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Takes the agent's latest listing and reads its steps again when they changed: a
    /// new content revision, a new count from a server without revisions, or the agent
    /// finishing.
    func update(_ subagent: AgentSubagent) {
        let state = subagent.status == .running ? "running" : subagent.status.rawValue
        window?.title = subagent.description + " · " + state
        let finished = status == .running && subagent.status != .running
        status = subagent.status
        isShell = subagent.agentType == "Shell"
        if isShell {
            let running = subagent.status == .running
            // A shell that just ended has its last output to read.
            if !running, outputRefresh != nil { reload(); return }
            followOutput(running)
        }
        if let revision = subagent.stepsRevision {
            if revision != loadedRevision || finished { reload() }
        } else if let steps = subagent.steps, steps != loadedSteps || finished {
            reload()
        } else if finished {
            reload()
        }
    }

    private func followOutput(_ running: Bool) {
        guard running != (outputRefresh != nil) else { return }
        outputRefresh?.invalidate()
        outputRefresh = running ? Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        } : nil
    }

    func reload() {
        guard loadTask == nil else { reloadPending = true; return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.loadTask = nil
                if self.reloadPending { self.reloadPending = false; self.reload() }
            }
            do {
                self.fetchCount += 1
                let steps = try await self.fetch(self.toolUseID)
                guard !Task.isCancelled else { return }
                self.show(steps)
            } catch is CancellationError {
            } catch {
                self.showMessage(error.localizedDescription)
            }
        }
    }

    private func show(_ steps: AgentSubagentSteps) {
        // A shell's output is what its window is for, so it opens expanded.
        if isShell, self.items.isEmpty, let id = steps.items.first?.id {
            transcript.rowStates["activity:" + id] = AgentTimelineRowState(toolExpandedIDs: [id])
        }
        latest = steps
        loadedSteps = steps.items.count
        loadedRevision = steps.revision
        let saved = steps.earlierSteps ?? 0
        let notKept = steps.omittedSteps ?? 0
        let shown = earlier.observe(steps.items, omitted: saved + notKept, resetID: nil)
        items = shown.items
        message.isHidden = !items.isEmpty
        if items.isEmpty {
            message.stringValue = steps.unavailable == true
                ? "This agent's steps weren't saved. Agents that ran before Tab saved their steps can't show them."
                : isShell ? "No output yet." : "No steps yet. They appear here as the agent works."
        }
        transcript.earlierNote = { hidden in Self.earlierNote(hidden: hidden, notKept: notKept) }
        let canLoad = fetchEarlier != nil && !earlierUnavailable && saved > 0 && (!earlier.isLoaded || earlier.canLoadMore)
        transcript.onEarlier = canLoad ? { [weak self] in self?.loadEarlier() } : nil
        if earlier.needsGapFill, canLoad { loadEarlier() }
        let following = scroll.contentView.bounds.maxY >= transcript.frame.height - 24
        transcript.update(items, omittedCount: shown.omitted)
        transcript.reflow(viewportWidth: scroll.contentSize.width)
        _ = transcript.updateViewport(scroll.contentView.bounds, followingEnd: following)
        if following { scroll.contentView.scroll(to: NSPoint(x: 0, y: transcript.viewportOrigin)) }
    }

    /// Why `hidden` earlier steps aren't shown: `notKept` of them went past the agent's
    /// retention limit, and the rest load on request.
    static func earlierNote(hidden: Int, notKept: Int) -> String {
        let unloaded = max(0, hidden - notKept)
        func steps(_ count: Int) -> String { count == 1 ? "1 earlier step" : "\(count) earlier steps" }
        guard notKept > 0 else { return steps(hidden) + (hidden == 1 ? " isn't" : " aren't") + " shown" }
        let lost = steps(notKept) + (notKept == 1 ? " wasn't" : " weren't") + " kept, past this agent's step limit"
        guard unloaded > 0 else { return lost }
        return steps(unloaded) + (unloaded == 1 ? " isn't" : " aren't") + " shown, and " + lost.prefix(1).lowercased() + lost.dropFirst()
    }

    /// Loads the page of saved steps before those shown, or fills a gap first.
    func loadEarlier() {
        guard earlierTask == nil, let fetchEarlier else { return }
        let toolUseID = toolUseID
        let gap = earlier.needsGapFill
        let before = earlier.olderCursor
        earlierTask = Task { [weak self] in
            defer { self?.earlierTask = nil }
            do {
                var pages = [try await fetchEarlier(toolUseID, gap ? nil : before)]
                while gap, let last = pages.last, self?.earlier.gapReached(last) == false, pages.count < 64 {
                    pages.append(try await fetchEarlier(toolUseID, last.start))
                }
                guard let self, !Task.isCancelled else { return }
                if gap {
                    self.earlier.fillGap(pages, resetID: nil)
                } else if let page = pages.first {
                    if page.items.isEmpty { self.earlierUnavailable = true }
                    else { self.earlier.accept(page, before: before, resetID: nil) }
                }
                if let latest = self.latest { self.show(latest) }
            } catch is CancellationError {
            } catch let error as ClientError where error.serverCode == .unsupported {
                self?.earlierUnavailable = true
                if let latest = self?.latest { self?.show(latest) }
            } catch {
                self?.showMessage(error.localizedDescription)
            }
        }
    }

    private func showMessage(_ text: String) {
        message.isHidden = false
        message.stringValue = text
    }

    @objc private func scrolled() {
        guard !transcript.isUpdatingViewport else { return }
        transcript.updateViewport(scroll.contentView.bounds, followingEnd: false)
    }

    func windowDidResize(_ notification: Notification) {
        transcript.reflow(viewportWidth: scroll.contentSize.width)
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        earlierTask?.cancel()
        outputRefresh?.invalidate()
        outputRefresh = nil
        NotificationCenter.default.removeObserver(self)
        onClose?()
    }
}
