import Foundation

// Simulators and emulators belong to a server, like its terminals. A client
// lists them, controls them with `deviceAction`, and attaches one to get its
// screen as `video` frames on a channel, one frame in flight like a
// terminal's screen: the client acknowledges each frame with `ack`, and
// sends touches and keys as `deviceInput` on the same channel.

/// The device platforms a server shows.
public enum DevicePlatform: String, Hashable, Codable, Sendable {
    case iOS
    case android
}

/// Names one device on a server: a simulator's UDID or an AVD's name.
public struct DeviceRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public var platform: DevicePlatform
    public var id: String

    public init(platform: DevicePlatform, id: String) {
        self.platform = platform
        self.id = id
    }

    public static func simulator(_ udid: String) -> DeviceRef { DeviceRef(platform: .iOS, id: udid) }
    public static func emulator(_ avd: String) -> DeviceRef { DeviceRef(platform: .android, id: avd) }

    public var description: String { id }
}

/// A hardware or navigation button a device has.
public enum DeviceButton: String, Hashable, Codable, Sendable, CaseIterable {
    case home, back, recents, lock
}

/// One device on a server, as its picker lists it.
public struct DeviceInfo: Hashable, Codable, Sendable {
    public var device: DeviceRef
    public var name: String
    /// The OS it runs, such as "iOS 27.0" or "Android API 35".
    public var runtime: String
    public var booted: Bool
    public var isTablet: Bool
    /// The buttons it has.
    public var buttons: [DeviceButton]
    /// Whether it can connect and disconnect a hardware keyboard.
    public var hardwareKeyboardSwitch: Bool

    public init(device: DeviceRef, name: String, runtime: String, booted: Bool, isTablet: Bool = false,
                buttons: [DeviceButton], hardwareKeyboardSwitch: Bool) {
        self.device = device
        self.name = name
        self.runtime = runtime
        self.booted = booted
        self.isTablet = isTablet
        self.buttons = buttons
        self.hardwareKeyboardSwitch = hardwareKeyboardSwitch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try container.decode(DeviceRef.self, forKey: .device)
        name = try container.decode(String.self, forKey: .name)
        runtime = try container.decodeIfPresent(String.self, forKey: .runtime) ?? ""
        booted = try container.decodeIfPresent(Bool.self, forKey: .booted) ?? false
        isTablet = try container.decodeIfPresent(Bool.self, forKey: .isTablet) ?? false
        buttons = (try? container.decodeIfPresent([DeviceButton].self, forKey: .buttons)) ?? []
        hardwareKeyboardSwitch = try container.decodeIfPresent(Bool.self, forKey: .hardwareKeyboardSwitch) ?? false
    }
}

/// Which way up a device is held. Its screen stays in the panel's native
/// portrait; the system draws rotated content into it.
public enum DeviceOrientation: String, Hashable, Codable, Sendable, CaseIterable {
    case portrait
    case landscapeLeft
    case portraitUpsideDown
    case landscapeRight

    /// Quarter turns counterclockwise from portrait, as the device is held.
    public var quarterTurns: Int {
        switch self {
        case .portrait: 0
        case .landscapeLeft: 1
        case .portraitUpsideDown: 2
        case .landscapeRight: 3
        }
    }

    public init(quarterTurns: Int) {
        let turns = ((quarterTurns % 4) + 4) % 4
        self = Self.allCases.first { $0.quarterTurns == turns } ?? .portrait
    }

    public var isLandscape: Bool { quarterTurns % 2 == 1 }

    /// A point on the screen as the user sees it, as fractions of its width
    /// and height from the top left, on the panel's portrait surface.
    public func panelPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        switch self {
        case .portrait: (x, y)
        case .landscapeLeft: (1 - y, x)
        case .portraitUpsideDown: (1 - x, 1 - y)
        case .landscapeRight: (y, 1 - x)
        }
    }
}

/// Input for a device, in order.
public enum DeviceInput: Hashable, Codable, Sendable {
    /// One finger at a point on the panel's portrait screen, as fractions of
    /// its width and height from the top left; `down` is false for the lift.
    case touch(x: Double, y: Double, down: Bool)
    /// A USB keyboard usage (HID page 7).
    case key(usage: UInt32, down: Bool)
    /// Presses and releases a button.
    case button(DeviceButton)
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "touch": self = .touch(x: try c("x"), y: try c("y"), down: try c("down"))
        case "key": self = .key(usage: try c("usage"), down: try c("down"))
        case "button": self = .button(try c("button"))
        default: self = .unknown(c.type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .touch(let x, let y, let down):
            var c = try TaggedEncoding(encoder, "touch")
            try c(x, "x")
            try c(y, "y")
            try c(down, "down")
        case .key(let usage, let down):
            var c = try TaggedEncoding(encoder, "key")
            try c(usage, "usage")
            try c(down, "down")
        case .button(let button):
            var c = try TaggedEncoding(encoder, "button")
            try c(button, "button")
        case .unknown(let type): try TaggedEncoding(encoder, type)
        }
    }
}

/// Something a client asks a device to do. Every action replies with the
/// device's settings as they are afterwards.
public enum DeviceAction: Hashable, Codable, Sendable {
    /// Starts it; replies once it launched, not booted.
    case boot
    case shutDown
    case setDark(Bool)
    /// Turns it a quarter counterclockwise per turn.
    case rotate(turns: Int)
    case setHardwareKeyboard(Bool)
    /// Sends input without attaching, such as `tab device tap`.
    case input([DeviceInput])
    /// Types text as key presses.
    case type(String)
    case openURL(String)
    case readSettings
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "boot": self = .boot
        case "shutDown": self = .shutDown
        case "setDark": self = .setDark(try c("dark"))
        case "rotate": self = .rotate(turns: try c("turns"))
        case "setHardwareKeyboard": self = .setHardwareKeyboard(try c("connected"))
        case "input": self = .input(try c("input"))
        case "type": self = .type(try c("text"))
        case "openURL": self = .openURL(try c("url"))
        case "readSettings": self = .readSettings
        default: self = .unknown(c.type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .boot: try TaggedEncoding(encoder, "boot")
        case .shutDown: try TaggedEncoding(encoder, "shutDown")
        case .setDark(let dark):
            var c = try TaggedEncoding(encoder, "setDark")
            try c(dark, "dark")
        case .rotate(let turns):
            var c = try TaggedEncoding(encoder, "rotate")
            try c(turns, "turns")
        case .setHardwareKeyboard(let connected):
            var c = try TaggedEncoding(encoder, "setHardwareKeyboard")
            try c(connected, "connected")
        case .input(let input):
            var c = try TaggedEncoding(encoder, "input")
            try c(input, "input")
        case .type(let text):
            var c = try TaggedEncoding(encoder, "type")
            try c(text, "text")
        case .openURL(let url):
            var c = try TaggedEncoding(encoder, "openURL")
            try c(url, "url")
        case .readSettings: try TaggedEncoding(encoder, "readSettings")
        case .unknown(let type): try TaggedEncoding(encoder, type)
        }
    }
}

/// A device's settings after an action.
public struct DeviceSettings: Hashable, Codable, Sendable {
    public var booted: Bool
    /// `nil` when it isn't booted or can't say.
    public var dark: Bool?
    /// How the screen turns to show it upright.
    public var orientation: DeviceOrientation

    public init(booted: Bool, dark: Bool? = nil, orientation: DeviceOrientation = .portrait) {
        self.booted = booted
        self.dark = dark
        self.orientation = orientation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        booted = try container.decodeIfPresent(Bool.self, forKey: .booted) ?? false
        dark = try container.decodeIfPresent(Bool.self, forKey: .dark)
        orientation = (try? container.decodeIfPresent(DeviceOrientation.self, forKey: .orientation)) ?? .portrait
    }
}

/// A video codec both sides can use for device screens.
public enum VideoCodec: OpenEnum {
    case h264
    case hevc
    case unknown(String)

    public static let knownCases: [VideoCodec] = [.h264, .hevc]

    public var rawValue: String {
        switch self {
        case .h264: "h264"
        case .hevc: "hevc"
        case .unknown(let value): value
        }
    }
}

/// Asks for a device's screen.
public struct AttachDevice: Hashable, Codable, Sendable {
    public var device: DeviceRef
    /// The most pixels the client shows, so the stream never sends more.
    public var maxPixels: UInt32
    /// Codecs the client decodes, preferred first.
    public var codecs: [VideoCodec]

    public init(device: DeviceRef, maxPixels: UInt32, codecs: [VideoCodec] = [.h264]) {
        self.device = device
        self.maxPixels = maxPixels
        self.codecs = codecs
    }
}

/// A device's screen stream.
public struct DeviceStream: Hashable, Codable, Sendable {
    public var channel: ChannelId
    public var codec: VideoCodec
    public var width: UInt16
    public var height: UInt16

    public init(channel: ChannelId, codec: VideoCodec, width: UInt16, height: UInt16) {
        self.channel = channel
        self.codec = codec
        self.width = width
        self.height = height
    }
}

/// One encoded access unit of a device's screen:
///
///     u32 big-endian frame number
///     u8  flags: bit 0 is a keyframe
///     u8  quarter turns counterclockwise to show it upright
///     u16 big-endian width
///     u16 big-endian height
///     u16 reserved
///     keyframes only: u8 count, then per parameter set a u16 big-endian length and its bytes
///     the sample: NAL units, each after a u32 big-endian length
public struct VideoFrame: Hashable, Sendable {
    public var seq: UInt32
    public var keyframe: Bool
    public var turns: UInt8
    public var width: UInt16
    public var height: UInt16
    /// SPS and PPS (and VPS for HEVC), on keyframes.
    public var parameterSets: [Data]
    public var sample: Data

    public static let headerSize = 12

    public init(seq: UInt32, keyframe: Bool, turns: UInt8 = 0, width: UInt16, height: UInt16,
                parameterSets: [Data] = [], sample: Data) {
        self.seq = seq
        self.keyframe = keyframe
        self.turns = turns
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
        self.sample = sample
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + sample.count + parameterSets.reduce(1) { $0 + 2 + $1.count })
        data.appendBigEndian(seq)
        data.append(keyframe ? 1 : 0)
        data.append(turns)
        data.appendBigEndian(width)
        data.appendBigEndian(height)
        data.appendBigEndian(UInt16(0))
        if keyframe {
            data.append(UInt8(min(parameterSets.count, 255)))
            for set in parameterSets.prefix(255) {
                data.appendBigEndian(UInt16(min(set.count, Int(UInt16.max))))
                data.append(set.prefix(Int(UInt16.max)))
            }
        }
        data.append(sample)
        return data
    }

    public static func decode(_ payload: Data) throws(ErrorCode) -> VideoFrame {
        var reader = ByteReader(payload)
        guard let seq = reader.uint32(), let flags = reader.uint8(), let turns = reader.uint8(),
              let width = reader.uint16(), let height = reader.uint16(), reader.uint16() != nil,
              turns < 4, width > 0, height > 0 else { throw .badRequest }
        let keyframe = flags & 1 == 1
        var sets: [Data] = []
        if keyframe {
            guard let count = reader.uint8() else { throw .badRequest }
            for _ in 0..<count {
                guard let length = reader.uint16(), let set = reader.bytes(Int(length)) else { throw .badRequest }
                sets.append(set)
            }
        }
        return VideoFrame(seq: seq, keyframe: keyframe, turns: turns, width: width, height: height,
                          parameterSets: sets, sample: reader.rest())
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

/// Reads big-endian integers and byte runs from the front of `Data`.
struct ByteReader {
    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    mutating func uint8() -> UInt8? {
        guard index < data.endIndex else { return nil }
        defer { index += 1 }
        return data[index]
    }

    mutating func uint16() -> UInt16? {
        guard let bytes = bytes(2) else { return nil }
        return bytes.reduce(0) { $0 << 8 | UInt16($1) }
    }

    mutating func uint32() -> UInt32? {
        guard let bytes = bytes(4) else { return nil }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, data.endIndex - index >= count else { return nil }
        defer { index += count }
        return Data(data[index ..< index + count])
    }

    mutating func rest() -> Data {
        defer { index = data.endIndex }
        return Data(data[index...])
    }
}

extension DeviceInput {
    func validate() throws(ErrorCode) {
        switch self {
        case .touch(let x, let y, _):
            if !x.isFinite || !y.isFinite || x < -1 || x > 2 || y < -1 || y > 2 { throw .badRequest }
        case .key, .button, .unknown: break
        }
    }

    static func validate(_ input: [DeviceInput]) throws(ErrorCode) {
        if input.count > Limits.maxDeviceInput { throw .badRequest }
        for item in input { try item.validate() }
    }
}

extension DeviceRef {
    func validate() throws(ErrorCode) {
        if id.isEmpty || id.utf8.count > 256 || Validation.hasNul(id) || id.contains("/") { throw .badRequest }
    }
}

extension DeviceAction {
    func validate() throws(ErrorCode) {
        switch self {
        case .input(let input): try DeviceInput.validate(input)
        case .type(let text): if text.utf8.count > Limits.maxInput || Validation.hasNul(text) { throw .badRequest }
        case .openURL(let url): if url.isEmpty || url.utf8.count > Limits.maxLinkURI || Validation.hasNul(url) { throw .badRequest }
        case .rotate(let turns): if abs(turns) > 4 { throw .badRequest }
        case .boot, .shutDown, .setDark, .setHardwareKeyboard, .readSettings, .unknown: break
        }
    }
}
