import Foundation

/// The terminal operation that failed.
public enum TerminalStep: String, Sendable {
    case create
    case resize
    case render
    case cursor
    case mode
    case compress
    case history
    case input
    case colors
    case search
    case selection
    case graphics
    case archive
}

/// A terminal engine failure, tagged with the step that failed.
public struct TerminalError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Reason: Equatable, Sendable {
        /// The engine returned this `GhosttyResult` code.
        case engine(Int32)
        /// A history or search cursor refers to output that has changed since.
        case staleCursor
        /// Primary history could not be captured when the alternate screen was entered.
        case historyUnavailable
        case invalidArgument(String)
    }

    public let step: TerminalStep
    public let reason: Reason

    public init(_ step: TerminalStep, _ reason: Reason) {
        self.step = step
        self.reason = reason
    }

    public var description: String {
        switch reason {
        case let .engine(code): "terminal \(step.rawValue) failed: engine error \(code)"
        case .staleCursor: "terminal \(step.rawValue) failed: output changed; start again"
        case .historyUnavailable: "terminal \(step.rawValue) failed: history unavailable"
        case let .invalidArgument(message): "terminal \(step.rawValue) failed: \(message)"
        }
    }
}

/// The PTY operation that failed.
public enum PTYStep: String, Sendable {
    case open
    case spawn
    case write
    case resize
    case wait
    case kill
}

/// A PTY failure with the `errno` that caused it.
public struct PTYError: Error, Equatable, Sendable, CustomStringConvertible {
    public let step: PTYStep
    public let code: Int32

    public init(_ step: PTYStep, code: Int32 = errno) {
        self.step = step
        self.code = code
    }

    public var description: String {
        "pty \(step.rawValue) failed: \(String(cString: strerror(code)))"
    }
}
