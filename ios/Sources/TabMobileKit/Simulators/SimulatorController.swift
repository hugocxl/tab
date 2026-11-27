import Foundation
import Observation
import TabConnection
import TabProtocol

/// Shows a simulator's screen. The controller calls `show` for each frame;
/// the display calls `frameShown()` once it took it, which lets the server
/// send the next one.
@MainActor
public protocol SimulatorDisplay: AnyObject {
    /// Starts showing `frame`. Returns false when nothing will show it, so
    /// the frame is acknowledged at once.
    func show(_ frame: VideoFrame, codec: VideoCodec) -> Bool
    /// A new stream starts: forget the last one's format and picture.
    func streamStarted()
}

/// One simulator pane as this app shows it: the iOS simulator or Android
/// emulator it chose on its tab's server, that simulator's state, its screen
/// stream while the pane is on screen, and its controls. The simulator keeps
/// running when the pane closes.
@MainActor
@Observable
public final class SimulatorController {
    public enum Phase: Equatable {
        case loading
        /// Choosing a simulator from `simulators`.
        case picking
        case starting
        case live
        /// The chosen simulator is shut down.
        case off
        case failed(String)
        /// The server isn't connected; the pane carries on when it is.
        case offline
        /// The server's Tab is too old to share its simulators.
        case unsupported
    }

    public nonisolated let pane: PaneId
    public private(set) var phase = Phase.loading
    /// What the pane chose, as its tab keeps it.
    public private(set) var choice: SimulatorPane
    /// The server's simulators, for choosing; nil until listed.
    public private(set) var simulators: [SimulatorInfo]?
    /// The chosen simulator as the server last listed it.
    public private(set) var info: SimulatorInfo?
    public private(set) var orientation = SimulatorOrientation.portrait
    /// Whether it shows dark appearance; nil until read.
    public private(set) var dark: Bool?

    @ObservationIgnored public weak var display: SimulatorDisplay?
    /// The most pixels the pane shows, so the stream never sends more.
    @ObservationIgnored public var maxPixels: UInt32 = 1920 * 1080
    /// Called with what went wrong when a control fails.
    @ObservationIgnored public var onError: ((String) -> Void)?

    @ObservationIgnored private weak var server: ServerModel?
    @ObservationIgnored private var picking = false
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var stream: (client: ServerClient, channel: ChannelId)?
    @ObservationIgnored private var attaching = false
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var unacknowledged: UInt32?

    init(pane: PaneId, choice: SimulatorPane, server: ServerModel) {
        self.pane = pane
        self.choice = choice
        self.server = server
        picking = !choice.isChosen
    }

    /// The chosen simulator, by platform.
    public var simulator: SimulatorRef? { Self.ref(choice) }

    /// The pane's title: what it shows, as the Mac titles it.
    public var title: String { phase == .picking ? "Choose Simulator" : choice.name ?? "Simulator" }

    static func ref(_ choice: SimulatorPane) -> SimulatorRef? {
        if let udid = choice.udid { return .iOS(udid) }
        if let avd = choice.avd { return .android(avd) }
        return nil
    }

    // MARK: State

    /// Lists the server's simulators again and follows the chosen one, as
    /// after a `simulators` change or a reconnect. The server model lists
    /// once for all its simulator panes.
    public func refresh() {
        guard let client = server?.client else {
            phase = .offline
            return
        }
        guard client.supports(.simulators) else {
            phase = .unsupported
            return
        }
        server?.listSimulators()
    }

    /// The server listed its simulators.
    func listed(_ list: [SimulatorInfo]) {
        simulators = list
        guard !picking, let simulator else {
            phase = .picking
            return
        }
        guard let found = list.first(where: { $0.simulator == simulator }) else {
            info = nil
            detachStream()
            phase = .failed("\(choice.name ?? "The simulator") is no longer on \(server?.server.name ?? "the Mac").")
            return
        }
        info = found
        guard found.booted else {
            detachStream()
            if phase != .starting { phase = .off }
            return
        }
        if phase != .live {
            phase = .live
            readSettings()
            applyHardwareKeyboard()
        }
        attachIfWanted()
    }

    /// The tab's copy of the pane changed, such as another device choosing
    /// another simulator.
    func paneChanged(_ next: SimulatorPane) {
        guard next != choice else { return }
        let moved = Self.ref(next) != simulator
        choice = next
        guard moved else { return }
        picking = !next.isChosen
        detachStream()
        info = nil
        dark = nil
        orientation = .portrait
        phase = .loading
        refresh()
    }

    func connectionLost() {
        attempt += 1
        stream = nil
        attaching = false
        unacknowledged = nil
        phase = .offline
    }

    func fail(_ error: Error) {
        if server?.client == nil {
            connectionLost()
            return
        }
        if let error = error as? ClientError, error.serverCode == .unsupported {
            phase = .unsupported
            return
        }
        phase = .failed(Self.describe(error))
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? ClientError { return error.description }
        return error.localizedDescription
    }

    // MARK: Choosing

    /// Shows the server's simulators to choose another.
    public func choose() {
        picking = true
        detachStream()
        phase = .picking
        refresh()
    }

    /// Leaves the list for the simulator the pane already shows.
    public func cancelChoosing() {
        guard choice.isChosen else { return }
        picking = false
        phase = .loading
        refresh()
    }

    public var canCancelChoosing: Bool { choice.isChosen }

    /// Shows `simulator` in the pane, on every device, starting it if it is shut down.
    public func choose(_ simulator: SimulatorInfo) {
        var next = SimulatorPane(name: simulator.name, hardwareKeyboard: choice.hardwareKeyboard)
        switch simulator.simulator.platform {
        case .iOS: next.udid = simulator.simulator.id
        case .android: next.avd = simulator.simulator.id
        }
        detachStream()
        picking = false
        choice = next
        info = simulator
        dark = nil
        orientation = .portrait
        save()
        if simulator.booted {
            phase = .loading
            refresh()
        } else {
            start()
        }
    }

    private func save() {
        do {
            try server?.setSimulator(pane, choice)
        } catch {
            onError?(Self.describe(error))
        }
    }

    // MARK: Screen

    /// The pane is on screen: stream its simulator while it is booted.
    public func startScreen() {
        wanted = true
        attachIfWanted()
    }

    /// The pane left the screen: stop streaming.
    public func stopScreen() {
        wanted = false
        detachStream()
    }

    private func attachIfWanted() {
        guard wanted, phase == .live, stream == nil, !attaching, let client = server?.client, let simulator else { return }
        attaching = true
        attempt += 1
        let current = attempt
        let request = AttachSimulator(simulator: simulator, maxPixels: maxPixels, codecs: [.hevc, .h264])
        Task {
            let attachment: SimulatorAttachment
            do {
                attachment = try await client.attachSimulator(request)
            } catch {
                guard current == attempt else { return }
                attaching = false
                fail(error)
                return
            }
            guard current == attempt, wanted else {
                try? await client.detachSimulator(channel: attachment.stream.channel)
                return
            }
            attaching = false
            stream = (client, attachment.stream.channel)
            unacknowledged = nil
            display?.streamStarted()
            for await event in attachment.events {
                guard current == attempt else { return }
                switch event {
                case .frame(let frame):
                    unacknowledged = frame.seq
                    if display?.show(frame, codec: attachment.stream.codec) != true { frameShown() }
                case .stopped:
                    break
                }
            }
            guard current == attempt else { return }
            // The simulator stopped or the stream ended; the listing says which.
            stream = nil
            refresh()
        }
    }

    private func detachStream() {
        attempt += 1
        attaching = false
        unacknowledged = nil
        guard let (client, channel) = stream else { return }
        stream = nil
        Task { try? await client.detachSimulator(channel: channel) }
    }

    /// The display took the latest frame: ask for the next one.
    public func frameShown() {
        guard let seq = unacknowledged, let (client, channel) = stream else { return }
        unacknowledged = nil
        try? client.ack(channel: channel, seq: UInt64(seq))
    }

    /// The display couldn't decode a frame: start again from a keyframe.
    public func needsKeyframe() {
        guard let (client, channel) = stream else { return }
        try? client.requestKeyframe(channel: channel)
    }

    // MARK: Input

    /// Sends touches, keys and buttons, in order.
    public func send(_ input: [SimulatorInput]) {
        guard !input.isEmpty else { return }
        let chunks = stride(from: 0, to: input.count, by: Int(Limits.maxSimulatorInput)).map {
            Array(input[$0 ..< min($0 + Int(Limits.maxSimulatorInput), input.count)])
        }
        if let (client, channel) = stream {
            for chunk in chunks { try? client.sendSimulatorInput(channel: channel, chunk) }
            return
        }
        for chunk in chunks { perform(.input(chunk)) }
    }

    public func press(_ button: SimulatorButton) {
        send([.button(button)])
    }

    /// Types `text` on the simulator's keyboard.
    public func type(_ text: String) {
        send(SimulatorKeyboard.input(typing: text))
    }

    // MARK: Controls

    public func start() {
        guard let client = server?.client, let simulator else { return }
        phase = .starting
        Task {
            do {
                _ = try await client.simulatorAction(.boot, on: simulator)
                guard simulator == self.simulator else { return }
                refresh()
            } catch {
                guard simulator == self.simulator else { return }
                fail(error)
            }
        }
    }

    public func shutDown() {
        perform(.shutDown) { controller, _ in controller.refresh() }
    }

    /// Turns the simulator a quarter counterclockwise for each of `turns`.
    public func rotate(by turns: Int) {
        perform(.rotate(turns: turns)) { controller, settings in controller.orientation = settings.orientation }
    }

    public func setDark(_ dark: Bool) {
        self.dark = dark
        perform(.setDark(dark))
    }

    /// Whether the phone's keys type on the simulator's hardware keyboard
    /// instead of its on-screen one; kept with the pane, as on the Mac.
    public var simulatesHardwareKeyboard: Bool { choice.simulatesHardwareKeyboard }

    public func setHardwareKeyboard(_ connected: Bool) {
        choice.hardwareKeyboard = connected
        save()
        applyHardwareKeyboard()
    }

    /// A simulator starts each boot with its own keyboard setting, so the
    /// pane's is applied whenever it boots.
    private func applyHardwareKeyboard() {
        guard info?.hardwareKeyboardSwitch == true else { return }
        perform(.setHardwareKeyboard(choice.simulatesHardwareKeyboard))
    }

    private func readSettings() {
        perform(.readSettings) { controller, settings in
            controller.dark = settings.dark
            controller.orientation = settings.orientation
        }
    }

    /// The screen as PNG bytes.
    public func screenshot() async throws -> Data {
        guard let client = server?.client, let simulator else { throw ClientError.disconnected }
        return try await client.simulatorScreenshot(simulator)
    }

    /// Runs `action` on the chosen simulator, then `done` with its settings,
    /// unless the pane chose another meanwhile.
    private func perform(_ action: SimulatorAction,
                         then done: @escaping (SimulatorController, SimulatorSettings) -> Void = { _, _ in }) {
        guard let client = server?.client, let simulator else { return }
        Task { [weak self] in
            do {
                let settings = try await client.simulatorAction(action, on: simulator)
                guard let self, simulator == self.simulator else { return }
                done(self, settings)
            } catch {
                guard let self, simulator == self.simulator else { return }
                onError?(Self.describe(error))
            }
        }
    }

    func close() {
        wanted = false
        detachStream()
    }
}
