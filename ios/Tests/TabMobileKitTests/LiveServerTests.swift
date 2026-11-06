import Foundation
import TabProtocol
import TabShared
import XCTest
@testable import TabMobileKit

/// Pairs with a real `tabd` and drives a terminal through it. Runs only when
/// `scripts/test-live.sh` passes a pairing link in `TAB_PAIR_LINK`.
@MainActor
final class LiveServerTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPairOpenTerminalTabTypeAndReadBack() async throws {
        guard let link = ProcessInfo.processInfo.environment["TAB_PAIR_LINK"], !link.isEmpty else {
            throw XCTSkip("set TAB_PAIR_LINK (scripts/test-live.sh does)")
        }
        let store = PairedServerStore(directory: directory, tokens: MemoryVault())
        let app = AppModel(store: store, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        app.resume()
        let server = try await app.pair(link: link, deviceName: "tabios tests")
        XCTAssertEqual(store.load().map(\.id), [server.id], "the pairing is saved")
        try await until("connected") { server.status == .connected }

        let tab = try server.newTab(.terminal, size: Size(cols: 80, rows: 24))
        try await until("the server starts the terminal") {
            server.tab(tab)?.tab.panes.first?.content.session != nil
        }
        let session = try XCTUnwrap(server.tab(tab)?.tab.panes.first?.content.session)
        let terminal = server.terminal(session)
        let display = RecordingDisplay(terminal)
        terminal.display = display
        terminal.attach(size: Size(cols: 80, rows: 24), cell: CellSize(width: 16, height: 32))
        try await until("attached") { terminal.state == .attached }

        terminal.send(.text("echo tabios-$((40+2))"))
        terminal.send(.key(KeyEvent(key: "enter")))
        try await until("the output arrives") {
            terminal.grid?.screenText(lines: 24).contains("tabios-42") == true
        }
        XCTAssertGreaterThan(display.frames, 0, "frames were drawn and acknowledged")

        try server.closeTab(tab)
        try await until("the tab closes on the server") { server.tab(tab) == nil }
        app.forget(server.id)
    }

    private func until(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting until \(what)")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// Acknowledges every frame as if it had drawn it.
@MainActor
private final class RecordingDisplay: TerminalDisplay {
    private weak var terminal: TerminalController?
    var frames = 0

    init(_ terminal: TerminalController) { self.terminal = terminal }

    func gridChanged(_ changes: GridChanges) -> Bool {
        frames += 1
        DispatchQueue.main.async { [weak terminal] in terminal?.frameDrawn() }
        return true
    }
}

/// Tokens in memory: unhosted test bundles can't use the Keychain.
final class MemoryVault: TokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: Data] = [:]

    func write(_ token: Data, account: String) throws { lock.withLock { tokens[account] = token } }
    func read(account: String) -> Data? { lock.withLock { tokens[account] } }
    func delete(account: String) { lock.withLock { tokens[account] = nil } }
}
