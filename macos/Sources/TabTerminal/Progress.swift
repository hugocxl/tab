import Foundation

/// A progress report from a program (OSC 9;4), as shown on its session.
public struct ProgressReport: Hashable, Sendable {
    public enum State: UInt8, Hashable, Codable, Sendable {
        case running = 0
        case error = 1
        case indeterminate = 2
        case paused = 3
    }

    public var state: State
    /// 0...100, or nil when the program gave none.
    public var percent: UInt8?

    public init(state: State, percent: UInt8?) {
        self.state = state
        self.percent = percent
    }
}

/// The current report and how many reports have finished so far.
public struct ProgressUpdate: Hashable, Sendable {
    public var report: ProgressReport?
    public var completed: UInt64

    public init(report: ProgressReport?, completed: UInt64) {
        self.report = report
        self.completed = completed
    }
}

/// Parses OSC 9;4 progress reports out of the output stream, across reads.
/// A report expires after `timeout` without a refresh.
struct ProgressParser {
    static let timeout: TimeInterval = 15

    private enum State {
        case ground
        case escape
        case osc
        case oscEscape
        case string
    }

    private var state = State.ground
    private var bytes = [UInt8](repeating: 0, count: 32)
    private var length = 0
    private var utf8Remaining = 0
    private(set) var current: ProgressReport?
    private var changed = false
    private var completed: UInt64 = 0
    private(set) var deadline: TimeInterval?

    mutating func feed(_ input: UnsafeBufferPointer<UInt8>, now: TimeInterval) {
        var index = 0
        let count = input.count
        while utf8Remaining > 0 && index < count {
            advance(input[index], now: now)
            index += 1
        }
        while index < count {
            if case .ground = state, utf8Remaining == 0 {
                index = Self.skipText(input, from: index)
                guard index < count else { return }
                if input[index] == 0x1b, index + 1 < count, input[index + 1] == UInt8(ascii: "[") {
                    index += 2
                    continue
                }
            }
            advance(input[index], now: now)
            index += 1
        }
    }

    /// Skips printable ASCII and complete UTF-8 sequences, stopping at ESC or
    /// at any byte that is not part of valid UTF-8 (such as a C1 control).
    private static func skipText(_ input: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        let count = input.count
        while index < count {
            let byte = input[index]
            if byte == 0x1b { return index }
            if byte < 0x80 {
                index += 1
                continue
            }
            let length = switch byte {
            case 0xc2...0xdf: 2
            case 0xe0...0xef: 3
            case 0xf0...0xf4: 4
            default: 0
            }
            guard length > 0, index + length <= count else { return index }
            for offset in 1..<length where input[index + offset] & 0xc0 != 0x80 {
                return index
            }
            index += length
        }
        return index
    }

    private mutating func advance(_ byte: UInt8, now: TimeInterval) {
        if utf8Remaining > 0, (0x80...0xbf).contains(byte) {
            utf8Remaining -= 1
            content(byte)
            return
        }
        utf8Remaining = switch byte {
        case 0xc2...0xdf: 1
        case 0xe0...0xef: 2
        case 0xf0...0xf4: 3
        default: 0
        }
        if byte == 0x18 || byte == 0x1a {
            state = .ground
            return
        }
        switch (state, byte) {
        case (.osc, 0x07), (.osc, 0x9c):
            finish(now: now)
            state = .ground
        case (.osc, 0x1b):
            state = .oscEscape
        case (.oscEscape, UInt8(ascii: "\\")):
            finish(now: now)
            state = .ground
        case (_, 0x1b):
            state = .escape
        case (_, 0x9d):
            start()
        case (_, 0x90), (_, 0x98), (_, 0x9e), (_, 0x9f):
            state = .string
        case (_, 0x80...0x9c):
            state = .ground
        case (.escape, _), (.oscEscape, _):
            escaped(byte, now: now)
        default:
            content(byte)
        }
    }

    private mutating func escaped(_ byte: UInt8, now: TimeInterval) {
        switch byte {
        case UInt8(ascii: "]"):
            start()
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            state = .string
        case UInt8(ascii: "c"):
            set(nil, now: now)
            state = .ground
        case 0x00...0x17, 0x19, 0x1c...0x1f, 0x7f:
            break
        default:
            state = .ground
        }
    }

    private mutating func start() {
        state = .osc
        length = 0
    }

    private mutating func content(_ byte: UInt8) {
        guard case .osc = state, byte > 0x1f, byte != 0x7f else { return }
        if length < bytes.count {
            bytes[length] = byte
            length += 1
        } else {
            length = bytes.count + 1
        }
    }

    private mutating func finish(now: TimeInterval) {
        guard length <= bytes.count else { return }
        let prefix: [UInt8] = Array("9;4;".utf8)
        guard length >= prefix.count, Array(bytes[0..<prefix.count]) == prefix else { return }
        let fields = bytes[prefix.count..<length].split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)
        guard let stateField = fields.first, stateField.count == 1,
              let code = stateField.first, (UInt8(ascii: "0")...UInt8(ascii: "4")).contains(code),
              fields.count <= 2
        else { return }
        var percent: UInt8?
        if fields.count == 2, !fields[1].isEmpty {
            guard fields[1].allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return }
            percent = fields[1].reduce(UInt8(0)) { value, digit in
                UInt8(min(UInt16(value) * 10 + UInt16(digit - UInt8(ascii: "0")), 100))
            }
        }
        let previous = current?.percent
        switch code {
        case UInt8(ascii: "0"):
            set(nil, now: now)
        case UInt8(ascii: "1"):
            set(ProgressReport(state: .running, percent: percent ?? 0), now: now)
        case UInt8(ascii: "2"):
            set(ProgressReport(state: .error, percent: percent ?? previous), now: now)
        case UInt8(ascii: "3"):
            set(ProgressReport(state: .indeterminate, percent: previous), now: now)
        default:
            set(ProgressReport(state: .paused, percent: percent ?? previous), now: now)
        }
    }

    private mutating func set(_ report: ProgressReport?, now: TimeInterval) {
        deadline = report == nil ? nil : now + Self.timeout
        if current != nil, report == nil {
            completed += 1
        }
        if current != report {
            current = report
            changed = true
        }
    }

    /// The update to publish, if anything changed or the report expired.
    mutating func take(now: TimeInterval) -> ProgressUpdate? {
        if let deadline, now >= deadline {
            set(nil, now: now)
        }
        guard changed else { return nil }
        changed = false
        return ProgressUpdate(report: current, completed: completed)
    }
}
