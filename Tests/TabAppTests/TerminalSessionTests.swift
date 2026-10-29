import XCTest
import TabClient
import TabCore
import TabProtocol
@testable import TabApp

/// A server stand-in: one attach whose channel events the test drives.
final class FakeTerminalBackend: TerminalBackend, @unchecked Sendable {
    let lock = NSLock()
    var snapshot: AttachSnapshot
    let events: AsyncStream<ChannelEvent>
    let continuation: AsyncStream<ChannelEvent>.Continuation
    private var _acks: [UInt64] = []
    private var _inputs: [TerminalInput] = []
    private var _colors: [TerminalColors] = []
    private var _cellSizes: [CellSize] = []
    private var _historyRequests: [HistoryCursor?] = []
    var historyPages: [HistoryPage] = []
    var ackWaiter: XCTestExpectation?

    init(snapshot: AttachSnapshot) {
        self.snapshot = snapshot
        (events, continuation) = AsyncStream.makeStream(of: ChannelEvent.self)
    }

    var acks: [UInt64] { lock.withLock { _acks } }
    var inputs: [TerminalInput] { lock.withLock { _inputs } }
    var colors: [TerminalColors] { lock.withLock { _colors } }
    var cellSizes: [CellSize] { lock.withLock { _cellSizes } }
    var historyRequests: [HistoryCursor?] { lock.withLock { _historyRequests } }

    func attachTerminal(session: SessionId, size: Size) async throws -> TerminalAttachment {
        TerminalAttachment(channel: snapshot.channel, snapshot: snapshot, process: nil, events: events)
    }

    func detach(channel: ChannelId) async throws { continuation.finish() }
    func sendInput(channel: ChannelId, _ input: TerminalInput) throws { lock.withLock { _inputs.append(input) } }
    func ack(channel: ChannelId, seq: UInt64) throws {
        lock.withLock { _acks.append(seq) }
        ackWaiter?.fulfill()
    }
    func resize(channel: ChannelId, size: Size) throws {}
    func scroll(channel: ChannelId, _ scroll: ScrollRequest) throws {}
    func sendCellSize(channel: ChannelId, _ cell: CellSize) throws { lock.withLock { _cellSizes.append(cell) } }
    func clear(channel: ChannelId) throws {}
    func historyPage(channel: ChannelId, before: HistoryCursor?, maxRows: UInt16) async throws -> HistoryPage {
        lock.withLock {
            _historyRequests.append(before)
            return historyPages.isEmpty ? HistoryPage(rows: [], totalRows: 0) : historyPages.removeFirst()
        }
    }
    func searchHistory(_ source: SearchSource, query: String, ignoreCase: Bool, before: HistoryCursor?,
                       maxResults: UInt16) async throws -> SearchPage {
        SearchPage(matches: [], totalRows: 0, scannedRows: 0)
    }
    func setTerminalColors(_ colors: TerminalColors) async throws { lock.withLock { _colors.append(colors) } }
    func upload(session: SessionId, name: String, bytes: Data) async throws -> ServerPath { ServerPath("/tmp/" + name) }
}

@MainActor
final class TerminalSessionTests: XCTestCase {
    private typealias F = TerminalFixtures

    private func snapshot(history: [Row] = [], historyCursor: HistoryCursor? = nil, total: UInt64 = 0) -> AttachSnapshot {
        AttachSnapshot(channel: ChannelId(7), size: Size(cols: 20, rows: 3),
                       rows: [Row(index: 0, runs: [F.run("$ ls")])], cursor: Cursor(row: 0, col: 4),
                       title: "zsh", directory: "/tmp", history: history, historyCursor: historyCursor,
                       historyTotal: total)
    }

    private func attached(_ backend: FakeTerminalBackend) async throws -> TerminalSessionController {
        let controller = TerminalSessionController(session: SessionId(), backend: backend,
                                                   settings: F.settings(), palette: TerminalPalette())
        controller.attach()
        for _ in 0..<100 where controller.state != .live { await Task.yield() }
        XCTAssertEqual(controller.state, .live)
        return controller
    }

    func testFramesUpdateTheGridAndAreAcked() async throws {
        let backend = FakeTerminalBackend(snapshot: snapshot())
        let controller = try await attached(backend)
        XCTAssertEqual(controller.title, "zsh")
        XCTAssertEqual(controller.view.grid?.rowText(0), "$ ls")
        XCTAssertEqual(backend.cellSizes, [controller.view.metrics.physicalCellSize])

        let acked = expectation(description: "acked")
        backend.ackWaiter = acked
        backend.continuation.yield(.frame(ScreenFrame(
            size: Size(cols: 20, rows: 3), seq: 1, reset: false,
            rows: [Row(index: 1, runs: [F.run("file.txt")])], cursor: Cursor(row: 2, col: 0))))
        await fulfillment(of: [acked], timeout: 2)
        XCTAssertEqual(backend.acks, [1])
        XCTAssertEqual(controller.view.grid?.rowText(0), "$ ls")
        XCTAssertEqual(controller.view.grid?.rowText(1), "file.txt")
        XCTAssertEqual(controller.view.grid?.cursor.row, 2)

        backend.continuation.yield(.metadata(.title("vim")))
        backend.continuation.yield(.ended(.exited(0)))
        for _ in 0..<100 where controller.state == .live { await Task.yield() }
        XCTAssertEqual(controller.title, "vim")
        XCTAssertEqual(controller.state, .ended(.exited(0)))
        XCTAssertEqual(controller.view.grid?.rowText(1), "file.txt", "the last screen stays")
    }

    func testHiddenPanesKeepTheirScreenAndInputNeedsALiveSession() async throws {
        let backend = FakeTerminalBackend(snapshot: snapshot())
        let controller = try await attached(backend)
        controller.setVisible(false)
        XCTAssertEqual(controller.state, .detached)
        XCTAssertEqual(controller.view.grid?.rowText(0), "$ ls")
        controller.terminalView(controller.view, send: .text("x"))
        XCTAssertTrue(backend.inputs.isEmpty)
    }

    func testScrollingUpPagesOlderHistory() async throws {
        let history = (0..<10).map { Row(index: 0, runs: [F.run("h\($0)")]) }
        let backend = FakeTerminalBackend(snapshot: snapshot(history: history, historyCursor: HistoryCursor(10),
                                                             total: 30))
        backend.historyPages = [HistoryPage(rows: (0..<20).map { Row(index: 0, runs: [F.run("older\($0)")]) },
                                            totalRows: 30)]
        let controller = try await attached(backend)
        controller.scroll(by: 25)
        for _ in 0..<200 where controller.view.grid?.history.count != 30 { await Task.yield() }
        XCTAssertEqual(backend.historyRequests, [HistoryCursor(10)])
        XCTAssertEqual(controller.view.grid?.history.count, 30)
        XCTAssertEqual(controller.view.grid?.scrollOffset, 25, "the scroll waiting for history is applied")
        controller.scrollToBottom()
        XCTAssertEqual(controller.view.grid?.scrollOffset, 0)
    }

    func testColorsGoToTheServerOncePerChange() async throws {
        let backend = FakeTerminalBackend(snapshot: snapshot())
        let controller = try await attached(backend)
        for _ in 0..<100 where backend.colors.isEmpty { await Task.yield() }
        XCTAssertEqual(backend.colors.count, 1)
        controller.apply(settings: F.settings(), palette: TerminalPalette())
        var light = TerminalPalette(dark: false)
        light.foreground = 0x11_22_33
        controller.apply(settings: F.settings(), palette: light)
        for _ in 0..<100 where backend.colors.count < 2 { await Task.yield() }
        XCTAssertEqual(backend.colors.count, 2)
        XCTAssertEqual(backend.colors.last?.foreground, RGB(0x11, 0x22, 0x33))
    }
}
