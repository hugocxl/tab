import CGhosttyVT
import Foundation
import TabProtocol

/// Merges cells into runs of one style. Consecutive single-width ASCII cells
/// share a run; any other cell gets its own run so clients can map runs back
/// to cells without Unicode width tables. Trailing default blanks are dropped.
struct RunBuilder {
    private(set) var runs: [Run] = []
    private var bytes: [UInt8] = []
    private var width: UInt16 = 0
    private var style = Style()
    private var open = false
    private var mergeable = false

    init() {
        bytes.reserveCapacity(256)
    }

    mutating func reset() {
        runs = []
        bytes.removeAll(keepingCapacity: true)
        open = false
    }

    mutating func push(_ text: UnsafeBufferPointer<UInt8>, width cellWidth: UInt16, style cellStyle: Style) {
        let ascii = text.count == Int(cellWidth) && text.allSatisfy { $0 < 0x80 }
        if open, mergeable, ascii, cellStyle == style {
            bytes.append(contentsOf: text)
            width &+= cellWidth
            return
        }
        flush()
        bytes.append(contentsOf: text)
        width = cellWidth
        style = cellStyle
        mergeable = ascii
        open = true
    }

    mutating func finish() -> [Run] {
        if open, style == Style() {
            while bytes.last == UInt8(ascii: " ") {
                bytes.removeLast()
                width -= 1
            }
            if bytes.isEmpty {
                open = false
            }
        }
        flush()
        while let last = runs.last, last.style == Style(), last.text.hasSuffix(" ") {
            var run = runs.removeLast()
            let trimmed = run.text.reversed().drop { $0 == " " }
            let blanks = run.text.count - trimmed.count
            run.text = String(trimmed.reversed())
            run.width -= UInt16(clamping: blanks)
            if !run.text.isEmpty {
                runs.append(run)
                break
            }
        }
        let result = runs
        reset()
        return result
    }

    private mutating func flush() {
        guard open else { return }
        runs.append(Run(text: String(decoding: bytes, as: UTF8.self), width: width, style: style))
        bytes.removeAll(keepingCapacity: true)
        open = false
    }
}

/// Session-scoped ids for OSC 8 hyperlink URIs, carried in `Style.hyperlink`.
final class HyperlinkTable {
    private static let limit = 16384
    private var ids: [String: UInt32] = [:]
    private(set) var uris: [UInt32: String] = [:]
    private var next: UInt32 = 1

    func id(for uri: String) -> UInt32 {
        if let id = ids[uri] { return id }
        if ids.count >= Self.limit {
            ids.removeAll(keepingCapacity: true)
            uris.removeAll(keepingCapacity: true)
        }
        let id = next
        next = next == UInt32.max ? 1 : next + 1
        ids[uri] = id
        uris[id] = uri
        return id
    }

    func uri(for id: UInt32) -> String? {
        uris[id]
    }
}

/// One row read from the render state.
struct RowContent {
    var runs: [Run]
    var links: [HyperlinkSpan]
    /// False when the link budget ran out before the end of the row.
    var linksComplete: Bool
    /// The row starts a shell prompt (OSC 133) and is not a wrapped continuation.
    var prompt: Bool
}

/// Reads render-state rows into runs, reusing its cell iterator and buffers.
final class RowReader {
    let cells: GhosttyRenderStateRowCells
    private var builder = RunBuilder()
    private var graphemes: UnsafeMutablePointer<UInt8>
    private var graphemeCapacity = 64
    private let uri = UnsafeMutablePointer<UInt8>.allocate(capacity: maxHyperlinkURI)
    private var lastURI: [UInt8] = []
    private var lastLink: UInt32 = 0

    init() throws {
        var cells: GhosttyRenderStateRowCells?
        try Ghostty.check(ghostty_render_state_row_cells_new(nil, &cells), .create)
        guard let cells else { throw TerminalError(.create, .engine(GHOSTTY_OUT_OF_MEMORY.rawValue)) }
        self.cells = cells
        graphemes = .allocate(capacity: graphemeCapacity)
    }

    deinit {
        ghostty_render_state_row_cells_free(cells)
        graphemes.deallocate()
        uri.deallocate()
    }

    /// Reads the row the iterator points at. `y` is its viewport row, used to
    /// look up hyperlink URIs.
    func read(
        _ rows: GhosttyRenderStateRowIterator,
        y: UInt32,
        terminal: GhosttyTerminal,
        hyperlinks: HyperlinkTable,
        linkBudget: Int
    ) throws -> RowContent {
        var raw: GhosttyRow = 0
        try Ghostty.check(ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &raw), .render)
        var hasLinks = false
        ghostty_row_get(raw, GHOSTTY_ROW_DATA_HYPERLINK, &hasLinks)
        var cells: GhosttyRenderStateRowCells? = self.cells
        try Ghostty.check(ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells), .render)

        var links: [HyperlinkSpan] = []
        var linksComplete = true
        var column: UInt16 = 0
        lastURI.removeAll(keepingCapacity: true)
        lastLink = 0
        while ghostty_render_state_row_cells_next(self.cells) {
            defer { column &+= 1 }
            var cell: GhosttyCell = 0
            try Ghostty.check(
                ghostty_render_state_row_cells_get(self.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &cell), .render)
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
            let width: UInt16 = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1

            var style = try cellStyle(cell)
            if hasLinks, let link = hyperlink(cell, x: column, y: y, terminal: terminal, table: hyperlinks) {
                style.hyperlink = link.id
                if let last = links.last, last.end == column, last.uri == link.uri {
                    links[links.count - 1].end = column + width
                } else if links.count < linkBudget {
                    links.append(HyperlinkSpan(start: column, end: column + width, uri: link.uri))
                } else {
                    linksComplete = false
                }
            }
            try appendText(cell, width: width, style: style)
        }

        var semantic = GHOSTTY_ROW_SEMANTIC_NONE
        ghostty_row_get(raw, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &semantic)
        var continuation = false
        ghostty_row_get(raw, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &continuation)
        return RowContent(
            runs: builder.finish(),
            links: links,
            linksComplete: linksComplete,
            prompt: semantic == GHOSTTY_ROW_SEMANTIC_PROMPT && !continuation)
    }

    /// Only reads the semantic prompt flag of the row the iterator points at.
    static func isPrompt(_ rows: GhosttyRenderStateRowIterator) -> Bool {
        var raw: GhosttyRow = 0
        guard ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &raw) == GHOSTTY_SUCCESS else {
            return false
        }
        var semantic = GHOSTTY_ROW_SEMANTIC_NONE
        ghostty_row_get(raw, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &semantic)
        var continuation = false
        ghostty_row_get(raw, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &continuation)
        return semantic == GHOSTTY_ROW_SEMANTIC_PROMPT && !continuation
    }

    private func cellStyle(_ cell: GhosttyCell) throws -> Style {
        var styled = false
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_STYLING, &styled)
        var style = Style()
        if styled {
            var engine = Ghostty.style()
            try Ghostty.check(
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &engine), .render)
            style = Style(engine)
        }
        var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag)
        if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE {
            var index: GhosttyColorPaletteIndex = 0
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_COLOR_PALETTE, &index)
            style.bg = .indexed(index)
        } else if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB {
            var rgb = GhosttyColorRgb()
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_COLOR_RGB, &rgb)
            style.bg = .rgb(rgb.r, rgb.g, rgb.b)
        }
        return style
    }

    private func appendText(_ cell: GhosttyCell, width: UInt16, style: Style) throws {
        var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag)
        if tag == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME {
            let length = try graphemeBytes()
            if length > 0 {
                builder.push(UnsafeBufferPointer(start: graphemes, count: length), width: width, style: style)
                return
            }
        }
        var codepoint: UInt32 = 0
        if tag == GHOSTTY_CELL_CONTENT_CODEPOINT || tag == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME {
            ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint)
        }
        let scalar = Unicode.Scalar(codepoint).flatMap { $0.value == 0 ? nil : $0 } ?? " "
        var count = 0
        UTF8.encode(scalar) { byte in
            graphemes[count] = byte
            count += 1
        }
        builder.push(UnsafeBufferPointer(start: graphemes, count: count), width: width, style: style)
    }

    private func graphemeBytes() throws -> Int {
        var buffer = GhosttyBuffer(ptr: graphemes, cap: graphemeCapacity, len: 0)
        var result = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer)
        if result == GHOSTTY_OUT_OF_SPACE {
            graphemes.deallocate()
            graphemeCapacity = max(buffer.len, graphemeCapacity * 2)
            graphemes = .allocate(capacity: graphemeCapacity)
            buffer = GhosttyBuffer(ptr: graphemes, cap: graphemeCapacity, len: 0)
            result = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer)
        }
        try Ghostty.check(result, .render)
        return buffer.len
    }

    private func hyperlink(
        _ cell: GhosttyCell, x: UInt16, y: UInt32, terminal: GhosttyTerminal, table: HyperlinkTable
    ) -> (id: UInt32, uri: String)? {
        var linked = false
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &linked)
        guard linked else { return nil }
        var ref = Ghostty.gridRef()
        guard ghostty_terminal_grid_ref(terminal, Ghostty.point(GHOSTTY_POINT_TAG_VIEWPORT, x: x, y: y), &ref)
            == GHOSTTY_SUCCESS
        else { return nil }
        var length = 0
        guard ghostty_grid_ref_hyperlink_uri(&ref, uri, maxHyperlinkURI, &length) == GHOSTTY_SUCCESS,
              length > 0
        else { return nil }
        let bytes = UnsafeBufferPointer(start: uri, count: length)
        if lastLink != 0, bytes.elementsEqual(lastURI) {
            return (lastLink, table.uri(for: lastLink) ?? "")
        }
        guard let text = String(bytes: bytes, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        lastURI.removeAll(keepingCapacity: true)
        lastURI.append(contentsOf: bytes)
        lastLink = table.id(for: text)
        return (lastLink, text)
    }
}

extension Style {
    init(_ engine: GhosttyStyle) {
        self.init()
        fg = Color(engine.fg_color)
        bg = Color(engine.bg_color)
        underlineColor = Color(engine.underline_color)
        bold = engine.bold
        italic = engine.italic
        faint = engine.faint
        inverse = engine.inverse
        invisible = engine.invisible
        strikethrough = engine.strikethrough
        overline = engine.overline
        underline = switch Int(engine.underline) {
        case Int(GHOSTTY_SGR_UNDERLINE_NONE.rawValue): .none
        case Int(GHOSTTY_SGR_UNDERLINE_DOUBLE.rawValue): .double
        case Int(GHOSTTY_SGR_UNDERLINE_CURLY.rawValue): .curly
        case Int(GHOSTTY_SGR_UNDERLINE_DOTTED.rawValue): .dotted
        case Int(GHOSTTY_SGR_UNDERLINE_DASHED.rawValue): .dashed
        default: .single
        }
    }
}

extension Color {
    init(_ engine: GhosttyStyleColor) {
        switch engine.tag {
        case GHOSTTY_STYLE_COLOR_PALETTE: self = .indexed(engine.value.palette)
        case GHOSTTY_STYLE_COLOR_RGB: self = .rgb(engine.value.rgb.r, engine.value.rgb.g, engine.value.rgb.b)
        default: self = .default
        }
    }
}

func hashRuns(_ runs: [Run]) -> Int {
    var hasher = Hasher()
    hasher.combine(runs)
    return hasher.finalize()
}
