import CoreVideo
import Foundation
import IOSurface
import TabClient
import TabCore
import TabDevices
import TabProtocol

/// A device on another computer's server: its screen arrives as video,
/// decoded into IOSurface-backed buffers the screen view shows like a local
/// device's surface, and touches, keys and controls go back as requests. The
/// stream runs only between `startScreen` and `stopScreen`.
@MainActor
final class ServerDeviceSession: DeviceSession {
    let device: DeviceRef
    var onStateChange: ((Bool) -> Void)?
    var onSurface: ((IOSurface) -> Void)?
    var onFrame: (() -> Void)?
    var onInputError: ((Error) -> Void)?

    private(set) var isBooted = false
    private(set) var surface: IOSurface?
    private(set) var buttons: [DeviceButton] = []
    private(set) var hasHardwareKeyboardSwitch = false
    /// The most pixels the pane shows, so the stream never sends more.
    var maxPixels: UInt32 = 1920 * 1080

    private let api: () -> ServerAPI?
    private var streaming = false
    private var stream: (api: ServerAPI, channel: ChannelId)?
    private var streamTask: Task<Void, Never>?
    private var generation = 0
    private var closed = false
    private let decoding = DispatchQueue(label: "com.hugocorta.tab.devices.decode", qos: .userInteractive)
    /// Holds the buffer behind `surface`, so its pool doesn't reuse it while shown.
    private var shownBuffer: CVPixelBuffer?

    init(device: DeviceRef, api: @escaping () -> ServerAPI?) {
        self.device = device
        self.api = api
    }

    private func client() throws -> ServerAPI {
        guard let api = api() else { throw ModelError("The server isn't connected") }
        return api
    }

    func connect() async throws {
        try await refresh()
    }

    /// Reads the device's state again, such as after a `devices` change or a
    /// reconnect, and attaches when the pane is showing it.
    func refresh() async throws {
        let devices = try await client().listDevices()
        guard !closed else { return }
        guard let info = devices.first(where: { $0.device == device }) else { throw SimulatorError.notFound }
        buttons = info.buttons
        hasHardwareKeyboardSwitch = info.hardwareKeyboardSwitch
        setBooted(info.booted)
        if streaming, isBooted, stream == nil, streamTask == nil { attach() }
    }

    private func setBooted(_ booted: Bool) {
        guard booted != isBooted else { return }
        isBooted = booted
        if !booted {
            detach()
            surface = nil
            shownBuffer = nil
        }
        onStateChange?(booted)
    }

    // MARK: Screen

    func startScreen() {
        streaming = true
        if isBooted, stream == nil, streamTask == nil { attach() }
    }

    func stopScreen() {
        streaming = false
        detach()
    }

    private func attach() {
        guard let api = api(), !closed else { return }
        generation += 1
        let generation = generation
        let request = AttachDevice(device: device, maxPixels: maxPixels, codecs: [.hevc, .h264])
        streamTask = Task { [weak self] in
            let attachment: DeviceAttachment
            do {
                attachment = try await api.attachDevice(request)
            } catch {
                self?.streamFailed(generation, error)
                return
            }
            guard let self, self.generation == generation, streaming else {
                try? await api.detachDevice(channel: attachment.stream.channel)
                return
            }
            stream = (api, attachment.stream.channel)
            let decoder = VideoDecoder(codec: attachment.stream.codec)
            for await event in attachment.events {
                switch event {
                case .frame(let frame):
                    decode(frame, with: decoder, api: api, channel: attachment.stream.channel, generation: generation)
                case .stopped:
                    setBooted(false)
                }
            }
            guard self.generation == generation else { return }
            stream = nil
            streamTask = nil
        }
    }

    private func streamFailed(_ generation: Int, _ error: Error) {
        guard generation == self.generation else { return }
        streamTask = nil
        Log.devices.error("device stream failed: \(error.message, privacy: .public)")
    }

    private func detach() {
        generation += 1
        streamTask?.cancel()
        streamTask = nil
        guard let (api, channel) = stream else { return }
        stream = nil
        Task { try? await api.detachDevice(channel: channel) }
    }

    /// Decodes off the main thread, acknowledges so the server sends the
    /// next frame, then shows the picture.
    private func decode(_ frame: VideoFrame, with decoder: VideoDecoder, api: ServerAPI, channel: ChannelId,
                        generation: Int) {
        decoding.async { [weak self] in
            let picture: CVPixelBuffer?
            do {
                picture = try decoder.decode(frame)
            } catch {
                picture = nil
                try? api.requestKeyframe(channel: channel)
            }
            try? api.ack(channel: channel, seq: UInt64(frame.seq))
            guard let picture, let surface = CVPixelBufferGetIOSurface(picture)?.takeUnretainedValue() else { return }
            let shown = unsafeBitCast(surface, to: IOSurface.self)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.shownBuffer = picture
                    self.show(shown)
                }
            }
        }
    }

    /// Decoded pictures come from a small pool, so most frames bring
    /// another surface for the view; the same one only marks it changed.
    private func show(_ shown: IOSurface) {
        let same = surface === shown
        surface = shown
        if same {
            onFrame?()
        } else {
            onSurface?(shown)
        }
    }

    // MARK: Input and controls

    func send(_ input: [DeviceInput]) {
        guard !input.isEmpty else { return }
        if let (api, channel) = stream {
            do {
                try api.sendDeviceInput(channel: channel, input)
            } catch {
                onInputError?(error)
            }
            return
        }
        perform(.input(input))
    }

    func press(_ button: DeviceButton) {
        send([.button(button)])
    }

    private func perform(_ action: DeviceAction) {
        Task { [weak self] in
            do {
                _ = try await self?.action(action)
            } catch {
                self?.onInputError?(error)
            }
        }
    }

    @discardableResult
    private func action(_ action: DeviceAction) async throws -> DeviceSettings {
        try await client().deviceAction(action, on: device)
    }

    func boot() async throws { try await action(.boot) }
    func shutDown() async throws { try await action(.shutDown) }
    func isDark() async throws -> Bool { try await action(.readSettings).dark ?? false }
    func setDark(_ dark: Bool) async throws { try await action(.setDark(dark)) }
    func setHardwareKeyboard(_ connected: Bool) async throws { try await action(.setHardwareKeyboard(connected)) }
    func orientation() async throws -> DeviceOrientation { try await action(.readSettings).orientation }
    func rotate(by turns: Int) async throws -> DeviceOrientation { try await action(.rotate(turns: turns)).orientation }

    func close() {
        closed = true
        stopScreen()
        surface = nil
        shownBuffer = nil
    }
}
