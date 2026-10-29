import AppKit
import TabClient
import TabCore
import TabProtocol

/// An attached session as the terminal sees it.
public struct TerminalAttachment: Sendable {
    public var channel: ChannelId
    public var snapshot: AttachSnapshot
    public var process: ForegroundProcess?
    public var events: AsyncStream<ChannelEvent>

    public init(channel: ChannelId, snapshot: AttachSnapshot, process: ForegroundProcess?,
                events: AsyncStream<ChannelEvent>) {
        self.channel = channel
        self.snapshot = snapshot
        self.process = process
        self.events = events
    }
}

/// The server calls a terminal pane makes. `ServerClient` provides them; tests
/// use a fake.
public protocol TerminalBackend: AnyObject, Sendable {
    func attachTerminal(session: SessionId, size: Size) async throws -> TerminalAttachment
    func detach(channel: ChannelId) async throws
    func sendInput(channel: ChannelId, _ input: TerminalInput) throws
    func ack(channel: ChannelId, seq: UInt64) throws
    func resize(channel: ChannelId, size: Size) throws
    func scroll(channel: ChannelId, _ scroll: ScrollRequest) throws
    func sendCellSize(channel: ChannelId, _ cell: CellSize) throws
    func clear(channel: ChannelId) throws
    func historyPage(channel: ChannelId, before: HistoryCursor?, maxRows: UInt16) async throws -> HistoryPage
    func searchHistory(_ source: SearchSource, query: String, ignoreCase: Bool, before: HistoryCursor?,
                       maxResults: UInt16) async throws -> SearchPage
    func setTerminalColors(_ colors: TerminalColors) async throws
    func upload(session: SessionId, name: String, bytes: Data) async throws -> ServerPath
}

extension ServerClient: TerminalBackend {
    public func attachTerminal(session: SessionId, size: Size) async throws -> TerminalAttachment {
        let attachment = try await attach(session: session, size: size)
        return TerminalAttachment(channel: attachment.channel, snapshot: attachment.snapshot,
                                  process: attachment.process, events: attachment.events)
    }
}

public enum TerminalSessionState: Equatable, Sendable {
    /// Not attached: hidden, not started, or the connection dropped. The
    /// last screen stays shown.
    case detached
    case attaching
    case live
    case ended(ExitReason?)
    case failed(String)
}

/// What a terminal pane tells the shell.
@MainActor public protocol TerminalSessionControllerDelegate: AnyObject {
    func terminalSession(_ session: TerminalSessionController, didChangeState state: TerminalSessionState)
    func terminalSession(_ session: TerminalSessionController, didChangeTitle title: String)
    func terminalSession(_ session: TerminalSessionController, didChangeDirectory directory: ServerPath)
    func terminalSession(_ session: TerminalSessionController, didChangeForegroundProcess process: ForegroundProcess)
    func terminalSessionDidRingBell(_ session: TerminalSessionController)
    /// A program wrote the clipboard (OSC 52); the text is already on it.
    func terminalSession(_ session: TerminalSessionController, didWriteClipboard text: String)
    func terminalSession(_ session: TerminalSessionController, didChangeInputModes modes: InputModes)
    func terminalSession(_ session: TerminalSessionController, didChangeFontSize size: Double)
    func terminalSession(_ session: TerminalSessionController, didFail error: Error)
    /// The user asked to reload `terminal.json` (a `reload_config` binding).
    func terminalSessionRequestsReload(_ session: TerminalSessionController)
}

public extension TerminalSessionControllerDelegate {
    func terminalSession(_ session: TerminalSessionController, didChangeState state: TerminalSessionState) {}
    func terminalSession(_ session: TerminalSessionController, didChangeTitle title: String) {}
    func terminalSession(_ session: TerminalSessionController, didChangeDirectory directory: ServerPath) {}
    func terminalSession(_ session: TerminalSessionController, didChangeForegroundProcess process: ForegroundProcess) {}
    func terminalSessionDidRingBell(_ session: TerminalSessionController) {}
    func terminalSession(_ session: TerminalSessionController, didWriteClipboard text: String) {}
    func terminalSession(_ session: TerminalSessionController, didChangeInputModes modes: InputModes) {}
    func terminalSession(_ session: TerminalSessionController, didChangeFontSize size: Double) {}
    func terminalSession(_ session: TerminalSessionController, didFail error: Error) {}
    func terminalSessionRequestsReload(_ session: TerminalSessionController) {}
}

/// One terminal pane's session: attaches with the view's grid size and cell
/// size, applies frames to the grid and acks them once drawn, sends input,
/// resizes, pages and searches history, jumps between prompts, and reports
/// metadata. Hidden panes detach but keep their last screen.
@MainActor public final class TerminalSessionController: TerminalViewHost, FindBarDelegate {
    public let session: SessionId
    public let backend: TerminalBackend
    /// The session runs on another computer: drops and image pastes upload.
    public let isRemote: Bool
    public weak var delegate: TerminalSessionControllerDelegate?
    /// The pane content: the find bar over the terminal.
    public let containerView: TerminalContainerView
    public var view: TerminalView { containerView.terminal }

    public private(set) var state: TerminalSessionState = .detached
    public private(set) var channel: ChannelId?
    public private(set) var title = ""
    public private(set) var directory: ServerPath?
    public private(set) var process: ForegroundProcess?
    public private(set) var find: TerminalFind?

    /// The pane title: what the program set, else the running program, else
    /// the folder.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        if let process, !process.isShell, !process.name.isEmpty { return process.name }
        if let directory { return Self.abbreviate(directory.rawValue) }
        return process?.name ?? ""
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private var visible = true
    private var attachTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var sentSize: Size?
    private var sentCellSize: CellSize?
    private var sentColors: TerminalColors?
    private var resizeScheduled = false
    private var historyLoading = false
    private var pendingScroll = 0
    private var prompt: PromptOperation?
    private var revealPending = false
    private var revealFirst = false
    /// The newest history was fetched once for the match being revealed.
    private var revealRefreshed = false
    private var findRefresh: DispatchWorkItem?
    private var reportedFontSize: Double

    private enum PromptOperation {
        case previous(fromBottom: Int)
        case next(fromBottom: Int)
        case select(fromBottom: Int, includePrompt: Bool)
    }

    public init(session: SessionId, backend: TerminalBackend, settings: TerminalSettings, palette: TerminalPalette,
                remote: Bool = false, directory: ServerPath? = nil, cachedGrid: RunGrid? = nil) {
        self.session = session
        self.backend = backend
        isRemote = remote
        self.directory = directory
        containerView = TerminalContainerView(terminal: TerminalView(settings: settings, palette: palette))
        reportedFontSize = settings.fontSize
        containerView.findBar.delegate = self
        view.host = self
        if let cachedGrid { view.setGrid(cachedGrid) }
    }

    // MARK: Attaching

    /// Attaches to the session, showing the cached screen until the
    /// server's arrives.
    public func attach() {
        guard attachTask == nil, channel == nil else { return }
        if case .ended = state { return }
        setState(.attaching)
        let size = view.bounds.width > 0 ? view.viewport : view.grid?.size ?? Size(cols: 80, rows: 24)
        attachTask = Task { [weak self, backend, session] in
            do {
                let attachment = try await backend.attachTerminal(session: session, size: size)
                self?.attached(attachment)
            } catch {
                self?.attachFailed(error)
            }
        }
    }

    /// Hidden panes detach and keep their screen; shown ones attach again.
    public func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        if visible {
            attach()
        } else {
            detach()
        }
    }

    /// Stops receiving the session, keeping the last screen.
    public func detach() {
        attachTask?.cancel()
        attachTask = nil
        eventTask?.cancel()
        eventTask = nil
        historyLoading = false
        findRefresh?.cancel()
        if let channel {
            self.channel = nil
            Task { [backend] in try? await backend.detach(channel: channel) }
        }
        if state == .live || state == .attaching { setState(.detached) }
    }

    func attached(_ attachment: TerminalAttachment) {
        attachTask = nil
        guard visible else {
            Task { [backend] in try? await backend.detach(channel: attachment.channel) }
            setState(.detached)
            return
        }
        channel = attachment.channel
        sentSize = attachment.snapshot.size
        sentCellSize = nil
        var grid = RunGrid(snapshot: attachment.snapshot)
        if let previous = view.grid, previous.scrollOffset > 0, previous.historyTotal == grid.historyTotal {
            grid.scroll(by: previous.scrollOffset)
        }
        view.setGrid(grid)
        updateTitle(attachment.snapshot.title)
        updateDirectory(attachment.snapshot.directory)
        if let process = attachment.process { updateProcess(process) }
        setState(.live)
        sendColors()
        sendCellSize()
        scheduleResize()
        eventTask = Task { [weak self] in
            for await event in attachment.events {
                guard let self else { return }
                self.handle(event)
            }
            self?.channelClosed(attachment.channel)
        }
    }

    private func attachFailed(_ error: Error) {
        attachTask = nil
        guard !Task.isCancelled else { return }
        setState(.failed(String(describing: error)))
        delegate?.terminalSession(self, didFail: error)
    }

    private func channelClosed(_ closed: ChannelId) {
        guard channel == closed else { return }
        channel = nil
        eventTask = nil
        if state == .live { setState(.detached) }
    }

    private func setState(_ next: TerminalSessionState) {
        guard next != state else { return }
        state = next
        view.needsDisplay = true
        delegate?.terminalSession(self, didChangeState: next)
    }

    // MARK: Channel events

    func handle(_ event: ChannelEvent) {
        switch event {
        case .frame(let frame):
            apply(frame)
        case .metadata(let metadata):
            apply(metadata)
        case .ended(let reason):
            channel = nil
            view.updateGrid { $0.cursor.visible = false }
            setState(.ended(reason))
        case .resized:
            break
        }
    }

    private func apply(_ frame: ScreenFrame) {
        let totalBefore = view.grid?.historyTotal
        let invalidated = view.updateGrid { $0.apply(frame) }
        if let grid = view.grid, grid.scrollOffset > 0 {
            if view.settings.options.scrollOnOutput {
                scrollToBottom()
            } else if totalBefore != grid.historyTotal {
                requestHistory(newest: true)
            }
        }
        if find != nil, totalBefore != view.grid?.historyTotal || !frame.rows.isEmpty { scheduleFindRefresh() }
        if invalidated, view.window != nil, !view.isHiddenOrHasHiddenAncestor { view.displayIfNeeded() }
        guard let channel else { return }
        try? backend.ack(channel: channel, seq: frame.seq)
    }

    private func apply(_ metadata: MetadataEvent) {
        switch metadata {
        case .title(let title):
            updateTitle(title)
        case .directory(let directory):
            updateDirectory(directory)
        case .foregroundProcess(let process):
            updateProcess(process)
        case .bell:
            NSSound.beep()
            delegate?.terminalSessionDidRingBell(self)
        case .history:
            if find != nil { scheduleFindRefresh() }
        case .inputModes(let modes):
            view.inputModes = modes
            delegate?.terminalSession(self, didChangeInputModes: modes)
        case .cursorBlinking(let blinking):
            view.cursorBlinks = blinking
        case .links(let seq, let rows):
            view.updateGrid { $0.links.replace(seq: seq, rows: rows) }
        case .screenPrompts(let seq, let rows):
            view.updateGrid { $0.screenPrompts(seq: seq, rows: rows) }
        case .clipboardWrite(let text):
            guard !text.isEmpty, text.utf8.count <= Limits.maxClipboardText else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            delegate?.terminalSession(self, didWriteClipboard: text)
        case .unknown:
            break
        }
    }

    private func updateTitle(_ title: String) {
        guard title != self.title else { return }
        self.title = title
        delegate?.terminalSession(self, didChangeTitle: title)
    }

    private func updateDirectory(_ directory: ServerPath) {
        guard directory != self.directory, !directory.rawValue.isEmpty else { return }
        self.directory = directory
        delegate?.terminalSession(self, didChangeDirectory: directory)
    }

    private func updateProcess(_ process: ForegroundProcess) {
        guard process != self.process else { return }
        self.process = process
        delegate?.terminalSession(self, didChangeForegroundProcess: process)
    }

    // MARK: Settings and colors

    /// Applies new terminal settings or theme colors; colors go to the server
    /// when they changed, so the engine answers color queries the same way.
    public func apply(settings: TerminalSettings, palette: TerminalPalette) {
        view.configure(settings: settings, palette: palette)
        containerView.needsLayout = true
        sendColors()
    }

    private func sendColors() {
        let colors = view.palette.terminalColors
        guard channel != nil, colors != sentColors else { return }
        sentColors = colors
        Task { [weak self, backend] in
            do {
                try await backend.setTerminalColors(colors)
            } catch {
                self?.sentColors = nil
            }
        }
    }

    private func sendCellSize() {
        let cell = view.metrics.physicalCellSize
        guard let channel, cell != sentCellSize else { return }
        sentCellSize = cell
        try? backend.sendCellSize(channel: channel, cell)
    }

    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.sendResize()
        }
    }

    private func sendResize() {
        guard let channel, state == .live, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let size = view.viewport
        guard size != sentSize else { return }
        sentSize = size
        try? backend.resize(channel: channel, size: size)
    }

    // MARK: TerminalViewHost

    var isLive: Bool { state == .live && channel != nil }
    var linkDirectory: String? { directory?.rawValue }

    func terminalView(_ view: TerminalView, send input: TerminalInput) {
        guard let channel, state == .live else { return }
        do {
            try backend.sendInput(channel: channel, input)
        } catch {
            delegate?.terminalSession(self, didFail: error)
        }
    }

    func terminalView(_ view: TerminalView, scrollBy rows: Int) {
        scroll(by: rows)
    }

    func terminalView(_ view: TerminalView, scrollTo offset: Int) {
        guard let grid = view.grid else { return }
        if offset <= 0 { return scrollToBottom() }
        scroll(by: offset - grid.scrollOffset)
    }

    func terminalView(_ view: TerminalView, perform command: TerminalCommand, at point: TerminalPoint?) {
        switch command {
        case .clearScreen: clearScreen()
        case .previousPrompt: jumpToPrompt(previous: true)
        case .nextPrompt: jumpToPrompt(previous: false)
        case .selectCommandOutput: selectCommandOutput(at: point)
        case .find: showFind()
        case .findNext: stepFind(previous: false)
        case .findPrevious: stepFind(previous: true)
        case .reloadConfiguration: delegate?.terminalSessionRequestsReload(self)
        default: view.perform(command, at: point)
        }
    }

    func terminalView(_ view: TerminalView, dropFiles paths: [String]) {
        guard isLive else { return }
        guard isRemote else {
            if let text = TerminalPaste.quotedPaths(paths) { view.pasteText(text) }
            return
        }
        Task { [weak self] in
            var remote: [String] = []
            for path in paths {
                guard let self else { return }
                let url = URL(fileURLWithPath: path)
                let bytes = await Task.detached { try? Data(contentsOf: url) }.value
                guard let bytes else { continue }
                do {
                    remote.append(try await self.backend.upload(session: self.session, name: url.lastPathComponent,
                                                                bytes: bytes).rawValue)
                } catch {
                    self.delegate?.terminalSession(self, didFail: error)
                }
            }
            if let self, let text = TerminalPaste.quotedPaths(remote) { self.view.pasteText(text) }
        }
    }

    func terminalView(_ view: TerminalView, pasteImage png: Data) {
        guard isLive else { return }
        guard isRemote else {
            terminalView(view, send: .bytes(Data([0x16])))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let name = "pasted-image-\(Int(Date().timeIntervalSince1970)).png"
                let path = try await self.backend.upload(session: self.session, name: name, bytes: png)
                if let text = TerminalPaste.quotedPaths([path.rawValue]) { self.view.pasteText(text) }
            } catch {
                self.delegate?.terminalSession(self, didFail: error)
            }
        }
    }

    func terminalView(_ view: TerminalView, didChangeViewport viewport: Size) {
        sendCellSize()
        scheduleResize()
        if view.fontSize != reportedFontSize {
            reportedFontSize = view.fontSize
            delegate?.terminalSession(self, didChangeFontSize: view.fontSize)
        }
    }

    func terminalView(_ view: TerminalView, didChangeFocus focused: Bool) {
        guard isLive else { return }
        terminalView(view, send: .focus(focused))
    }

    // MARK: Scrolling and history

    /// Scrolls history by rows, positive toward older output, fetching pages
    /// ahead of the view.
    public func scroll(by rows: Int) {
        guard let grid = view.grid, rows != 0 else { return }
        if rows > 0, grid.scrollOffset == 0, !grid.historyFresh, grid.historyTotal > 0 {
            pendingScroll = min(pendingScroll + rows, Int.max / 4)
            requestHistory(newest: true)
            return
        }
        let before = grid.scrollOffset
        view.updateGrid { $0.scroll(by: rows) }
        let moved = (view.grid?.scrollOffset ?? before) - before
        if rows > moved, view.grid?.historyCursor != nil {
            pendingScroll = min(pendingScroll + rows - moved, Int.max / 4)
        }
        prefetch()
        if find != nil, rows < 0, view.grid?.scrollOffset == 0 { scheduleFindRefresh() }
    }

    /// Back to live output.
    public func scrollToBottom() {
        pendingScroll = 0
        prompt = nil
        view.updateGrid { $0.scrollToBottom() }
    }

    private func prefetch() {
        guard let grid = view.grid else { return }
        if grid.needsOlderHistory(margin: Int(view.viewport.rows) * 3) || pendingScroll > 0 && grid.historyCursor != nil {
            requestHistory(newest: false)
        }
    }

    /// Fetches the newest history page (replacing what is fetched) or the next
    /// older one.
    private func requestHistory(newest: Bool) {
        guard !historyLoading, let channel, let grid = view.grid else { return }
        let before = newest ? nil : grid.historyCursor
        guard newest || before != nil else { return }
        let wanted = grid.scrollOffset + Int(view.viewport.rows) * 2 + 100
        let maxRows = UInt16(newest ? min(max(200, wanted), Limits.maxHistoryPage) : Limits.maxHistoryPage)
        historyLoading = true
        Task { [weak self, backend] in
            do {
                let page = try await backend.historyPage(channel: channel, before: before, maxRows: maxRows)
                self?.receiveHistory(page, newest: newest, channel: channel)
            } catch {
                self?.historyFailed(error, newest: newest, channel: channel)
            }
        }
    }

    private func receiveHistory(_ page: HistoryPage, newest: Bool, channel: ChannelId) {
        guard channel == self.channel else { return }
        historyLoading = false
        view.updateGrid { grid in
            if newest {
                grid.replaceHistory(page)
            } else {
                grid.fetchOlder(page)
            }
        }
        continueAfterHistory()
    }

    private func historyFailed(_ error: Error, newest: Bool, channel: ChannelId) {
        guard channel == self.channel else { return }
        historyLoading = false
        if !newest, (error as? ClientError)?.serverCode == .staleHistoryCursor {
            requestHistory(newest: true)
            return
        }
        pendingScroll = 0
        prompt = nil
        revealPending = false
    }

    private func continueAfterHistory() {
        if pendingScroll > 0 {
            let rows = pendingScroll
            pendingScroll = 0
            scroll(by: rows)
        }
        if prompt != nil { continuePrompt() }
        if revealPending {
            revealPending = false
            revealMatch()
        }
        prefetch()
    }

    // MARK: Prompts

    /// Scrolls to the previous or next prompt (shell integration marks).
    public func jumpToPrompt(previous: Bool) {
        guard isLive, let grid = view.grid else { return }
        let fromBottom = grid.scrollOffset + grid.rows.count
        prompt = previous ? .previous(fromBottom: fromBottom) : .next(fromBottom: fromBottom)
        continuePrompt()
    }

    /// Selects a command's output: the one under `point`, or the last
    /// finished one when `nil`.
    public func selectCommandOutput(at point: TerminalPoint? = nil) {
        guard isLive, let grid = view.grid else { return }
        let anchor = grid.history.count + (point?.row ?? Int(grid.cursor.row))
        prompt = .select(fromBottom: grid.history.count + grid.rows.count - anchor, includePrompt: point != nil)
        continuePrompt()
    }

    private func continuePrompt() {
        guard let operation = prompt, let grid = view.grid else { return }
        var needsNewestHistory = !grid.historyFresh && grid.historyTotal > 0
        if case .next = operation { needsNewestHistory = false }
        if needsNewestHistory { return requestHistory(newest: true) }
        let count = grid.history.count + grid.rows.count
        let sorted = grid.prompts.sorted()
        switch operation {
        case .previous(let fromBottom):
            let anchor = count - fromBottom
            guard let row = sorted.last(where: { $0 < anchor }) else {
                if grid.historyCursor != nil { return requestHistory(newest: false) }
                prompt = nil
                return
            }
            prompt = nil
            scrollToContentRow(row)
        case .next(let fromBottom):
            prompt = nil
            let anchor = count - fromBottom
            guard let row = sorted.first(where: { $0 > anchor }) else { return scrollToBottom() }
            scrollToContentRow(row)
        case .select(let fromBottom, let includePrompt):
            let anchor = count - fromBottom
            guard let row = sorted.last(where: { includePrompt ? $0 <= anchor : $0 < anchor }) else {
                if grid.historyCursor != nil { return requestHistory(newest: false) }
                prompt = nil
                return
            }
            prompt = nil
            let end = sorted.first(where: { $0 > row }) ?? grid.history.count + Int(grid.cursor.row) + 1
            guard end > row + 1 else { return }
            let history = grid.history.count
            view.select(TerminalSelection(anchor: TerminalPoint(row: row + 1 - history, column: 0),
                                          head: TerminalPoint(row: end - 1 - history, column: grid.size.cols)))
        }
    }

    /// Puts a content row (history then screen) at the top of the view.
    private func scrollToContentRow(_ row: Int) {
        guard let grid = view.grid else { return }
        let offset = grid.history.count - row
        if offset <= 0 { return scrollToBottom() }
        view.updateGrid { $0.scroll(by: offset - $0.scrollOffset) }
        prefetch()
    }

    // MARK: Commands

    /// Clears the screen and history (Cmd+K).
    public func clearScreen() {
        guard let channel, isLive else { return }
        scrollToBottom()
        view.clearSelection()
        try? backend.clear(channel: channel)
    }

    // MARK: Find

    public func showFind() {
        guard view.grid != nil, state != .attaching else { return }
        if find == nil {
            find = TerminalFind()
            containerView.findBar.query = ""
            containerView.findBar.isCaseSensitive = false
            updateFindBar()
        }
        containerView.showFindBar(true)
        containerView.findBar.focus()
    }

    public func closeFind() {
        find = nil
        findRefresh?.cancel()
        findRefresh = nil
        view.find = nil
        containerView.showFindBar(false)
        view.window?.makeFirstResponder(view)
    }

    public func setFindQuery(_ query: String) {
        guard find != nil else { return }
        find?.query = query
        revealFirst = true
        restartFind()
    }

    public func toggleFindCase() {
        guard find != nil else { return }
        find?.ignoreCase.toggle()
        containerView.findBar.isCaseSensitive = !(find?.ignoreCase ?? true)
        revealFirst = true
        restartFind()
    }

    public func stepFind(previous: Bool) {
        guard find != nil else { return showFind() }
        find?.step(previous: previous)
        revealRefreshed = false
        revealMatch()
        updateFindBar()
    }

    private func restartFind() {
        findRefresh?.cancel()
        findRefresh = nil
        guard let request = find?.restart() else { return updateFindBar() }
        search(request)
        updateFindBar()
    }

    private func scheduleFindRefresh() {
        guard find != nil, findRefresh == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.findRefresh = nil
            guard self.find != nil, self.view.grid?.scrollOffset == 0 else { return }
            if self.find?.isSearching == true { return self.scheduleFindRefresh() }
            self.restartFind()
        }
        findRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func search(_ request: TerminalFind.Request) {
        guard let channel else { return }
        Task { [weak self, backend] in
            let result: Result<SearchPage, Error>
            do {
                result = .success(try await backend.searchHistory(.live(channel), query: request.query,
                                                                  ignoreCase: request.ignoreCase, before: request.before,
                                                                  maxResults: 200))
            } catch {
                result = .failure(error)
            }
            self?.receiveSearch(request, result)
        }
    }

    private func receiveSearch(_ request: TerminalFind.Request, _ result: Result<SearchPage, Error>) {
        guard find != nil else { return }
        let wasEmpty = find?.current == nil
        if let next = find?.receive(request, result) { search(next) }
        if wasEmpty, find?.current != nil, revealFirst {
            revealFirst = false
            revealRefreshed = false
            revealMatch()
        }
        updateFindBar()
    }

    /// Scrolls the current match into view, fetching history up to it.
    private func revealMatch() {
        guard let find, let match = find.currentMatch, let grid = view.grid else { return }
        let rows = Int(view.viewport.rows)
        let first = grid.history.count - grid.scrollOffset
        if let index = grid.searchContentRow(match.row, totalRows: find.totalRows) {
            revealRefreshed = false
            self.find?.loadingHistory = false
            if !(first..<first + rows).contains(index) {
                let offset = grid.history.count - max(0, index - rows / 2)
                if offset <= 0 {
                    scrollToBottom()
                } else {
                    view.updateGrid { $0.scroll(by: offset - $0.scrollOffset) }
                }
            }
            updateFindBar()
            return
        }
        let current = grid.historyFresh && grid.historyTotal == find.totalRows
        if current, grid.historyCursor == nil {
            self.find?.loadingHistory = false
            return updateFindBar()
        }
        if !current {
            guard !revealRefreshed else {
                self.find?.loadingHistory = false
                return updateFindBar()
            }
            revealRefreshed = true
        }
        self.find?.loadingHistory = true
        revealPending = true
        requestHistory(newest: !current)
        updateFindBar()
    }

    private func updateFindBar() {
        view.find = find
        containerView.findBar.counter = find?.counter ?? ""
    }

    public func findBar(_ bar: FindBar, didChangeQuery query: String) { setFindQuery(query) }
    public func findBarDidToggleCase(_ bar: FindBar) { toggleFindCase() }
    public func findBar(_ bar: FindBar, step previous: Bool) { stepFind(previous: previous) }
    public func findBarDidClose(_ bar: FindBar) { closeFind() }
}

/// A terminal pane's content below the card header: the find bar, when
/// open, above the terminal.
public final class TerminalContainerView: NSView {
    public let terminal: TerminalView
    public let findBar = FindBar()

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        findBar.isHidden = true
        addSubview(terminal)
        addSubview(findBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }

    func showFindBar(_ shown: Bool) {
        guard findBar.isHidden == shown else { return }
        findBar.isHidden = !shown
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    public override func layout() {
        super.layout()
        let barHeight = findBar.isHidden ? 0 : FindBar.height
        findBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        terminal.frame = CGRect(x: 0, y: barHeight, width: bounds.width, height: max(0, bounds.height - barHeight))
    }
}
