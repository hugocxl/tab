import AppKit
import TabProtocol

/// One agent's own steps, its tool calls and text, in a nested transcript. The pane
/// reads them again when its snapshot says the agent's step count changed, so a
/// running agent's window follows it without polling.
@MainActor
final class AgentSubagentStepsWindow: NSWindowController, NSWindowDelegate {
    typealias Fetch = (String) async throws -> AgentSubagentSteps
    let toolUseID: String
    private let fetch: Fetch
    private let scroll = NSScrollView()
    private let transcript = AgentTranscriptDocument(frame: .zero)
    private let message = makeLabel("", font: AppFont.body)
    private let background = ThemedBackground(color: { $0.paneBackground })
    private var loadTask: Task<Void, Never>?
    private var reloadPending = false
    private(set) var items: [AgentChatItem] = []
    /// The step count the shown items were read at.
    private(set) var loadedSteps: Int?
    var onClose: (() -> Void)?

    init(subagent: AgentSubagent, toolUseID: String, theme: AppTheme, fetch: @escaping Fetch) {
        self.toolUseID = toolUseID
        self.fetch = fetch
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
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Takes the agent's latest listing and reads its steps again when they changed.
    func update(_ subagent: AgentSubagent) {
        let state = subagent.status == .running ? "running" : subagent.status.rawValue
        window?.title = subagent.description + " · " + state
        if let steps = subagent.steps, steps != loadedSteps { reload() }
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
                let steps = try await self.fetch(self.toolUseID)
                guard !Task.isCancelled else { return }
                self.show(steps.items)
            } catch is CancellationError {
            } catch {
                self.showMessage(error.localizedDescription)
            }
        }
    }

    private func show(_ items: [AgentChatItem]) {
        self.items = items
        loadedSteps = items.count
        message.isHidden = !items.isEmpty
        if items.isEmpty { message.stringValue = "No steps yet. They appear here as the agent works." }
        let following = scroll.contentView.bounds.maxY >= transcript.frame.height - 24
        transcript.update(items, omittedCount: 0)
        transcript.reflow(viewportWidth: scroll.contentSize.width)
        _ = transcript.updateViewport(scroll.contentView.bounds, followingEnd: following)
        if following { scroll.contentView.scroll(to: NSPoint(x: 0, y: transcript.viewportOrigin)) }
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
        NotificationCenter.default.removeObserver(self)
        onClose?()
    }
}
