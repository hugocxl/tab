import Foundation
import Network
import TabCore

/// A minimal gRPC client over cleartext HTTP/2 to a local Android emulator.
/// It encodes request headers as plain HPACK literals and never decodes
/// response headers, since it needs only the messages and where each call
/// ends; the server's header compression state therefore never matters.
/// Everything runs on `queue`.
final class GRPCClient: @unchecked Sendable {
    /// One call's messages, then its end, delivered on `queue`.
    struct Call {
        var onMessage: (Data) -> Void
        /// `nil` when the call ended normally.
        var onEnd: (GRPCError?) -> Void
    }

    let queue: DispatchQueue
    /// The connection closed; every open call has ended.
    var onClose: ((GRPCError) -> Void)?

    private let connection: NWConnection
    private let authority: String
    private let token: String?
    private var buffer = Data()
    private var calls: [UInt32: Call] = [:]
    private var messages: [UInt32: Data] = [:]
    private var nextStream: UInt32 = 1
    private var closed = false
    private var ready = false
    private var pending: [Data] = []

    init(port: UInt16, token: String?, queue: DispatchQueue) {
        self.queue = queue
        self.token = token
        authority = "127.0.0.1:\(port)"
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? 8554, using: .tcp)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                ready = true
                let queued = pending
                pending = []
                for data in queued { write(data) }
                receive()
            case .failed(let error):
                close(.connection(error.localizedDescription))
            case .cancelled:
                close(.connection("closed"))
            default:
                break
            }
        }
        connection.start(queue: queue)
        var preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        // No server push; a large window so screenshots stream without
        // waiting on window updates.
        var settings = Data()
        Self.appendSetting(0x2, 0, to: &settings)
        Self.appendSetting(0x4, Self.window, to: &settings)
        preface.append(Self.frame(type: .settings, flags: 0, stream: 0, payload: settings))
        preface.append(Self.windowUpdate(stream: 0, increment: Self.window - 65_535))
        send(preface)
    }

    /// Starts a call to `method` on the emulator controller with one request.
    /// Returns its stream, for `cancel`.
    @discardableResult
    func call(_ method: String, _ request: Data, _ call: Call) -> UInt32 {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed else {
            call.onEnd(.connection("closed"))
            return 0
        }
        let stream = nextStream
        nextStream += 2
        calls[stream] = call
        var headers = Data()
        for (name, value) in [
            (":method", "POST"), (":scheme", "http"), (":authority", authority),
            (":path", "/android.emulation.control.EmulatorController/\(method)"),
            ("content-type", "application/grpc"), ("te", "trailers"),
        ] + (token.map { [("authorization", "Bearer \($0)")] } ?? []) {
            Self.appendLiteral(name, value, to: &headers)
        }
        var message = Data([0])
        withUnsafeBytes(of: UInt32(request.count).bigEndian) { message.append(contentsOf: $0) }
        message.append(request)
        var out = Self.frame(type: .headers, flags: Flags.endHeaders, stream: stream, payload: headers)
        out.append(contentsOf: Self.dataFrames(stream: stream, message))
        send(out)
        return stream
    }

    /// Ends a call early; its `onEnd` is not called.
    func cancel(_ stream: UInt32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard calls.removeValue(forKey: stream) != nil else { return }
        messages[stream] = nil
        var code = Data()
        withUnsafeBytes(of: UInt32(0x8).bigEndian) { code.append(contentsOf: $0) }
        send(Self.frame(type: .rstStream, flags: 0, stream: stream, payload: code))
    }

    func close() {
        queue.async { [weak self] in self?.close(.connection("closed")) }
    }

    private func close(_ error: GRPCError) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let open = calls
        calls = [:]
        messages = [:]
        for call in open.values { call.onEnd(error) }
        onClose?(error)
    }

    // MARK: Writing

    private func send(_ data: Data) {
        guard ready else {
            pending.append(data)
            return
        }
        write(data)
    }

    private func write(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            self?.close(.connection(error.localizedDescription))
        })
    }

    /// A gRPC message split into DATA frames no larger than the default
    /// frame size, the last ending the stream.
    private static func dataFrames(stream: UInt32, _ message: Data) -> Data {
        var out = Data()
        var offset = message.startIndex
        repeat {
            let end = min(offset + 16_384, message.endIndex)
            let last = end == message.endIndex
            out.append(frame(type: .data, flags: last ? Flags.endStream : 0, stream: stream, payload: message[offset..<end]))
            offset = end
        } while offset < message.endIndex
        return out
    }

    // MARK: Reading

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { buffer.append(data) }
            readFrames()
            if let error {
                close(.connection(error.localizedDescription))
            } else if complete {
                close(.connection("the emulator closed the connection"))
            } else if !closed {
                receive()
            }
        }
    }

    private func readFrames() {
        while buffer.count >= 9 {
            let start = buffer.startIndex
            let length = Int(buffer[start]) << 16 | Int(buffer[start + 1]) << 8 | Int(buffer[start + 2])
            guard buffer.count >= 9 + length else { return }
            let type = buffer[start + 3]
            let flags = buffer[start + 4]
            let stream = (UInt32(buffer[start + 5]) << 24 | UInt32(buffer[start + 6]) << 16
                | UInt32(buffer[start + 7]) << 8 | UInt32(buffer[start + 8])) & 0x7FFF_FFFF
            let payload = buffer[(start + 9)..<(start + 9 + length)]
            buffer = buffer[(start + 9 + length)...]
            handle(type: FrameType(rawValue: type), flags: flags, stream: stream, payload: Data(payload))
            if closed { return }
        }
    }

    private func handle(type: FrameType?, flags: UInt8, stream: UInt32, payload: Data) {
        switch type {
        case .data:
            var body = payload
            if flags & Flags.padded != 0, let pad = body.first {
                body = body.dropFirst().dropLast(Int(pad))
            }
            if !payload.isEmpty {
                send(Self.windowUpdate(stream: 0, increment: UInt32(payload.count))
                    + (flags & Flags.endStream == 0 ? Self.windowUpdate(stream: stream, increment: UInt32(payload.count)) : Data()))
            }
            messages[stream, default: Data()].append(body)
            deliverMessages(stream)
            if flags & Flags.endStream != 0 { end(stream, nil) }
        case .headers:
            // Trailers end a call; a status other than OK arrives in them,
            // and a call that ends without a message for a unary request is
            // reported by its caller.
            if flags & Flags.endStream != 0 { end(stream, nil) }
        case .rstStream:
            end(stream, .reset)
        case .settings:
            if flags & Flags.ack == 0 { send(Self.frame(type: .settings, flags: Flags.ack, stream: 0, payload: Data())) }
        case .ping:
            if flags & Flags.ack == 0 { send(Self.frame(type: .ping, flags: Flags.ack, stream: 0, payload: payload)) }
        case .goAway:
            close(.connection("the emulator ended the connection"))
        default:
            break
        }
    }

    /// Hands over each complete length-prefixed message.
    private func deliverMessages(_ stream: UInt32) {
        guard var pending = messages[stream], let call = calls[stream] else {
            messages[stream] = nil
            return
        }
        while pending.count >= 5 {
            let start = pending.startIndex
            let length = Int(pending[start + 1]) << 24 | Int(pending[start + 2]) << 16
                | Int(pending[start + 3]) << 8 | Int(pending[start + 4])
            guard pending.count >= 5 + length else { break }
            let message = Data(pending[(start + 5)..<(start + 5 + length)])
            pending = Data(pending[(start + 5 + length)...])
            call.onMessage(message)
        }
        messages[stream] = pending
    }

    private func end(_ stream: UInt32, _ error: GRPCError?) {
        messages[stream] = nil
        calls.removeValue(forKey: stream)?.onEnd(error)
    }

    // MARK: Framing

    private enum FrameType: UInt8 {
        case data = 0x0, headers = 0x1, rstStream = 0x3, settings = 0x4, ping = 0x6, goAway = 0x7, windowUpdate = 0x8
    }

    private enum Flags {
        static let endStream: UInt8 = 0x1
        static let ack: UInt8 = 0x1
        static let endHeaders: UInt8 = 0x4
        static let padded: UInt8 = 0x8
    }

    private static let window: UInt32 = 0x7FFF_FFFF

    private static func frame(type: FrameType, flags: UInt8, stream: UInt32, payload: Data) -> Data {
        var out = Data(capacity: 9 + payload.count)
        let length = UInt32(payload.count)
        out.append(contentsOf: [UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF), type.rawValue, flags])
        withUnsafeBytes(of: (stream & 0x7FFF_FFFF).bigEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    private static func windowUpdate(stream: UInt32, increment: UInt32) -> Data {
        var payload = Data()
        withUnsafeBytes(of: increment.bigEndian) { payload.append(contentsOf: $0) }
        return frame(type: .windowUpdate, flags: 0, stream: stream, payload: payload)
    }

    private static func appendSetting(_ id: UInt16, _ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: id.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    /// A header as an HPACK literal that is never indexed, with a new name
    /// and no Huffman coding.
    static func appendLiteral(_ name: String, _ value: String, to data: inout Data) {
        data.append(0x00)
        for string in [name, value] {
            let bytes = Data(string.utf8)
            appendInteger(bytes.count, prefixBits: 7, to: &data)
            data.append(bytes)
        }
    }

    /// An HPACK integer in a byte whose top bits are clear.
    static func appendInteger(_ value: Int, prefixBits: Int, to data: inout Data) {
        let limit = (1 << prefixBits) - 1
        guard value >= limit else {
            data.append(UInt8(value))
            return
        }
        data.append(UInt8(limit))
        var rest = value - limit
        while rest >= 0x80 {
            data.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        data.append(UInt8(rest))
    }
}

enum GRPCError: Error, Equatable, CustomStringConvertible {
    case connection(String)
    case reset

    var description: String {
        switch self {
        case .connection(let reason): return "Lost the emulator: \(reason)"
        case .reset: return "The emulator refused the request"
        }
    }
}
