import CGhosttyVT
import Foundation
import TabProtocol

/// A terminal's screen and primary history, saved so a session's output
/// survives the program and the server.
public struct TerminalArchive: Hashable, Sendable {
    public var size: Size
    public var rows: [Row]
    public var cursor: Cursor
    /// Primary-screen history, oldest first, even while a full-screen app runs.
    public var history: [[Run]]
    public var graphics: Graphics
    /// URIs of the `Style.hyperlink` ids used in `rows` and `history`.
    public var hyperlinks: [UInt32: String]

    public init(
        size: Size, rows: [Row], cursor: Cursor, history: [[Run]],
        graphics: Graphics, hyperlinks: [UInt32: String] = [:]
    ) {
        self.size = size
        self.rows = rows
        self.cursor = cursor
        self.history = history
        self.graphics = graphics
        self.hyperlinks = hyperlinks
    }
}

extension Terminal {
    /// Captures the screen and the primary history. On the alternate screen
    /// the history is the one captured when the program switched to it.
    public func archive() throws -> TerminalArchive {
        let history: [[Run]] = switch try activeScreen(.archive) {
        case GHOSTTY_TERMINAL_SCREEN_ALTERNATE: try primaryHistory.get()
        default: try captureHistory()
        }
        let rows = try fullRender()
        var ids = Set<UInt32>()
        for runs in history + rows.map(\.runs) {
            for run in runs where run.style.hyperlink != 0 {
                ids.insert(run.style.hyperlink)
            }
        }
        var uris: [UInt32: String] = [:]
        for id in ids {
            uris[id] = hyperlinks.uri(for: id)
        }
        return TerminalArchive(
            size: size, rows: rows, cursor: try cursor(), history: history, graphics: try graphics(), hyperlinks: uris)
    }

    /// Replaces the terminal's content with an archive: its history becomes
    /// scrollback and its rows the screen, then the terminal returns to its
    /// current size. Styles, wide characters and hyperlinks are kept; images
    /// and modes are not.
    public func restore(_ archive: TerminalArchive) throws {
        guard archive.size.cols > 0, archive.size.rows > 0 else {
            throw TerminalError(.archive, .invalidArgument("empty size"))
        }
        let target = size
        ghostty_terminal_reset(handle)
        try resize(archive.size)
        var replay = ReplayEncoder(hyperlinks: archive.hyperlinks)
        for runs in archive.history {
            replay.line(runs)
            replay.newline()
        }
        var screen = [[Run]](repeating: [], count: Int(archive.size.rows))
        for row in archive.rows where Int(row.index) < screen.count {
            screen[Int(row.index)] = row.runs
        }
        for (index, runs) in screen.enumerated() {
            replay.line(runs)
            if index + 1 < screen.count {
                replay.newline()
            }
        }
        replay.cursor(archive.cursor)
        replay.bytes.withUnsafeBufferPointer { ghostty_terminal_vt_write(handle, $0.baseAddress, $0.count) }
        try resize(target)
        _ = takePtyOutput()
        _ = takeEvents()
        primaryHistory = .success([])
    }
}

/// Turns runs back into the VT sequences that draw them.
struct ReplayEncoder {
    let hyperlinks: [UInt32: String]
    var bytes: [UInt8] = []
    private var style = Style()
    private var link: UInt32 = 0

    init(hyperlinks: [UInt32: String]) {
        self.hyperlinks = hyperlinks
    }

    mutating func line(_ runs: [Run]) {
        for run in runs {
            if run.style != style {
                sgr(run.style)
            }
            let uri = hyperlinks[run.style.hyperlink]
            if run.style.hyperlink != link {
                append("\u{1b}]8;;\(uri ?? "")\u{1b}\\")
                link = uri == nil ? 0 : run.style.hyperlink
            }
            append(run.text)
        }
        if link != 0 {
            append("\u{1b}]8;;\u{1b}\\")
            link = 0
        }
        if style != Style() {
            append("\u{1b}[0m")
            style = Style()
        }
    }

    mutating func newline() {
        append("\r\n")
    }

    mutating func cursor(_ cursor: Cursor) {
        append("\u{1b}[\(Int(cursor.row) + 1);\(Int(cursor.col) + 1)H")
        if !cursor.visible {
            append("\u{1b}[?25l")
        }
    }

    private mutating func sgr(_ next: Style) {
        var parameters = ["0"]
        if next.bold { parameters.append("1") }
        if next.faint { parameters.append("2") }
        if next.italic { parameters.append("3") }
        if next.underline != .none { parameters.append("4:\(next.underline.rawValue)") }
        if next.inverse { parameters.append("7") }
        if next.invisible { parameters.append("8") }
        if next.strikethrough { parameters.append("9") }
        if next.overline { parameters.append("53") }
        parameters += Self.color(next.fg, base: 38)
        parameters += Self.color(next.bg, base: 48)
        parameters += Self.color(next.underlineColor, base: 58)
        append("\u{1b}[\(parameters.joined(separator: ";"))m")
        style = next
    }

    private static func color(_ color: Color, base: Int) -> [String] {
        switch color {
        case .default: []
        case let .indexed(index): ["\(base)", "5", "\(index)"]
        case let .rgb(r, g, b): ["\(base)", "2", "\(r)", "\(g)", "\(b)"]
        }
    }

    private mutating func append(_ text: String) {
        bytes.append(contentsOf: text.utf8)
    }
}
