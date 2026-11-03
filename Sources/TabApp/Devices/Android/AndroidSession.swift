import Accelerate
import AppKit
import IOSurface
import TabCore

/// One device pane's link to an Android emulator through its gRPC control
/// API, as Android Studio's embedded emulator uses it: screenshots stream
/// as RGBA frames copied into a surface, and touches and keys are calls
/// sent one at a time so they arrive in order. The pane notices emulators
/// starting and stopping from their discovery files.
@MainActor
final class AndroidSession: DeviceSession {
    let avd: String
    var onStateChange: ((Bool) -> Void)?
    var onSurface: ((IOSurface) -> Void)?
    var onFrame: (() -> Void)?
    var onInputError: ((Error) -> Void)?

    private(set) var isBooted = false
    private(set) var surface: IOSurface?
    let buttons: [DeviceButton] = [.back, .home, .recents, .lock]

    private let queue = DispatchQueue(label: "com.hugocorta.tab.android")
    private var emulator: RunningEmulator?
    private var client: GRPCClient?
    private var screenStream: UInt32?
    private var streaming = false
    private var watcher: DispatchSourceFileSystemObject?
    private var closed = false
    /// Input waiting for the call before it to finish, on `queue`.
    private let input = InputQueue()
    /// How the emulator's display is turned, from the latest frame.
    private var skinTurns = 0
    private var frameSize = CGSize.zero

    init(avd: String) {
        self.avd = avd
    }

    func connect() async throws {
        guard AndroidEmulators.sdk != nil else { throw AndroidError.noSDK }
        watchDiscovery()
        try await refresh()
    }

    /// Finds the emulator running this AVD, if any, and connects to it.
    private func refresh() async throws {
        let avd = avd
        let running = await Task.detached { AndroidEmulators.running().first { $0.avd == avd } }.value
        guard !closed else { return }
        guard let running else {
            disconnect()
            return
        }
        guard running != emulator || client == nil else { return }
        if running.needsUnsupportedAuth { throw AndroidError.unsupportedAuth }
        guard let port = running.grpcPort else { throw AndroidError.noControlAPI }
        disconnect()
        emulator = running
        let client = GRPCClient(port: port, token: running.grpcToken, queue: queue)
        client.onClose = { [weak self] _ in
            DispatchQueue.main.async { self?.clientClosed(client) }
        }
        self.client = client
        queue.async { client.start() }
        setBooted(true)
        if streaming { requestScreen() }
    }

    private func clientClosed(_ closed: GRPCClient) {
        guard client === closed else { return }
        client = nil
        screenStream = nil
        Task { try? await self.refresh() }
    }

    private func disconnect() {
        client?.close()
        client = nil
        screenStream = nil
        emulator = nil
        surface = nil
        setBooted(false)
    }

    private func setBooted(_ booted: Bool) {
        guard booted != isBooted else { return }
        isBooted = booted
        onStateChange?(booted)
    }

    /// Emulators add and remove their discovery files as they start and stop.
    private func watchDiscovery() {
        guard watcher == nil else { return }
        let folder = AndroidEmulators.discoveryFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { try? await self.refresh() }
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        watcher = source
    }

    // MARK: Screen

    func startScreen() {
        streaming = true
        requestScreen()
    }

    func stopScreen() {
        streaming = false
        guard let client, let stream = screenStream else { return }
        screenStream = nil
        // A stream still starting is cancelled when it reports its ID.
        if stream != 0 { queue.async { client.cancel(stream) } }
    }

    private func requestScreen() {
        guard streaming, screenStream == nil, let client else { return }
        var format = ProtobufWriter()
        format.varint(1, 1) // RGBA8888
        let request = format.data
        var surfaceOnQueue = surface
        let call = GRPCClient.Call(onMessage: { [weak self] message in
            guard let frame = AndroidFrame(message), let target = frame.copy(into: surfaceOnQueue) else { return }
            let replaced = target !== surfaceOnQueue
            surfaceOnQueue = target
            DispatchQueue.main.async { self?.frameArrived(target, replaced: replaced, frame: frame) }
        }, onEnd: { [weak self] _ in
            DispatchQueue.main.async { self?.screenEnded() }
        })
        screenStream = 0
        queue.async { [weak self] in
            let id = client.call("streamScreenshot", request, call)
            DispatchQueue.main.async { self?.screenStarted(id, on: client) }
        }
    }

    /// Keeps the stream while the pane still wants it, else cancels it.
    private func screenStarted(_ id: UInt32, on started: GRPCClient) {
        guard client === started, streaming else {
            queue.async { started.cancel(id) }
            return
        }
        screenStream = id
    }

    private func frameArrived(_ target: IOSurface, replaced: Bool, frame: AndroidFrame) {
        skinTurns = frame.turns
        frameSize = CGSize(width: frame.width, height: frame.height)
        if replaced || surface !== target {
            surface = target
            onSurface?(target)
        } else {
            onFrame?()
        }
    }

    private func screenEnded() {
        screenStream = nil
    }

    // MARK: Input

    func send(_ input: [DeviceInput]) {
        guard let client, frameSize.width > 0 else { return }
        // Frames arrive turned upright; touches go to the display unturned.
        let turned = DeviceOrientation(quarterTurns: skinTurns)
        let native = turned.isLandscape ? CGSize(width: frameSize.height, height: frameSize.width) : frameSize
        let calls = input.map { item -> (String, Data) in
            switch item {
            case let .touch(point, down):
                let panel = turned.panelPoint(point)
                var touch = ProtobufWriter()
                touch.int32(1, Int32((panel.x * native.width).rounded()))
                touch.int32(2, Int32((panel.y * native.height).rounded()))
                touch.int32(4, down ? 0x400 : 0)
                var event = ProtobufWriter()
                event.message(1, touch)
                return ("sendTouch", event.data)
            case let .key(usage, down):
                var event = ProtobufWriter()
                event.varint(2, down ? 0 : 1)
                event.int32(3, Int32(0x07_0000 | usage))
                return ("sendKey", event.data)
            }
        }
        enqueue(calls, on: client)
    }

    func press(_ button: DeviceButton) {
        guard let client else { return }
        let key: String
        switch button {
        case .home: key = "GoHome"
        case .back: key = "GoBack"
        case .recents: key = "AppSwitch"
        case .lock: key = "Power"
        }
        var event = ProtobufWriter()
        event.varint(2, 2) // keypress
        event.string(4, key)
        enqueue([("sendKey", event.data)], on: client)
    }

    private func enqueue(_ calls: [(String, Data)], on client: GRPCClient) {
        let input = input
        queue.async { [weak self] in
            input.append(calls, client: client) { error in
                DispatchQueue.main.async { self?.onInputError?(error) }
            }
        }
    }

    // MARK: Controls

    private func running() throws -> RunningEmulator {
        guard let emulator else { throw AndroidError.failed("The emulator isn't running") }
        return emulator
    }

    func boot() async throws {
        try await AndroidEmulators.start(avd)
    }

    func shutDown() async throws { try await AndroidEmulators.shutdown(try running()) }
    func isDark() async throws -> Bool { try await AndroidEmulators.isDark(try running()) }
    func setDark(_ dark: Bool) async throws { try await AndroidEmulators.setDark(try running(), dark) }

    /// Keys always reach the emulator, so it has no keyboard switch.
    var hasHardwareKeyboardSwitch: Bool { false }
    func setHardwareKeyboard(_ connected: Bool) async throws {}

    /// Frames arrive upright, so the view never turns them.
    func orientation() async throws -> DeviceOrientation { .portrait }

    func rotate(by turns: Int) async throws -> DeviceOrientation {
        let emulator = try running()
        for _ in 0..<(((turns % 4) + 4) % 4) { try await AndroidEmulators.rotateLeft(emulator) }
        return .portrait
    }

    func close() {
        closed = true
        watcher?.cancel()
        watcher = nil
        stopScreen()
        client?.close()
        client = nil
    }
}

/// Sends input calls one at a time, so a lift never overtakes its touch.
/// Used only on the session's queue.
private final class InputQueue: @unchecked Sendable {
    private var waiting: [(String, Data)] = []
    private var busy = false
    private var client: GRPCClient?
    private var onError: ((Error) -> Void)?

    func append(_ calls: [(String, Data)], client: GRPCClient, onError: @escaping (Error) -> Void) {
        if self.client !== client {
            waiting = []
            busy = false
        }
        self.client = client
        self.onError = onError
        waiting += calls
        next()
    }

    private func next() {
        guard !busy, let client, !waiting.isEmpty else { return }
        let (method, request) = waiting.removeFirst()
        busy = true
        client.call(method, request, GRPCClient.Call(onMessage: { _ in }, onEnd: { [weak self] error in
            guard let self else { return }
            busy = false
            if let error {
                waiting = []
                onError?(error)
                return
            }
            next()
        }))
    }
}

/// One screenshot from the emulator: RGBA pixels, turned upright.
struct AndroidFrame {
    var width: Int
    var height: Int
    /// Quarter turns counterclockwise the display is turned by.
    var turns: Int
    var pixels: Data

    /// Reads an `Image` message.
    init?(_ message: Data) {
        let image = ProtobufReader(message)
        let format = image.message(1)
        let width = format?.uint(3) ?? image.uint(2) ?? 0
        let height = format?.uint(4) ?? image.uint(3) ?? 0
        guard width > 0, height > 0, let pixels = image.bytes(4), pixels.count >= Int(width * height * 4) else { return nil }
        self.width = Int(width)
        self.height = Int(height)
        turns = Int(format?.message(2)?.uint(1) ?? 0)
        self.pixels = pixels
    }

    /// Copies the frame into `surface`, or a new BGRA surface when its size
    /// changed. Returns the surface written.
    func copy(into surface: IOSurface?) -> IOSurface? {
        let target: IOSurface
        if let surface, surface.width == width, surface.height == height {
            target = surface
        } else {
            guard let created = IOSurface(properties: [
                .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: 0x4247_5241, // 'BGRA'
            ]) else { return nil }
            target = created
        }
        target.lock(options: [], seed: nil)
        defer { target.unlock(options: [], seed: nil) }
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width * 4)
            var destination = vImage_Buffer(data: target.baseAddress, height: vImagePixelCount(height),
                                            width: vImagePixelCount(width), rowBytes: target.bytesPerRow)
            let rgbaToBGRA: [UInt8] = [2, 1, 0, 3]
            vImagePermuteChannels_ARGB8888(&source, &destination, rgbaToBGRA, vImage_Flags(kvImageNoFlags))
        }
        return target
    }
}
