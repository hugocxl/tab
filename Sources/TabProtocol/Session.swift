import Foundation

// MARK: - Sessions

public struct SessionInfo: Hashable, Codable, Sendable {
    public var project: ProjectId
    public var id: SessionId
    public var directory: ServerPath

    public init(project: ProjectId, id: SessionId, directory: ServerPath) {
        self.project = project
        self.id = id
        self.directory = directory
    }
}

public enum SessionStatus: OpenEnum {
    case starting
    case live
    case ended
    case unavailable
    case unknown(String)

    public static let knownCases: [SessionStatus] = [.starting, .live, .ended, .unavailable]

    public var rawValue: String {
        switch self {
        case .starting: "starting"
        case .live: "live"
        case .ended: "ended"
        case .unavailable: "unavailable"
        case .unknown(let value): value
        }
    }
}

/// The client that owns a session's size: the first one attached.
public struct SessionClient: Hashable, Codable, Sendable {
    public var id: ClientId
    public var kind: ClientKind

    public init(id: ClientId, kind: ClientKind) {
        self.id = id
        self.kind = kind
    }
}

/// How a session's program ended.
public enum ExitReason: Hashable, Sendable, Codable {
    case exited(Int32)
    case signaled(Int32)
    /// A client ended it.
    case ended
    case serverStopped
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "exited": self = .exited(try c("code"))
        case "signaled": self = .signaled(try c("signal"))
        case "ended": self = .ended
        case "serverStopped": self = .serverStopped
        default: self = .unknown(c.type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .exited(let code):
            var c = try TaggedEncoding(encoder, "exited")
            try c(code, "code")
        case .signaled(let signal):
            var c = try TaggedEncoding(encoder, "signaled")
            try c(signal, "signal")
        case .ended: try TaggedEncoding(encoder, "ended")
        case .serverStopped: try TaggedEncoding(encoder, "serverStopped")
        case .unknown(let type): try TaggedEncoding(encoder, type)
        }
    }
}

/// The program in the foreground of a session's terminal.
public struct ForegroundProcess: Hashable, Codable, Sendable {
    public var name: String
    public var isShell: Bool

    public init(name: String, isShell: Bool) {
        self.name = name
        self.isShell = isShell
    }
}

/// Everything a client needs to show a session it just attached to.
public struct AttachSnapshot: Hashable, Codable, Sendable {
    public var channel: ChannelId
    public var size: Size
    public var rows: [Row]
    public var cursor: Cursor
    public var modes: Modes
    public var graphics: Graphics?
    public var title: String
    public var directory: ServerPath
    /// Prompt starts in history-then-screen row coordinates.
    public var prompts: [UInt16]
    /// The newest history rows, oldest first.
    public var history: [Row]
    /// Where to continue paging history backwards; `nil` when it is all here.
    public var historyCursor: HistoryCursor?
    public var historyTotal: UInt64

    public init(channel: ChannelId, size: Size, rows: [Row], cursor: Cursor, modes: Modes = Modes(),
                graphics: Graphics? = nil, title: String = "", directory: ServerPath, prompts: [UInt16] = [],
                history: [Row] = [], historyCursor: HistoryCursor? = nil, historyTotal: UInt64 = 0) {
        self.channel = channel
        self.size = size
        self.rows = rows
        self.cursor = cursor
        self.modes = modes
        self.graphics = graphics
        self.title = title
        self.directory = directory
        self.prompts = prompts
        self.history = history
        self.historyCursor = historyCursor
        self.historyTotal = historyTotal
    }
}

public struct HistoryPage: Hashable, Codable, Sendable {
    /// Prompt starts in page-history-then-optional-screen row coordinates.
    public var prompts: [UInt16]
    /// Oldest first.
    public var rows: [Row]
    public var next: HistoryCursor?
    public var totalRows: UInt64
    /// The saved screen below the history, on the first page of a saved session.
    public var screen: SavedScreen?

    public init(prompts: [UInt16] = [], rows: [Row], next: HistoryCursor? = nil, totalRows: UInt64,
                screen: SavedScreen? = nil) {
        self.prompts = prompts
        self.rows = rows
        self.next = next
        self.totalRows = totalRows
        self.screen = screen
    }
}

/// Which session a history search or page reads.
public enum SearchSource: Hashable, Codable, Sendable {
    /// An attached session, by its channel.
    case live(ChannelId)
    /// A session's saved output, also after it ended.
    case saved(SessionId)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "live": self = .live(try c("channel"))
        case "saved": self = .saved(try c("session"))
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                         debugDescription: "Unknown search source \(c.type)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .live(let channel):
            var c = try TaggedEncoding(encoder, "live")
            try c(channel, "channel")
        case .saved(let session):
            var c = try TaggedEncoding(encoder, "saved")
            try c(session, "session")
        }
    }
}

public struct SearchMatch: Hashable, Codable, Sendable {
    /// History-then-screen row.
    public var row: UInt64
    /// Cell columns, end exclusive.
    public var start: UInt16
    public var end: UInt16

    public init(row: UInt64, start: UInt16, end: UInt16) {
        self.row = row
        self.start = start
        self.end = end
    }
}

/// Matches newest first, and where to continue searching older rows.
public struct SearchPage: Hashable, Codable, Sendable {
    public var matches: [SearchMatch]
    public var next: HistoryCursor?
    public var totalRows: UInt64
    public var scannedRows: UInt64

    public init(matches: [SearchMatch], next: HistoryCursor? = nil, totalRows: UInt64, scannedRows: UInt64) {
        self.matches = matches
        self.next = next
        self.totalRows = totalRows
        self.scannedRows = scannedRows
    }
}

/// A session's last screen, kept on disk after its program or the server ended.
public struct SavedScreen: Hashable, Codable, Sendable {
    public var size: Size
    public var rows: [Row]
    public var cursor: Cursor
    public var graphics: Graphics?
    public var reason: ExitReason?

    public init(size: Size, rows: [Row], cursor: Cursor, graphics: Graphics? = nil, reason: ExitReason? = nil) {
        self.size = size
        self.rows = rows
        self.cursor = cursor
        self.graphics = graphics
        self.reason = reason
    }
}

// MARK: - Metadata and progress

public enum ProgressState: OpenEnum {
    case running
    case error
    case indeterminate
    case paused
    case unknown(String)

    public static let knownCases: [ProgressState] = [.running, .error, .indeterminate, .paused]

    public var rawValue: String {
        switch self {
        case .running: "running"
        case .error: "error"
        case .indeterminate: "indeterminate"
        case .paused: "paused"
        case .unknown(let value): value
        }
    }
}

/// A program's OSC 9;4 progress report.
public struct TerminalProgress: Hashable, Codable, Sendable {
    public var state: ProgressState
    /// 0...100.
    public var percent: UInt8?

    public init(state: ProgressState, percent: UInt8? = nil) {
        self.state = state
        self.percent = percent
    }
}

public struct SessionProgress: Hashable, Codable, Sendable {
    public var progress: TerminalProgress?
    /// How many progress reports finished, so clients can notice one they missed.
    public var completed: UInt64

    public init(progress: TerminalProgress? = nil, completed: UInt64 = 0) {
        self.progress = progress
        self.completed = completed
    }
}

/// What the sidebar shows for a session, sent to every client.
public struct SessionMetadata: Hashable, Codable, Sendable {
    public var title: String
    public var directory: ServerPath
    public var process: ForegroundProcess?

    public init(title: String, directory: ServerPath, process: ForegroundProcess? = nil) {
        self.title = title
        self.directory = directory
        self.process = process
    }
}

/// Links found on screen rows, in cell columns, end exclusive.
public struct LinkRow: Hashable, Codable, Sendable {
    public var row: UInt16
    public var spans: [LinkSpan]

    public init(row: UInt16, spans: [LinkSpan]) {
        self.row = row
        self.spans = spans
    }
}

public struct LinkSpan: Hashable, Codable, Sendable {
    public var start: UInt16
    public var end: UInt16
    public var uri: String

    public init(start: UInt16, end: UInt16, uri: String) {
        self.start = start
        self.end = end
        self.uri = uri
    }
}

/// A change an attached client hears about on the session's channel.
public enum MetadataEvent: Hashable, Codable, Sendable {
    case title(String)
    case directory(ServerPath)
    case foregroundProcess(ForegroundProcess)
    case bell
    case history(totalRows: UInt64)
    case inputModes(InputModes)
    case cursorBlinking(Bool)
    /// Links on the screen rows of frame `seq`.
    case links(seq: UInt64, rows: [LinkRow])
    /// Rows where prompts start on the screen of frame `seq`.
    case screenPrompts(seq: UInt64, rows: [UInt16])
    /// OSC 52: a program asked to set the clipboard.
    case clipboardWrite(String)
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "title": self = .title(try c("title"))
        case "directory": self = .directory(try c("directory"))
        case "foregroundProcess": self = .foregroundProcess(try c("process"))
        case "bell": self = .bell
        case "history": self = .history(totalRows: try c("totalRows"))
        case "inputModes": self = .inputModes(try c("modes"))
        case "cursorBlinking": self = .cursorBlinking(try c("blinking"))
        case "links": self = .links(seq: try c("seq"), rows: try c("rows"))
        case "screenPrompts": self = .screenPrompts(seq: try c("seq"), rows: try c("rows"))
        case "clipboardWrite": self = .clipboardWrite(try c("text"))
        default: self = .unknown(c.type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .title(let title):
            var c = try TaggedEncoding(encoder, "title")
            try c(title, "title")
        case .directory(let directory):
            var c = try TaggedEncoding(encoder, "directory")
            try c(directory, "directory")
        case .foregroundProcess(let process):
            var c = try TaggedEncoding(encoder, "foregroundProcess")
            try c(process, "process")
        case .bell:
            try TaggedEncoding(encoder, "bell")
        case .history(let totalRows):
            var c = try TaggedEncoding(encoder, "history")
            try c(totalRows, "totalRows")
        case .inputModes(let modes):
            var c = try TaggedEncoding(encoder, "inputModes")
            try c(modes, "modes")
        case .cursorBlinking(let blinking):
            var c = try TaggedEncoding(encoder, "cursorBlinking")
            try c(blinking, "blinking")
        case .links(let seq, let rows):
            var c = try TaggedEncoding(encoder, "links")
            try c(seq, "seq")
            try c(rows, "rows")
        case .screenPrompts(let seq, let rows):
            var c = try TaggedEncoding(encoder, "screenPrompts")
            try c(seq, "seq")
            try c(rows, "rows")
        case .clipboardWrite(let text):
            var c = try TaggedEncoding(encoder, "clipboardWrite")
            try c(text, "text")
        case .unknown(let type):
            try TaggedEncoding(encoder, type)
        }
    }
}

// MARK: - Session channel

/// Moves the server-side viewport of an attached session, for programs and
/// selection that depend on it. Clients page history themselves.
public enum ScrollRequest: Hashable, Codable, Sendable {
    /// Positive scrolls down, towards live output.
    case lines(Int32)
    case top
    case bottom
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "lines": self = .lines(try c("lines"))
        case "top": self = .top
        case "bottom": self = .bottom
        default: self = .unknown(c.type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .lines(let lines):
            var c = try TaggedEncoding(encoder, "lines")
            try c(lines, "lines")
        case .top: try TaggedEncoding(encoder, "top")
        case .bottom: try TaggedEncoding(encoder, "bottom")
        case .unknown(let type): try TaggedEncoding(encoder, type)
        }
    }
}

/// A JSON message on an attached session's channel. Screen frames travel as
/// binary `screen` frames and raw input as `input` frames beside these.
public enum SessionMessage: Hashable, Codable, Sendable {
    // Server to client.
    case metadata(MetadataEvent)
    case ended(ExitReason)
    case resized(Size)

    // Client to server.
    case input(TerminalInput)
    case resize(Size)
    /// The client drew frame `seq`; the server may send the next one.
    case ack(UInt64)
    case scroll(ScrollRequest)
    case cellSize(CellSize)
    /// Asks for a history metadata event with the current total.
    case requestHistory
    /// Clears the screen through the engine (Cmd+K).
    case clear

    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "metadata": self = .metadata(try c("event"))
        case "ended": self = .ended(try c("reason"))
        case "resized": self = .resized(try c("size"))
        case "input": self = .input(try c("input"))
        case "resize": self = .resize(try c("size"))
        case "ack": self = .ack(try c("seq"))
        case "scroll": self = .scroll(try c("scroll"))
        case "cellSize": self = .cellSize(try c("cell"))
        case "requestHistory": self = .requestHistory
        case "clear": self = .clear
        default: self = .unknown(c.type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .metadata(let event):
            var c = try TaggedEncoding(encoder, "metadata")
            try c(event, "event")
        case .ended(let reason):
            var c = try TaggedEncoding(encoder, "ended")
            try c(reason, "reason")
        case .resized(let size):
            var c = try TaggedEncoding(encoder, "resized")
            try c(size, "size")
        case .input(let input):
            var c = try TaggedEncoding(encoder, "input")
            try c(input, "input")
        case .resize(let size):
            var c = try TaggedEncoding(encoder, "resize")
            try c(size, "size")
        case .ack(let seq):
            var c = try TaggedEncoding(encoder, "ack")
            try c(seq, "seq")
        case .scroll(let scroll):
            var c = try TaggedEncoding(encoder, "scroll")
            try c(scroll, "scroll")
        case .cellSize(let cell):
            var c = try TaggedEncoding(encoder, "cellSize")
            try c(cell, "cell")
        case .requestHistory: try TaggedEncoding(encoder, "requestHistory")
        case .clear: try TaggedEncoding(encoder, "clear")
        case .unknown(let type): try TaggedEncoding(encoder, type)
        }
    }
}

// MARK: - Screen types in JSON

/// A row inside JSON is its `ScreenCodec` encoding, as base64.
extension Row: Codable {
    public init(from decoder: Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        do {
            self = try ScreenCodec.decodeRow(data)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Bad row: \(error)", underlyingError: error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ScreenCodec.encodeRow(self))
    }
}

/// Graphics inside JSON are their `ScreenCodec` encoding, as base64.
extension Graphics: Codable {
    public init(from decoder: Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        do {
            self = try ScreenCodec.decodeGraphics(data)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Bad graphics: \(error)", underlyingError: error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ScreenCodec.encodeGraphics(self))
    }
}

/// Terminal input in the same `{"type": ...}` shape as every other message.
extension TerminalInput {
    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "bytes": self = .bytes(try c("bytes"))
        case "text": self = .text(try c("text"))
        case "key": self = .key(try c("event"))
        case "mouse": self = .mouse(try c("event"))
        case "paste": self = .paste(try c("text"))
        case "focus": self = .focus(try c("focused"))
        default: throw unknownCase(c.type, decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .bytes(let bytes):
            var c = try TaggedEncoding(encoder, "bytes")
            try c(bytes, "bytes")
        case .text(let text):
            var c = try TaggedEncoding(encoder, "text")
            try c(text, "text")
        case .key(let event):
            var c = try TaggedEncoding(encoder, "key")
            try c(event, "event")
        case .mouse(let event):
            var c = try TaggedEncoding(encoder, "mouse")
            try c(event, "event")
        case .paste(let text):
            var c = try TaggedEncoding(encoder, "paste")
            try c(text, "text")
        case .focus(let focused):
            var c = try TaggedEncoding(encoder, "focus")
            try c(focused, "focused")
        }
    }
}
