import Foundation
import Observation
import TabProtocol
import TabShared

/// Draws a terminal's grid. The controller calls `gridChanged` for each
/// frame; the display calls `frameDrawn()` once it has drawn, which lets the
/// server send the next frame.
@MainActor
public protocol TerminalDisplay: AnyObject {
    /// Marks what `changes` covers for redrawing. Returns false when nothing
    /// will draw (the view is offscreen), so the frame is acknowledged at once.
    func gridChanged(_ changes: GridChanges) -> Bool
}

/// One terminal session as this app shows it: the attachment, the screen
/// grid, fetched history and input. The server encodes keys against the
/// program's live modes, so input goes out as events, never bytes.
@MainActor
@Observable
public final class TerminalController {
    public enum State: Equatable {
        case detached
        case attaching
        case attached
        case ended(String)
    }

    public nonisolated let session: SessionId
    public private(set) var state: State = .detached
    public private(set) var title = ""
    public private(set) var directory: ServerPath?
    public private(set) var process: ForegroundProcess?
    public private(set) var inputModes = InputModes()
    public private(set) var cursorBlinks = true
    /// Whether the view shows history above live output.
    public private(set) var scrolledBack = false

    /// The screen; read by the display while drawing.
    @ObservationIgnored public private(set) var grid: RunGrid?
    @ObservationIgnored public weak var display: TerminalDisplay?
    /// Called with text a program copied (OSC 52).
    @ObservationIgnored public var onClipboardWrite: ((String) -> Void)?
    @ObservationIgnored public var onBell: (() -> Void)?

    @ObservationIgnored private weak var server: ServerModel?
    @ObservationIgnored private var client: ServerClient?
    @ObservationIgnored private var channel: ChannelId?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var size: Size?
    @ObservationIgnored private var cellSize: CellSize?
    @ObservationIgnored private var sentSize: Size?
    @ObservationIgnored private var unacknowledged: UInt64?
    @ObservationIgnored private var fetchingHistory = false
    @ObservationIgnored private var attempt = 0

    init(session: SessionId, server: ServerModel) {
        self.session = session
        self.server = server
    }

    /// The program's title, or else its process and folder.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        let folder = directory.map { ($0.rawValue as NSString).lastPathComponent } ?? ""
        switch (process?.name, folder.isEmpty) {
        case (let name?, false) where process?.isShell == false: return "\(name) — \(folder)"
        case (let name?, _): return name
        case (nil, false): return folder
        case (nil, true): return "Terminal"
        }
    }

    // MARK: Attaching

    /// Shows the session at `size`; while shown, frames keep coming.
    public func attach(size: Size, cell: CellSize) {
        wanted = true
        self.size = size
        cellSize = cell
        guard channel == nil, state != .attaching else {
            resize(to: size, cell: cell)
            return
        }
        guard let client = server?.client else { return }
        attach(with: client)
    }

    private func attach(with client: ServerClient) {
        guard let size else { return }
        self.client = client
        attempt += 1
        let current = attempt
        if case .ended = state { return }
        state = .attaching
        Task {
            do {
                let attachment = try await client.attach(session: session, size: size)
                guard current == attempt, wanted else {
                    try? await client.detach(channel: attachment.channel)
                    return
                }
                attached(attachment, client: client)
            } catch let error as ClientError {
                guard current == attempt else { return }
                state = error.serverCode == .unknownSession ? .ended("This terminal has ended.") : .detached
            } catch {
                guard current == attempt else { return }
                state = .detached
            }
        }
    }

    private func attached(_ attachment: Attachment, client: ServerClient) {
        channel = attachment.channel
        sentSize = attachment.snapshot.size
        grid = RunGrid(snapshot: attachment.snapshot)
        title = attachment.snapshot.title
        directory = attachment.snapshot.directory
        process = attachment.process
        unacknowledged = nil
        scrolledBack = false
        state = .attached
        if let cellSize { try? client.sendCellSize(channel: attachment.channel, cellSize) }
        if let size, size != attachment.snapshot.size { sendResize(size) }
        redraw(GridChanges(full: true, cursor: true))
        let events = attachment.events
        let current = attempt
        Task { [weak self] in
            for await event in events {
                guard let self, current == self.attempt else { return }
                self.handle(event)
            }
        }
    }

    /// Stops receiving frames, keeping the last screen to show meanwhile.
    public func detach() {
        wanted = false
        attempt += 1
        guard let channel, let client else { return }
        self.channel = nil
        if case .ended = state {} else { state = .detached }
        Task { try? await client.detach(channel: channel) }
    }

    func connectionLost() {
        attempt += 1
        channel = nil
        client = nil
        if case .ended = state { return }
        state = .detached
    }

    func connectionRestored(_ client: ServerClient) {
        guard wanted, channel == nil else { return }
        attach(with: client)
    }

    // MARK: Frames

    private func handle(_ event: ChannelEvent) {
        switch event {
        case .frame(let frame):
            guard grid != nil else { return }
            grid?.apply(frame)
            unacknowledged = frame.seq
            if scrolledBack, grid?.scrollOffset == 0 { scrolledBack = false }
            redraw(grid?.takeChanges() ?? GridChanges(full: true))
        case .metadata(let metadata):
            handle(metadata)
        case .ended(let reason):
            channel = nil
            state = .ended(Self.describe(reason))
            grid?.cursor.visible = false
            redraw(GridChanges(cursor: true))
        case .resized(let size):
            // Another device took the size; take it back on the next input.
            sentSize = size
            if self.size != size { sentSize = nil }
        }
    }

    private func handle(_ metadata: MetadataEvent) {
        switch metadata {
        case .title(let value): title = value
        case .directory(let value): directory = value
        case .foregroundProcess(let value): process = value
        case .bell: onBell?()
        case .inputModes(let modes): inputModes = modes
        case .cursorBlinking(let blinking): cursorBlinks = blinking
        case .history(let total):
            if scrolledBack, grid?.historyTotal != total { fetchNewestHistory() }
        case .links(let seq, let rows): grid?.links.replace(seq: seq, rows: rows)
        case .screenPrompts(let seq, let rows): grid?.screenPrompts(seq: seq, rows: rows)
        case .clipboardWrite(let text): onClipboardWrite?(text)
        default: break
        }
    }

    private func redraw(_ changes: GridChanges) {
        let drawing = display?.gridChanged(changes) ?? false
        if !drawing { frameDrawn() }
    }

    /// The display drew the latest frame: ask for the next one.
    public func frameDrawn() {
        guard let seq = unacknowledged, let channel, let client else { return }
        unacknowledged = nil
        try? client.ack(channel: channel, seq: seq)
    }

    private static func describe(_ reason: ExitReason) -> String {
        switch reason {
        case .exited(let code): code == 0 ? "Process exited" : "Process exited with code \(code)"
        case .signaled(let signal): "Process ended by signal \(signal)"
        case .serverStopped: "The Tab server stopped"
        default: "Terminal ended"
        }
    }

    // MARK: Size

    /// The view's grid size changed. This device takes the size only while
    /// someone uses it here, so a phone in a pocket never shrinks the Mac's terminal.
    public func resize(to size: Size, cell: CellSize) {
        let changedCell = cellSize != cell
        self.size = size
        cellSize = cell
        guard let channel, let client else { return }
        if changedCell { try? client.sendCellSize(channel: channel, cell) }
        if sentSize != nil, sentSize != size { sendResize(size) }
    }

    private func sendResize(_ size: Size) {
        guard let channel, let client else { return }
        sentSize = size
        grid?.resize(size)
        try? client.resize(channel: channel, size: size)
    }

    // MARK: Input

    public func send(_ input: TerminalInput) {
        guard let channel, let client else { return }
        if let size, sentSize != size { sendResize(size) }
        if scrolledBack { scrollToBottom() }
        try? client.sendInput(channel: channel, input)
    }

    /// Pastes text in chunks the server accepts.
    public func paste(_ text: String) {
        var rest = Substring(text)
        let limit = Int(Limits.maxClipboardText) / 2
        while !rest.isEmpty {
            var end = rest.index(rest.startIndex, offsetBy: min(limit, rest.count))
            while rest[rest.startIndex..<end].utf8.count > Int(Limits.maxClipboardText), end > rest.startIndex {
                end = rest.index(before: end)
            }
            send(.paste(String(rest[rest.startIndex..<end])))
            rest = rest[end...]
        }
    }

    public func clear() {
        guard let channel, let client else { return }
        try? client.clear(channel: channel)
    }

    // MARK: History

    /// Scrolls history by `rows` (positive is older), fetching pages as the
    /// view nears the top of what it has.
    public func scroll(by rows: Int) {
        guard var grid else { return }
        if rows > 0, !grid.historyFresh {
            fetchNewestHistory(thenScroll: rows)
            return
        }
        let moved = grid.scroll(by: rows)
        let needsOlder = grid.needsOlderHistory(margin: Int(grid.size.rows) * 3)
        self.grid = grid
        scrolledBack = grid.scrollOffset > 0
        if moved { redraw(self.grid?.takeChanges() ?? GridChanges(full: true)) }
        if needsOlder { fetchOlderHistory() }
    }

    public func scrollToBottom() {
        guard grid?.scrollOffset ?? 0 > 0 else { return }
        grid?.scrollToBottom()
        scrolledBack = false
        redraw(grid?.takeChanges() ?? GridChanges(full: true))
    }

    private func fetchNewestHistory(thenScroll rows: Int = 0) {
        guard !fetchingHistory, let channel, let client, let grid else { return }
        fetchingHistory = true
        let wanted = max(200, grid.scrollOffset + 2 * Int(grid.size.rows) + 100)
        Task {
            defer { fetchingHistory = false }
            guard let page = try? await client.historyPage(channel: channel, before: nil,
                                                           maxRows: UInt16(min(wanted, Int(Limits.maxHistoryPage)))) else {
                return
            }
            self.grid?.replaceHistory(page)
            fetchingHistory = false
            if rows != 0 { scroll(by: rows) } else { redraw(self.grid?.takeChanges() ?? GridChanges(full: true)) }
        }
    }

    private func fetchOlderHistory() {
        guard !fetchingHistory, let channel, let client, let cursor = grid?.historyCursor else { return }
        fetchingHistory = true
        Task {
            defer { fetchingHistory = false }
            do {
                let page = try await client.historyPage(channel: channel, before: cursor,
                                                        maxRows: UInt16(Limits.maxHistoryPage))
                grid?.fetchOlder(page)
            } catch let error as ClientError where error.serverCode == .staleHistoryCursor {
                fetchingHistory = false
                fetchNewestHistory()
            } catch {}
        }
    }
}
