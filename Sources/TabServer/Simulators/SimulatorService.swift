import Foundation
import IOSurface
import TabSimulators
import TabProtocol

/// The server's simulators and emulators: their listing, their controls,
/// and their screens streamed to clients as video. Each attached simulator has
/// one source following its screen, shared by every channel showing it; each
/// channel has its own encoder and credit, so a slow client never slows a
/// fast one. Simulators keep running when clients detach or the server stops.
///
/// Simulator sessions live on the main actor; `tabd` serves the main queue,
/// where CoreSimulator delivers its callbacks. Encoding runs on each
/// channel's queue, `simctl` and `adb` off the request path.
public final class SimulatorService: @unchecked Sendable {
    private let events: ServiceEvents
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private lazy var catalog = SimulatorCatalog { [weak self] in self?.simulatorsChanged() }

    /// Main actor only.
    private var sources: [SimulatorRef: Source] = [:]
    /// Streams by connection and channel. Behind `lock`.
    private var streams: [StreamKey: Streamer] = [:]

    private struct StreamKey: Hashable {
        let connection: Int
        let channel: ChannelId
    }

    public init(events: ServiceEvents) {
        self.events = events
    }

    private func simulatorsChanged() {
        let revision = lock.withLock {
            self.revision += 1
            return self.revision
        }
        events.broadcast(.changed(topic: .simulators, revision: revision))
    }

    // MARK: Requests

    func list() async -> [SimulatorInfo] {
        catalog.watch()
        return await catalog.list()
    }

    func perform(_ action: SimulatorAction, on simulator: SimulatorRef) async throws -> SimulatorSettings {
        switch action {
        case .boot:
            try await control(simulator) { try await $0.boot() }
        case .shutDown:
            try await control(simulator) { try await $0.shutDown() }
        case .setDark(let dark):
            try await control(simulator) { try await $0.setDark(dark) }
        case .rotate(let turns):
            _ = try await control(simulator) { try await $0.rotate(by: turns) }
        case .setHardwareKeyboard(let connected):
            try await control(simulator) { try await $0.setHardwareKeyboard(connected) }
        case .input(let input):
            try await send(input, to: simulator)
        case .type(let text):
            try await send(SimulatorKeyboard.input(typing: text), to: simulator)
        case .openURL(let url):
            try await LocalSimulators.openURL(url, on: simulator)
        case .readSettings:
            break
        case .unknown:
            throw ServiceError.unsupportedRequest
        }
        return await settings(simulator)
    }

    func screenshot(_ simulator: SimulatorRef) async throws -> Data {
        let surface = try await withScreen(simulator) { _, surface in surface }
        guard let png = LocalSimulators.png(surface) else { throw ServiceError(.badRequest, "The screen couldn't be read") }
        return png
    }

    /// Starts streaming `request.simulator` on `channel`, once its screen has a surface.
    func attach(_ request: AttachSimulator, channel: ChannelId, connection: ClientConnection) async throws -> SimulatorStream {
        guard let codec = request.codecs.first(where: { $0 == .h264 || $0 == .hevc }) else {
            throw ServiceError(.unsupported, "No video codec in common")
        }
        let streamer = Streamer(channel: channel, connection: connection, codec: codec,
                                maxPixels: Int(request.maxPixels))
        lock.withLock { streams[StreamKey(connection: connection.number, channel: channel)] = streamer }
        do {
            let surface = try await withScreen(request.simulator, keep: streamer) { _, surface in surface }
            let size = streamer.prepare(surface)
            return SimulatorStream(channel: channel, codec: codec, width: UInt16(clamping: size.width),
                                   height: UInt16(clamping: size.height))
        } catch {
            detach(channel, connection: connection)
            throw error
        }
    }

    func detach(_ channel: ChannelId, connection: ClientConnection) {
        guard let streamer = lock.withLock({ streams.removeValue(forKey: StreamKey(connection: connection.number, channel: channel)) })
        else { return }
        streamer.stop()
        connection.outbox.closeVideo(channel)
        Task { @MainActor in self.release(streamer) }
    }

    func input(_ input: [SimulatorInput], on channel: ChannelId, from connection: ClientConnection) {
        guard let streamer = streamer(channel, connection) else { return }
        Task { @MainActor in streamer.source?.session.send(input) }
    }

    /// The attach reply for `channel` is queued, so its frames may follow.
    func begin(_ channel: ChannelId, connection: ClientConnection) {
        streamer(channel, connection)?.pump?.begin()
    }

    func requestKeyframe(on channel: ChannelId, from connection: ClientConnection) {
        streamer(channel, connection)?.pump?.screenChanged(keyframe: true)
    }

    func disconnected(_ connection: ClientConnection) {
        let gone = lock.withLock { () -> [Streamer] in
            let keys = streams.keys.filter { $0.connection == connection.number }
            return keys.compactMap { streams.removeValue(forKey: $0) }
        }
        for streamer in gone { streamer.stop() }
        Task { @MainActor in for streamer in gone { self.release(streamer) } }
    }

    private func streamer(_ channel: ChannelId, _ connection: ClientConnection) -> Streamer? {
        lock.withLock { streams[StreamKey(connection: connection.number, channel: channel)] }
    }

    // MARK: Sources

    /// One simulator's live session, shared by its streams.
    @MainActor
    private final class Source {
        let simulator: SimulatorRef
        let session: SimulatorSession
        var streamers: [ObjectIdentifier: Streamer] = [:]
        /// Holds the screen for a request without a stream, such as a screenshot.
        var holds = 0
        var connecting: Task<Void, Error>?

        init(simulator: SimulatorRef) {
            self.simulator = simulator
            session = LocalSimulators.session(for: simulator)
        }

        var isIdle: Bool { streamers.isEmpty && holds == 0 }
    }

    @MainActor
    private func source(_ simulator: SimulatorRef) async throws -> Source {
        if let existing = sources[simulator], let connecting = existing.connecting {
            try await connecting.value
            return existing
        }
        let source = Source(simulator: simulator)
        sources[simulator] = source
        source.session.onSurface = { [weak source] surface in
            guard let source else { return }
            for streamer in source.streamers.values { streamer.surfaceChanged(surface) }
        }
        source.session.onFrame = { [weak source] in
            guard let source else { return }
            for streamer in source.streamers.values { streamer.drew() }
        }
        source.session.onStateChange = { [weak self, weak source] booted in
            guard let self, let source, !booted else { return }
            stopped(source)
        }
        source.session.onInputError = { error in ServerLog.error("simulator input failed: \(error)") }
        let session = source.session
        let connecting = Task { @MainActor in try await session.connect() }
        source.connecting = connecting
        do {
            try await connecting.value
        } catch {
            close(source)
            throw ServiceError(.badRequest, "\(error)")
        }
        return source
    }

    /// Runs `body` with the simulator's current surface, starting its screen
    /// for the call when nothing streams it. `keep` joins the source's streams.
    @MainActor
    private func withScreen<T>(_ simulator: SimulatorRef, keep streamer: Streamer? = nil,
                               _ body: (Source, IOSurface) async throws -> T) async throws -> T {
        let source = try await source(simulator)
        guard source.session.isBooted else {
            if source.isIdle { close(source) }
            throw ServiceError(.badRequest, "The simulator isn't running")
        }
        source.holds += 1
        if let streamer {
            streamer.source = source
            source.streamers[ObjectIdentifier(streamer)] = streamer
        }
        source.session.startScreen()
        defer {
            source.holds -= 1
            if source.isIdle { close(source) }
        }
        let deadline = Date().addingTimeInterval(5)
        while source.session.surface == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let surface = source.session.surface else {
            throw ServiceError(.badRequest, "The simulator's screen didn't appear")
        }
        return try await body(source, surface)
    }

    /// Runs a control on the simulator's session, sharing a live one.
    @MainActor
    private func control<T>(_ simulator: SimulatorRef, _ body: (SimulatorSession) async throws -> T) async throws -> T {
        let source = try await source(simulator)
        source.holds += 1
        defer {
            source.holds -= 1
            if source.isIdle { close(source) }
        }
        return try await body(source.session)
    }

    @MainActor
    private func send(_ input: [SimulatorInput], to simulator: SimulatorRef) async throws {
        try await withScreen(simulator) { source, _ in
            source.session.send(input)
            // Input goes out on the simulator's queue; let it leave before the screen stops.
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @MainActor
    private func settings(_ simulator: SimulatorRef) async -> SimulatorSettings {
        guard let source = try? await source(simulator) else { return SimulatorSettings(booted: false) }
        source.holds += 1
        defer {
            source.holds -= 1
            if source.isIdle { close(source) }
        }
        guard source.session.isBooted else { return SimulatorSettings(booted: false) }
        let dark = try? await source.session.isDark()
        let orientation = (try? await source.session.orientation()) ?? .portrait
        return SimulatorSettings(booted: true, dark: dark, orientation: orientation)
    }

    /// The simulator shut down: its streams end.
    @MainActor
    private func stopped(_ source: Source) {
        let ended = Array(source.streamers.values)
        source.streamers = [:]
        for streamer in ended {
            lock.withLock { streams[streamer.key] = nil }
            streamer.stop()
            streamer.connection?.outbox.push(.simulatorStopped, on: streamer.channel)
            streamer.connection?.outbox.closeVideo(streamer.channel, flush: true)
        }
        if source.isIdle { close(source) }
        simulatorsChanged()
    }

    @MainActor
    private func release(_ streamer: Streamer) {
        guard let source = streamer.source else { return }
        source.streamers[ObjectIdentifier(streamer)] = nil
        streamer.source = nil
        if source.isIdle { close(source) }
    }

    @MainActor
    private func close(_ source: Source) {
        guard sources[source.simulator] === source else { return }
        sources[source.simulator] = nil
        source.session.close()
    }

    // MARK: Streams

    /// One channel's stream of a simulator's screen.
    private final class Streamer: @unchecked Sendable {
        let channel: ChannelId
        weak var connection: ClientConnection?
        let key: StreamKey
        let codec: VideoCodec
        let maxPixels: Int
        /// Main actor only.
        var source: Source?
        private let queue: DispatchQueue
        private(set) var pump: VideoPump?
        /// On `queue`.
        private var surface: IOSurface?
        private var encoder: VideoEncoder?
        private var bitrate = BitrateControl()

        init(channel: ChannelId, connection: ClientConnection, codec: VideoCodec, maxPixels: Int) {
            self.channel = channel
            self.connection = connection
            key = StreamKey(connection: connection.number, channel: channel)
            self.codec = codec
            self.maxPixels = maxPixels
            queue = DispatchQueue(label: "tab.simulator.\(connection.number).\(channel)", qos: .userInteractive)
        }

        /// Sets up the encoder for `surface` and opens the channel; returns the stream's size.
        func prepare(_ surface: IOSurface) -> (width: Int, height: Int) {
            let size = VideoEncoder.size(width: surface.width, height: surface.height, maxPixels: maxPixels)
            queue.sync {
                self.surface = surface
                encoder = try? VideoEncoder(codec: codec, width: size.width, height: size.height)
            }
            guard let outbox = connection?.outbox else { return size }
            let pump = VideoPump(channel: channel, queue: queue, outbox: outbox, encode: { [weak self] keyframe in
                try self?.encode(keyframe: keyframe)
            }, acknowledged: { [weak self] seconds in
                guard let self else { return }
                encoder?.setBitrate(bitrate.acknowledged(after: seconds))
            })
            self.pump = pump
            pump.open()
            return size
        }

        func surfaceChanged(_ surface: IOSurface) {
            queue.async { [self] in
                let size = VideoEncoder.size(width: surface.width, height: surface.height, maxPixels: maxPixels)
                if encoder?.width != size.width || encoder?.height != size.height {
                    encoder = try? VideoEncoder(codec: codec, width: size.width, height: size.height,
                                                bitrate: bitrate.bitrate)
                }
                self.surface = surface
                pump?.screenChanged(keyframe: true)
            }
        }

        func drew() {
            pump?.screenChanged()
        }

        func stop() {
            pump?.stop()
        }

        /// On `queue`.
        private func encode(keyframe: Bool) throws -> VideoFrame? {
            guard let surface, let encoder, let encoded = try encoder.encode(surface, keyframe: keyframe) else { return nil }
            return VideoFrame(seq: 0, keyframe: encoded.keyframe, width: UInt16(clamping: encoder.width),
                              height: UInt16(clamping: encoder.height), parameterSets: encoded.parameterSets,
                              sample: encoded.sample)
        }
    }
}
