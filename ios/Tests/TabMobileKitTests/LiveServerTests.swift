import Foundation
import TabProtocol
import TabShared
import XCTest
@testable import TabMobileKit

/// Pairs with a real `tabd` and drives a terminal and a simulator through
/// it. Runs only when `scripts/test-live.sh` passes a pairing link in
/// `TAB_PAIR_LINK`; its code pairs once, so the tests share the pairing.
@MainActor
final class LiveServerTests: XCTestCase {
    private static var paired: (app: AppModel, server: ServerModel)?

    /// The paired, connected server.
    private func connectedServer() async throws -> ServerModel {
        if let paired = Self.paired { return paired.server }
        guard let link = ProcessInfo.processInfo.environment["TAB_PAIR_LINK"], !link.isEmpty else {
            throw XCTSkip("set TAB_PAIR_LINK (scripts/test-live.sh does)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PairedServerStore(directory: directory, tokens: MemoryVault())
        let app = AppModel(store: store, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        app.resume()
        let server = try await app.pair(link: link, deviceName: "tabios tests")
        XCTAssertEqual(store.load().map(\.id), [server.id], "the pairing is saved")
        try await until("connected") { server.status == .connected }
        Self.paired = (app, server)
        return server
    }

    func testPairOpenTerminalTabTypeAndReadBack() async throws {
        let server = try await connectedServer()

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
    }

    /// The tests run on a simulator of the server's Mac, so a simulator tab
    /// can choose that one and watch itself.
    func testSimulatorTabStreamsAndTakesInput() async throws {
        let server = try await connectedServer()
        guard server.sharesSimulators else { throw XCTSkip("this tabd doesn't share simulators") }

        let tab = try server.newTab(.simulator, size: Size(cols: 80, rows: 24))
        let pane = try XCTUnwrap(server.tab(tab)?.tab.panes.first)
        let simulator = server.simulator(pane.id, choice: SimulatorPane())
        try await until("the simulators are listed", timeout: 30) { simulator.phase == .picking && simulator.simulators != nil }
        let own = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
        let booted = simulator.simulators?.filter(\.booted) ?? []
        let chosen = try XCTUnwrap(booted.first { $0.simulator.id == own } ?? booted.first, "a booted simulator is listed")
        simulator.choose(chosen)
        try await until("the choice reaches the server") {
            if case .simulator(let choice)? = server.tab(tab)?.tab.panes.first?.content {
                return choice.udid == chosen.simulator.id || choice.avd == chosen.simulator.id
            }
            return false
        }
        try await until("live", timeout: 30) { simulator.phase == .live }

        let display = DecodingDisplay(simulator)
        simulator.display = display
        simulator.maxPixels = 640 * 960
        simulator.startScreen()
        try await until("a picture decodes", timeout: 30) { display.pictures > 0 }
        simulator.send([.touch(x: 0.5, y: 0.02, down: true), .touch(x: 0.5, y: 0.02, down: false)])
        let shown = display.pictures
        simulator.rotate(by: 1)
        try await until("it turns", timeout: 30) { simulator.orientation == .landscapeLeft }
        try await until("frames keep coming once acknowledged", timeout: 30) { display.pictures > shown }
        simulator.rotate(by: -1)
        try await until("it turns back", timeout: 30) { simulator.orientation == .portrait }
        XCTAssertEqual(display.failures, 0)
        simulator.stopScreen()

        try server.closeTab(tab)
        try await until("the tab closes on the server") { server.tab(tab) == nil }
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

/// Decodes every frame as the screen does, then acknowledges it.
@MainActor
private final class DecodingDisplay: SimulatorDisplay {
    private weak var simulator: SimulatorController?
    private var decoder: SimulatorVideoDecoder?
    var pictures = 0
    var failures = 0

    init(_ simulator: SimulatorController) { self.simulator = simulator }

    func streamStarted() { decoder = nil }

    func show(_ frame: VideoFrame, codec: VideoCodec) -> Bool {
        if decoder?.codec != codec { decoder = SimulatorVideoDecoder(codec: codec) }
        do {
            _ = try decoder?.decode(frame)
            pictures += 1
        } catch {
            failures += 1
            simulator?.needsKeyframe()
        }
        DispatchQueue.main.async { [weak simulator] in simulator?.frameShown() }
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
