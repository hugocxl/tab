import Foundation

/// What a frame's payload is.
public struct FrameKind: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// A `Message` on the control channel, a `SessionMessage` on a session channel.
    public static let json = FrameKind(rawValue: 0)
    /// A `ScreenCodec` frame on a session channel.
    public static let screen = FrameKind(rawValue: 1)
    /// Raw bytes for a session's terminal, on its channel.
    public static let input = FrameKind(rawValue: 2)

    /// Kinds from here up are reserved; a reader treats them as corrupt
    /// traffic rather than as a newer build's kind.
    public static let firstReserved: UInt8 = 64

    public var description: String {
        switch self {
        case .json: "json"
        case .screen: "screen"
        case .input: "input"
        default: "kind \(rawValue)"
        }
    }
}

/// One unit on the byte stream:
///
///     u32 big-endian payload length
///     u8  kind
///     u32 big-endian channel
///     payload
public struct Frame: Hashable, Sendable {
    public var kind: FrameKind
    public var channel: ChannelId
    public var payload: Data

    public static let headerSize = 9

    public init(kind: FrameKind, channel: ChannelId, payload: Data) {
        self.kind = kind
        self.channel = channel
        self.payload = payload
    }
}

public enum FramingError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A frame announced a payload over the limit.
    case frameTooLarge(length: Int, limit: Int)
    /// A frame used a reserved kind: the stream is not this protocol.
    case reservedKind(UInt8)
    /// The stream ended inside a frame.
    case truncated(bufferedBytes: Int)
    /// A JSON frame on the wrong channel, or a binary one on the control channel.
    case wrongChannel(kind: FrameKind, channel: ChannelId)

    public var description: String {
        switch self {
        case .frameTooLarge(let length, let limit): "frame of \(length) bytes exceeds \(limit)"
        case .reservedKind(let kind): "reserved frame kind \(kind)"
        case .truncated(let bytes): "stream ended inside a frame (\(bytes) bytes buffered)"
        case .wrongChannel(let kind, let channel): "\(kind) frame on channel \(channel)"
        }
    }
}

/// Builds frames.
public enum FrameEncoder {
    public static func encode(kind: FrameKind, channel: ChannelId, payload: Data,
                              maxFrame: Int = Limits.maxFrame) throws -> Data {
        guard payload.count <= maxFrame else {
            throw FramingError.frameTooLarge(length: payload.count, limit: maxFrame)
        }
        var data = Data(capacity: Frame.headerSize + payload.count)
        let length = UInt32(payload.count)
        let channel = channel.rawValue
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
            kind.rawValue,
            UInt8(truncatingIfNeeded: channel >> 24), UInt8(truncatingIfNeeded: channel >> 16),
            UInt8(truncatingIfNeeded: channel >> 8), UInt8(truncatingIfNeeded: channel),
        ])
        data.append(payload)
        return data
    }

    public static func encode(_ frame: Frame, maxFrame: Int = Limits.maxFrame) throws -> Data {
        try encode(kind: frame.kind, channel: frame.channel, payload: frame.payload, maxFrame: maxFrame)
    }

    /// A control-channel message.
    public static func encode(_ message: Message) throws -> Data {
        try encode(kind: .json, channel: .control, payload: try WireJSON.encode(message))
    }

    public static func encode(_ message: SessionMessage, channel: ChannelId) throws -> Data {
        try encode(kind: .json, channel: channel, payload: try WireJSON.encode(message))
    }

    public static func encode(screen: ScreenFrame, channel: ChannelId) throws -> Data {
        try encode(kind: .screen, channel: channel, payload: ScreenCodec.encode(screen))
    }

    public static func encode(input: Data, channel: ChannelId) throws -> Data {
        try encode(kind: .input, channel: channel, payload: input)
    }
}

/// Splits a byte stream into frames. Feed it chunks of any size, then take
/// frames until `next()` returns `nil`. After an error the stream is corrupt
/// and every later call throws it again; close the connection.
public struct FrameReader: Sendable {
    public let maxFrame: Int
    private var buffer: [UInt8] = []
    private var start = 0
    private var failure: FramingError?

    public init(maxFrame: Int = Limits.maxFrame) {
        self.maxFrame = maxFrame
    }

    /// Bytes received but not yet returned as frames.
    public var bufferedByteCount: Int { buffer.count - start }

    public mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    public mutating func append(_ bytes: UnsafeRawBufferPointer) {
        buffer.append(contentsOf: bytes)
    }

    /// The next complete frame, or `nil` until more bytes arrive.
    public mutating func next() throws -> Frame? {
        if let failure { throw failure }
        guard bufferedByteCount >= Frame.headerSize else { return nil }
        let length = Int(bigEndian32(at: start))
        let kind = buffer[start + 4]
        if kind >= FrameKind.firstReserved {
            return try fail(.reservedKind(kind))
        }
        if length > maxFrame {
            return try fail(.frameTooLarge(length: length, limit: maxFrame))
        }
        guard bufferedByteCount >= Frame.headerSize + length else { return nil }
        let channel = bigEndian32(at: start + 5)
        let payloadStart = start + Frame.headerSize
        let payload = Data(buffer[payloadStart ..< payloadStart + length])
        start = payloadStart + length
        compact()
        return Frame(kind: FrameKind(rawValue: kind), channel: ChannelId(channel), payload: payload)
    }

    /// Appends a chunk and returns every frame it completed.
    public mutating func frames(from chunk: Data) throws -> [Frame] {
        append(chunk)
        var frames: [Frame] = []
        while let frame = try next() { frames.append(frame) }
        return frames
    }

    /// Call at end of stream: throws when it ended inside a frame.
    public func finish() throws {
        if let failure { throw failure }
        if bufferedByteCount > 0 { throw FramingError.truncated(bufferedBytes: bufferedByteCount) }
    }

    private mutating func fail(_ error: FramingError) throws -> Frame? {
        failure = error
        buffer = []
        start = 0
        throw error
    }

    private func bigEndian32(at index: Int) -> UInt32 {
        UInt32(buffer[index]) << 24 | UInt32(buffer[index + 1]) << 16 | UInt32(buffer[index + 2]) << 8
            | UInt32(buffer[index + 3])
    }

    private mutating func compact() {
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: buffer.capacity <= 1 << 20)
            start = 0
        } else if start >= 64 * 1024, start * 2 >= buffer.count {
            buffer.removeSubrange(0 ..< start)
            start = 0
        }
    }
}

// MARK: - Decoding frames

/// A frame decoded by its kind and channel.
public enum IncomingFrame: Hashable, Sendable {
    /// A control-channel message.
    case message(Message)
    case session(ChannelId, SessionMessage)
    case screen(ChannelId, ScreenFrame)
    case input(ChannelId, Data)
    /// A kind from a newer build; ignore it.
    case other(Frame)
}

extension Frame {
    /// Decodes the payload by kind and channel. Throws on malformed payloads
    /// and on frames on the wrong channel.
    public func decoded() throws -> IncomingFrame {
        switch kind {
        case .json where channel.isControl:
            return .message(try WireJSON.decode(Message.self, from: payload))
        case .json:
            return .session(channel, try WireJSON.decode(SessionMessage.self, from: payload))
        case .screen, .input:
            if channel.isControl { throw FramingError.wrongChannel(kind: kind, channel: channel) }
            return kind == .screen ? .screen(channel, try ScreenCodec.decode(payload)) : .input(channel, payload)
        default:
            return .other(self)
        }
    }
}
