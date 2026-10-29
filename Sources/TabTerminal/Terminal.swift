import CGhosttyVT
import Foundation
import TabProtocol

/// An 8-bit RGB color.
public struct ThemeColor: Hashable, Codable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// The theme a client wants: default colors, the 16 ANSI colors, palette
/// overrides and the default cursor.
public struct TerminalTheme: Hashable, Sendable {
    public var foreground: ThemeColor
    public var background: ThemeColor
    public var cursor: ThemeColor
    /// The 16 ANSI colors; extra entries are ignored.
    public var ansi: [ThemeColor]
    /// Overrides for palette entries 16...255 (or 0...15).
    public var palette: [UInt8: ThemeColor]
    public var cursorStyle: CursorShape?
    public var cursorBlink: Bool?

    public init(
        foreground: ThemeColor, background: ThemeColor, cursor: ThemeColor, ansi: [ThemeColor],
        palette: [UInt8: ThemeColor] = [:], cursorStyle: CursorShape? = nil, cursorBlink: Bool? = nil
    ) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.ansi = ansi
        self.palette = palette
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
    }
}

/// Where to move the engine's viewport.
public enum ScrollTarget: Hashable, Sendable {
    case top
    case bottom
    /// Rows; negative scrolls up into history.
    case delta(Int)
    /// Absolute row from the top of history.
    case row(Int)
    /// Shell prompts; negative moves to earlier prompts.
    case prompt(Int)
}

public enum CompressionMode: Sendable {
    /// One bounded step, for idle scheduling.
    case incremental
    /// Every eligible page at once.
    case full
}

/// A Ghostty terminal: parses program output, keeps screen and history, and
/// encodes input. Not thread-safe; the owner serializes every call.
public final class Terminal {
    let handle: GhosttyTerminal
    let engineRender: RenderResources
    let rowReader: RowReader
    let hyperlinks = HyperlinkTable()
    private let callbacks: EngineCallbacks
    private let keyboard: Keyboard
    private let mouse: Mouse
    private let graphicsCache: GraphicsCache
    private var progress = ProgressParser()
    private var rowHashes: [Int?] = []
    private var rowLinks: [CachedLinks] = []
    var redrawAll = true
    public private(set) var size: Size
    public private(set) var cellSize = CellSize(width: 8, height: 16)
    private var screenSwitch = ScreenSwitch()
    var primaryHistory: Result<[[Run]], TerminalError> = .success([])
    var tracking = HistoryTracking()
    var searchSession: SearchSession?

    public init(size: Size, historyBudgetBytes: Int) throws {
        guard size.cols > 0, size.rows > 0 else { throw TerminalError(.create, .invalidArgument("empty size")) }
        callbacks = EngineCallbacks()
        keyboard = try Keyboard()
        mouse = try Mouse(size: size)
        graphicsCache = try GraphicsCache()
        engineRender = try RenderResources()
        rowReader = try RowReader()
        self.size = size
        handle = try Self.makeEngine(size: size, historyBudgetBytes: historyBudgetBytes, callbacks: callbacks)
    }

    deinit {
        searchSession = nil
        ghostty_terminal_free(handle)
    }

    private static func makeEngine(size: Size, historyBudgetBytes: Int, callbacks: EngineCallbacks) throws -> GhosttyTerminal {
        var created: GhosttyTerminal?
        try Ghostty.check(ghostty_terminal_new(nil, &created, size.cols, size.rows), .create)
        guard let terminal = created else { throw TerminalError(.create, .engine(GHOSTTY_OUT_OF_MEMORY.rawValue)) }
        do {
            var budget = max(0, historyBudgetBytes)
            try Ghostty.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &budget), .create)
            var blink = true
            try Ghostty.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink), .create)
            var grapheme = GhosttyTerminalModeConfig(mode: DECMode.graphemeCluster, value: true)
            try Ghostty.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &grapheme), .create)
            try configureGraphics(terminal)
            let terminfo = "xterm-256color"
            try terminfo.utf8CString.withUnsafeBufferPointer { name in
                try name.withMemoryRebound(to: UInt8.self) { bytes in
                    var string = GhosttyString(ptr: bytes.baseAddress, len: bytes.count - 1)
                    try Ghostty.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &string), .create)
                }
            }
            try Ghostty.check(ghostty_terminal_resize(terminal, size.cols, size.rows, 8, 16), .create)
            try callbacks.install(on: terminal)
        } catch {
            ghostty_terminal_free(terminal)
            throw error
        }
        return terminal
    }

    /// Kitty images live in memory only: no file, temp file or shared memory media.
    private static func configureGraphics(_ terminal: GhosttyTerminal) throws {
        var limit = UInt64(maxGraphicsBytes)
        try Ghostty.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &limit), .create)
        var disabled = false
        try Ghostty.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &disabled), .create)
        try Ghostty.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, nil), .create)
        try Ghostty.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &disabled), .create)
    }

    // MARK: - Output

    /// Parses program output. Entering the alternate screen first captures
    /// the primary history so archives keep it while a full-screen app runs.
    public func feed(_ bytes: UnsafeRawBufferPointer) {
        let input = bytes.bindMemory(to: UInt8.self)
        guard let base = input.baseAddress, !input.isEmpty else { return }
        progress.feed(input, now: ProcessInfo.processInfo.systemUptime)
        var start = 0
        for index in 0..<input.count where screenSwitch.advance(input[index]) {
            ghostty_terminal_vt_write(handle, base + start, index - start)
            start = index
            guard (try? activeScreen(.history)) == GHOSTTY_TERMINAL_SCREEN_PRIMARY else { continue }
            do {
                primaryHistory = .success(try captureHistory())
            } catch let error as TerminalError {
                primaryHistory = .failure(error)
            } catch {
                primaryHistory = .failure(TerminalError(.history, .historyUnavailable))
            }
        }
        ghostty_terminal_vt_write(handle, base + start, input.count - start)
    }

    public func feed(_ data: Data) {
        data.withUnsafeBytes { feed($0) }
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { feed($0) }
    }

    /// Bytes the engine wants written back to the PTY (query replies, reports).
    public func takePtyOutput() -> Data {
        guard !callbacks.ptyOutput.isEmpty else { return Data() }
        let output = Data(callbacks.ptyOutput)
        callbacks.ptyOutput.removeAll(keepingCapacity: true)
        return output
    }

    /// Title, directory, clipboard, bell and progress changes since the last call.
    public func takeEvents(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [TerminalEvent] {
        var events: [TerminalEvent] = []
        if let update = progress.take(now: now) {
            events.append(.progress(update))
        }
        if callbacks.titleChanged {
            callbacks.titleChanged = false
            if let title = try? string(GHOSTTY_TERMINAL_DATA_TITLE) {
                events.append(.title(title))
            }
        }
        if callbacks.directoryChanged {
            callbacks.directoryChanged = false
            if let directory = try? string(GHOSTTY_TERMINAL_DATA_PWD) {
                events.append(.directory(directory))
            }
        }
        if let text = callbacks.clipboardWrite {
            callbacks.clipboardWrite = nil
            events.append(.clipboardWrite(text))
        }
        if callbacks.bell {
            callbacks.bell = false
            events.append(.bell)
        }
        return events
    }

    // MARK: - Size and colors

    public func resize(_ size: Size) throws {
        guard size.cols > 0, size.rows > 0 else { throw TerminalError(.resize, .invalidArgument("empty size")) }
        try Ghostty.check(
            ghostty_terminal_resize(handle, size.cols, size.rows, UInt32(cellSize.width), UInt32(cellSize.height)),
            .resize)
        self.size = size
        redrawAll = true
        mouse.resize(size)
        tracking.invalidate()
    }

    /// The cell size in pixels, used for image placement and size reports.
    public func setCellSize(_ cell: CellSize) throws {
        guard cell.width > 0, cell.height > 0 else { throw TerminalError(.resize, .invalidArgument("empty cell")) }
        try Ghostty.check(
            ghostty_terminal_resize(handle, size.cols, size.rows, UInt32(cell.width), UInt32(cell.height)), .resize)
        cellSize = cell
    }

    /// Applies a theme. Programs that asked for color scheme reports
    /// (mode 2031) get one in `takePtyOutput()` when the colors changed.
    public func setDefaults(_ colors: TerminalTheme) throws {
        let previous = try (defaultColor(GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT),
                            defaultColor(GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT),
                            defaultColor(GHOSTTY_TERMINAL_DATA_COLOR_CURSOR_DEFAULT))
        let previousPalette = try defaultPalette()
        try Ghostty.check(ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, nil), .colors)
        try setColor(GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, colors.foreground)
        try setColor(GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, colors.background)
        try setColor(GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, colors.cursor)
        var palette = try defaultPalette()
        for (index, color) in colors.ansi.prefix(16).enumerated() {
            palette[index] = color
        }
        for (index, color) in colors.palette {
            palette[Int(index)] = color
        }
        var engine = palette.map(GhosttyColorRgb.init)
        try Ghostty.check(ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &engine), .colors)
        if let shape = colors.cursorStyle {
            var style = switch shape {
            case .block: GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK
            case .bar: GHOSTTY_TERMINAL_CURSOR_STYLE_BAR
            case .underline: GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE
            case .hollow: GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK_HOLLOW
            }
            try Ghostty.check(ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &style), .colors)
        } else {
            try Ghostty.check(ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, nil), .colors)
        }
        var blink = colors.cursorBlink ?? true
        try Ghostty.check(ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink), .colors)
        let current = (colors.foreground, colors.background, colors.cursor)
        let changed = previous.0 != current.0 || previous.1 != current.1 || previous.2 != current.2
            || previousPalette != palette
        if changed, try mode(DECMode.colorSchemeReport, .colors) {
            callbacks.ptyOutput.append(contentsOf: ColorSchemeReport.encode(background: colors.background))
        }
    }

    private func setColor(_ option: GhosttyTerminalOption, _ color: ThemeColor) throws {
        var value = GhosttyColorRgb(color)
        try Ghostty.check(ghostty_terminal_set(handle, option, &value), .colors)
    }

    private func defaultColor(_ data: GhosttyTerminalData) throws -> ThemeColor? {
        var color = GhosttyColorRgb()
        let result = ghostty_terminal_get(handle, data, &color)
        if result == GHOSTTY_NO_VALUE { return nil }
        try Ghostty.check(result, .colors)
        return color.rgb
    }

    private func defaultPalette() throws -> [ThemeColor] {
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        try Ghostty.check(ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, &palette), .colors)
        return palette.map(\.rgb)
    }

    /// Clears the primary screen and history. At a shell prompt the screen is
    /// emptied and a form feed is queued so the shell redraws its prompt;
    /// otherwise the cursor line stays. Does nothing on the alternate screen.
    @discardableResult
    public func clearScreen() throws -> Bool {
        guard try activeScreen(.history) != GHOSTTY_TERMINAL_SCREEN_ALTERNATE else { return false }
        if ghostty_terminal_clear_screen(handle) {
            callbacks.ptyOutput.append(0x0c)
        }
        primaryHistory = .success([])
        tracking.invalidate()
        tracking.count = 0
        redrawAll = true
        return true
    }

    // MARK: - State

    public func cursor() throws -> Cursor {
        let column = try value(GHOSTTY_TERMINAL_DATA_CURSOR_X, UInt16(0), .cursor)
        let row = try value(GHOSTTY_TERMINAL_DATA_CURSOR_Y, UInt16(0), .cursor)
        try updateRenderState(.cursor)
        var visible = true
        try Ghostty.check(ghostty_render_state_get(engineRender.state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible), .cursor)
        var style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
        try Ghostty.check(
            ghostty_render_state_get(engineRender.state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style), .cursor)
        let shape: CursorShape = switch style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: .hollow
        default: .block
        }
        return Cursor(shape: shape, row: row, col: column, visible: visible)
    }

    public func modes() throws -> Modes {
        var modes = Modes()
        modes.applicationCursorKeys = try mode(DECMode.cursorKeys, .mode)
        modes.bracketedPaste = try mode(DECMode.bracketedPaste, .mode)
        return modes
    }

    public func inputModes() throws -> InputModes {
        var modes = InputModes()
        modes.mouseTracking = try value(GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, false, .mode)
        modes.alternateScroll = try mode(DECMode.alternateScroll, .mode)
            && activeScreen(.mode) == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
        modes.focusEvents = try mode(DECMode.focusEvents, .mode)
        return modes
    }

    public func cursorBlinking() throws -> Bool {
        try mode(DECMode.cursorBlinking, .cursor)
    }

    /// The program is holding the screen (mode 2026) while it draws a frame.
    public func synchronizedOutput() throws -> Bool {
        try mode(DECMode.synchronizedOutput, .mode)
    }

    /// Ends a hold a program never released.
    public func endSynchronizedOutput() throws {
        var config = GhosttyTerminalModeConfig(mode: DECMode.synchronizedOutput, value: false)
        try Ghostty.check(ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_MODE, &config), .mode)
    }

    /// The shell's cursor is at a prompt or its input (OSC 133).
    public func cursorAtPrompt() throws -> Bool {
        try value(GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT, false, .cursor)
    }

    // MARK: - Input

    public func encodeKey(_ key: KeyEvent) throws -> Data {
        try keyboard.encode(key, terminal: handle)
    }

    /// Mouse reports for tracking programs. Without tracking, a wheel on the
    /// alternate screen with alternate scroll (1007) becomes three arrow keys.
    public func encodeMouse(_ event: MouseEvent) throws -> Data {
        let modes = try inputModes()
        guard modes.mouseTracking else {
            mouse.reset()
            guard modes.alternateScroll, event.action == .scroll, let direction = event.scroll else { return Data() }
            let prefix = try self.modes().applicationCursorKeys ? UInt8(ascii: "O") : UInt8(ascii: "[")
            let suffix = direction == .up ? UInt8(ascii: "A") : UInt8(ascii: "B")
            return Data([0x1b, prefix, suffix, 0x1b, prefix, suffix, 0x1b, prefix, suffix])
        }
        return try mouse.encode(event, size: size, terminal: handle)
    }

    /// Pasted text, wrapped in bracketed paste markers when the program asked.
    public func encodePaste(_ text: Data) throws -> Data {
        try PasteEncoding.encode(text, bracketed: modes().bracketedPaste)
    }

    public func encodePaste(_ text: String) throws -> Data {
        try encodePaste(Data(text.utf8))
    }

    /// Typed or composed text. Text with a line break is sent as a paste so
    /// a dictated paragraph doesn't run line by line.
    public func encodeText(_ text: String) throws -> Data {
        guard text.contains(where: \.isNewline) else { return Data(text.utf8) }
        return try encodePaste(text)
    }

    public func encodeFocus(_ focused: Bool) throws -> Data {
        guard try inputModes().focusEvents else { return Data() }
        return Data(focused ? [0x1b, UInt8(ascii: "["), UInt8(ascii: "I")] : [0x1b, UInt8(ascii: "["), UInt8(ascii: "O")])
    }

    // MARK: - Screen

    /// Rows that changed since the last call, using the engine's dirty rows
    /// and a per-row content hash. After a resize or clear, every row.
    public func render() throws -> [Row] {
        try updateRenderState(.render)
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        try Ghostty.check(ghostty_render_state_get(engineRender.state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty), .render)
        let retryLinks = rowLinks.contains { !$0.complete }
        if !redrawAll, dirty == GHOSTTY_RENDER_STATE_DIRTY_FALSE, !retryLinks { return [] }
        let all = redrawAll || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL
        let count = try renderRows()
        if rowHashes.count != count {
            rowHashes = Array(rowHashes.prefix(count)) + Array(repeating: nil, count: max(0, count - rowHashes.count))
            rowLinks = Array(rowLinks.prefix(count))
                + Array(repeating: CachedLinks(), count: max(0, count - rowLinks.count))
        }
        var linkCount = rowLinks.reduce(0) { $0 + $1.spans.count }
        var changed: [Row] = []
        try forEachRow { index, rows in
            var rowDirty = false
            ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
            let cached = rowLinks[index]
            guard all || rowDirty || !cached.complete else { return }
            let budget = maxHyperlinkSpans - (linkCount - cached.spans.count)
            let content = try rowReader.read(
                rows, y: UInt32(index), terminal: handle, hyperlinks: hyperlinks, linkBudget: budget)
            linkCount += content.links.count - cached.spans.count
            let linksChanged = content.links != cached.spans
            rowLinks[index] = CachedLinks(spans: content.links, complete: content.linksComplete)
            let hash = hashRuns(content.runs)
            guard redrawAll || linksChanged || rowHashes[index] != hash else { return }
            rowHashes[index] = hash
            changed.append(Row(index: UInt16(index), runs: content.runs))
        }
        try Ghostty.check(ghostty_render_state_clean(engineRender.state), .render)
        redrawAll = false
        return changed
    }

    /// Every row of the screen, without affecting what `render()` reports next.
    public func fullRender() throws -> [Row] {
        try readViewport(.render).rows
    }

    /// Rows of the screen that start a shell prompt.
    public func screenPrompts() throws -> [UInt16] {
        try updateRenderState(.render)
        var prompts: [UInt16] = []
        try forEachRow { index, rows in
            if RowReader.isPrompt(rows) {
                prompts.append(UInt16(index))
            }
        }
        return prompts
    }

    /// OSC 8 hyperlinks of the screen as of the last `render()`.
    public func hyperlinkRows() -> [HyperlinkRow] {
        rowLinks.enumerated().compactMap { index, links in
            links.spans.isEmpty ? nil : HyperlinkRow(row: UInt16(index), spans: links.spans)
        }
    }

    /// The URI of a `Style.hyperlink` id.
    public func hyperlinkURI(_ id: UInt32) -> String? {
        hyperlinks.uri(for: id)
    }

    /// Text of the bottom of the screen for agent detection (at most 80 rows, 128 KiB).
    public func detectionText() throws -> String {
        let rows = try readViewport(.render).rows
        var text = ""
        for row in rows.suffix(80) {
            for run in row.runs {
                text += run.text
            }
            text += "\n"
        }
        while text.utf8.count > 128 * 1024, let newline = text.firstIndex(of: "\n") {
            text.removeSubrange(...newline)
        }
        return text
    }

    public func graphics() throws -> Graphics {
        try updateRenderState(.graphics)
        return try graphicsCache.snapshot(terminal: handle, renderState: engineRender.state, cell: cellSize)
    }

    /// Moves the engine viewport. History paging does not need this.
    public func scroll(_ target: ScrollTarget) {
        var viewport = GhosttyTerminalScrollViewport()
        switch target {
        case .top:
            viewport.tag = GHOSTTY_SCROLL_VIEWPORT_TOP
        case .bottom:
            viewport.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        case let .delta(rows):
            viewport.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
            viewport.value.delta = rows
        case let .row(row):
            viewport.tag = GHOSTTY_SCROLL_VIEWPORT_ROW
            viewport.value.row = max(0, row)
        case let .prompt(prompts):
            viewport.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA_PROMPT
            viewport.value.delta_prompt = prompts
        }
        ghostty_terminal_scroll_viewport(handle, viewport)
    }

    // MARK: - Memory

    /// Compresses history. Returns true when more incremental work remains.
    @discardableResult
    public func compress(_ mode: CompressionMode = .full) throws -> Bool {
        var result = GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE
        let engineMode = mode == .full
            ? GHOSTTY_TERMINAL_COMPRESSION_MODE_FULL : GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL
        try Ghostty.check(ghostty_terminal_compress(handle, engineMode, &result), .compress)
        return result == GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING
    }

    /// Changes whenever compression-relevant state changes; restart the idle
    /// timer when it does and compress once it has been quiet.
    public func compressionActivity() throws -> UInt64 {
        var activity: UInt64 = 0
        try Ghostty.check(ghostty_terminal_compression_activity(handle, &activity), .compress)
        return activity
    }

    // MARK: - Engine access

    func value<T: BitwiseCopyable>(_ data: GhosttyTerminalData, _ initial: T, _ step: TerminalStep) throws -> T {
        var value = initial
        try Ghostty.check(ghostty_terminal_get(handle, data, &value), step)
        return value
    }

    func mode(_ mode: GhosttyMode, _ step: TerminalStep) throws -> Bool {
        var config = GhosttyTerminalModeConfig(mode: mode, value: false)
        try Ghostty.check(ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MODE, &config), step)
        return config.value
    }

    func activeScreen(_ step: TerminalStep) throws -> GhosttyTerminalScreen {
        try value(GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, GHOSTTY_TERMINAL_SCREEN_PRIMARY, step)
    }

    private func string(_ data: GhosttyTerminalData) throws -> String {
        Ghostty.string(try value(data, GhosttyString(), .render))
    }

    func updateRenderState(_ step: TerminalStep) throws {
        try Ghostty.check(ghostty_render_state_update(engineRender.state, handle), step)
    }

    func renderRows() throws -> Int {
        var rows: UInt16 = 0
        try Ghostty.check(ghostty_render_state_get(engineRender.state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows), .render)
        return Int(rows)
    }

    /// Visits each row of the current render state with the row iterator.
    func forEachRow(_ body: (Int, GhosttyRenderStateRowIterator) throws -> Void) throws {
        var iterator: GhosttyRenderStateRowIterator? = engineRender.rows
        try Ghostty.check(ghostty_render_state_get(engineRender.state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator), .render)
        var index = 0
        while ghostty_render_state_row_iterator_next(engineRender.rows) {
            try body(index, engineRender.rows)
            index += 1
        }
    }

    /// Every row of the viewport and the rows that start a prompt.
    func readViewport(_ step: TerminalStep) throws -> (rows: [Row], prompts: [UInt16]) {
        try updateRenderState(step)
        var rows: [Row] = []
        rows.reserveCapacity(Int(size.rows))
        var prompts: [UInt16] = []
        try forEachRow { index, iterator in
            let content = try rowReader.read(
                iterator, y: UInt32(index), terminal: handle, hyperlinks: hyperlinks, linkBudget: 0)
            if content.prompt {
                prompts.append(UInt16(index))
            }
            rows.append(Row(index: UInt16(index), runs: content.runs))
        }
        return (rows, prompts)
    }
}

/// The render state and its row iterator, reused for every frame.
final class RenderResources {
    let state: GhosttyRenderState
    let rows: GhosttyRenderStateRowIterator

    init() throws {
        var state: GhosttyRenderState?
        try Ghostty.check(ghostty_render_state_new(nil, &state), .create)
        guard let state else { throw TerminalError(.create, .engine(GHOSTTY_OUT_OF_MEMORY.rawValue)) }
        var rows: GhosttyRenderStateRowIterator?
        guard ghostty_render_state_row_iterator_new(nil, &rows) == GHOSTTY_SUCCESS, let rows else {
            ghostty_render_state_free(state)
            throw TerminalError(.create, .engine(GHOSTTY_OUT_OF_MEMORY.rawValue))
        }
        self.state = state
        self.rows = rows
    }

    deinit {
        ghostty_render_state_row_iterator_free(rows)
        ghostty_render_state_free(state)
    }
}

struct CachedLinks {
    var spans: [HyperlinkSpan] = []
    var complete = true
}

/// Spots `CSI ? 47 h`, `CSI ? 1047 h` and `CSI ? 1049 h` (alone or among
/// other modes) across reads, so history can be captured before the switch.
struct ScreenSwitch {
    private enum State {
        case ground
        case escape
        case csi
        case privateMode(parameter: UInt32, alternate: Bool)
    }

    private var state = State.ground

    /// True when `byte` is the final `h` of an alternate-screen switch.
    mutating func advance(_ byte: UInt8) -> Bool {
        if byte == 0x1b {
            state = .escape
            return false
        }
        if byte == 0x9b {
            state = .csi
            return false
        }
        switch byte {
        case 0x00...0x17, 0x19, 0x1c...0x1f, 0x7f: return false
        default: break
        }
        switch state {
        case .escape where byte == UInt8(ascii: "["):
            state = .csi
        case .csi where byte == UInt8(ascii: "?"):
            state = .privateMode(parameter: 0, alternate: false)
        case let .privateMode(parameter, alternate) where (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte):
            let scaled = UInt64(parameter) * 10 + UInt64(byte - UInt8(ascii: "0"))
            state = .privateMode(parameter: UInt32(min(scaled, UInt64(UInt32.max))), alternate: alternate)
        case let .privateMode(parameter, alternate) where byte == UInt8(ascii: ";"):
            state = .privateMode(parameter: 0, alternate: alternate || Self.isAlternate(parameter))
        case let .privateMode(parameter, alternate) where byte == UInt8(ascii: "h"):
            state = .ground
            return alternate || Self.isAlternate(parameter)
        default:
            state = .ground
        }
        return false
    }

    private static func isAlternate(_ mode: UInt32) -> Bool {
        mode == 47 || mode == 1047 || mode == 1049
    }
}
