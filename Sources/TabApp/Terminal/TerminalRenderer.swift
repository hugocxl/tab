import CoreGraphics
import CoreText
import Foundation
import TabClient
import TabCore
import TabProtocol

/// How the cursor is drawn this time.
public struct TerminalCursorState: Equatable, Sendable {
    /// Shown: focused, live, following output, and in the visible blink phase.
    public var visible: Bool
    public var shape: CursorShape
    /// Visible row and column.
    public var row: Int
    public var column: Int
    /// The configured bar, underline and outline thickness.
    public var thickness: CellHeight

    public init(visible: Bool = false, shape: CursorShape = .block, row: Int = 0, column: Int = 0,
                thickness: CellHeight = .natural) {
        self.visible = visible
        self.shape = shape
        self.row = row
        self.column = column
        self.thickness = thickness
    }
}

/// Everything one draw reads. The grid is borrowed for the draw only.
public struct TerminalRenderState {
    public var grid: RunGrid
    public var layout: TerminalLayout
    public var metrics: TerminalMetrics
    public var fonts: TerminalFontSet
    public var palette: TerminalPalette
    public var cursor: TerminalCursorState
    public var selection: TerminalSelection?
    public var find: TerminalFind?
    /// The Cmd-hovered link, underlined.
    public var link: TerminalLinkCandidate?
    /// Input method text being composed, drawn at the cursor.
    public var markedText: String?

    public init(grid: RunGrid, layout: TerminalLayout, metrics: TerminalMetrics, fonts: TerminalFontSet,
                palette: TerminalPalette, cursor: TerminalCursorState = TerminalCursorState(),
                selection: TerminalSelection? = nil, find: TerminalFind? = nil, link: TerminalLinkCandidate? = nil,
                markedText: String? = nil) {
        self.grid = grid
        self.layout = layout
        self.metrics = metrics
        self.fonts = fonts
        self.palette = palette
        self.cursor = cursor
        self.selection = selection
        self.find = find
        self.link = link
        self.markedText = markedText
    }

    /// The content row (history then screen) shown at the top.
    public var firstRow: Int { grid.history.count - grid.scrollOffset }
}

/// Draws a terminal grid into a Core Graphics context. Kept behind a protocol
/// so a Metal renderer can replace Core Text without touching the model.
@MainActor public protocol TerminalRenderer: AnyObject {
    /// Whether the terminal background covers what is behind it.
    var isBackgroundOpaque: Bool { get }
    /// Prepares changed row surfaces before AppKit enters draw(_:).
    func prepare(_ state: TerminalRenderState)
    /// Blits the prepared rows touching `dirty` (view coordinates, y down).
    func draw(_ state: TerminalRenderState, dirty: [CGRect], in context: CGContext)
    /// Forgets every cached row and image (fonts or colors changed).
    func invalidateAll()
    /// Forgets the cached layout of visible rows, which are laid out again
    /// unless their content is still cached.
    func invalidate(rows: IndexSet)
}

/// The Core Text renderer: one `CTLine` laid out per distinct row content and
/// cached as cell-aligned glyph runs, one rectangle per background color run,
/// decorations as rectangles and paths, and kitty images as `CGImage`s.
@MainActor public final class CoreTextRenderer: TerminalRenderer {
    /// Rows laid out since creation, for tests and profiling.
    public private(set) var layoutCount = 0
    public private(set) var drawCount = 0
    var cachedLineCount: Int { cache.count }
    public private(set) var rasterCount = 0
    public private(set) var glyphLayoutCount = 0
    private var glyphCache: [GlyphKey: [GlyphRun]] = [:]
    private(set) var glyphBytes = 0
    var cachedGlyphCount: Int { glyphCache.count }
    static let glyphLimit = 1024
    static let glyphByteLimit = 4 * 1024 * 1024
    public var onLayoutRow: ((Int) -> Void)?
    public var onRasterRow: ((Int) -> Void)?
    public private(set) var surfaceAllocationCount = 0
    /// Optional profiling hook; absent on the normal rendering path.
    public var onDrawRow: ((Int) -> Void)?
    public var onInvalidateRows: ((IndexSet) -> Void)?
    /// Hard limits for retained layout payload, independent of scrollback size.
    static let lineLimit = 512
    static let lineByteLimit = 8 * 1024 * 1024
    static let imageByteLimit = 32 * 1024 * 1024
    private(set) var layoutBytes = 0
    var surfaceBytes: Int { surfaces.reduce(0) { $0 + ($1?.bytes ?? 0) } }
    var imageBytes: Int { images.values.reduce(0) { $0 + $1.bytesPerRow * $1.height } }
    private var surfaces: [RowSurface?] = []
    private var renderLayout: TerminalLayout?
    private var renderMetrics: TerminalMetrics?
    private var graphics: Graphics?
    private var preparedImages: [ImagePlacement] = []
    private var surfaceKeys: [PaintKey?] = []
    public private(set) var isBackgroundOpaque = true

    private var slots: [PreparedRow?] = []
    private var cache: [RowKey: PreparedRow] = [:]
    private var colors: [UInt64: CGColor] = [:]
    private var images: [ImageKey: CGImage] = [:]
    private var stamp: UInt64 = 0
    private var palette: TerminalPalette?
    private var fontGeneration: UInt64 = 0

    public init() {}

    public func invalidateAll() {
        slots.removeAll(keepingCapacity: true)
        cache.removeAll(keepingCapacity: true)
        layoutBytes = 0
        glyphBytes = 0
        glyphCache.removeAll(keepingCapacity: true)
        images.removeAll(keepingCapacity: true)
        colors.removeAll(keepingCapacity: true)
        surfaces.removeAll(keepingCapacity: true)
        surfaceKeys.removeAll(keepingCapacity: true)
        preparedImages.removeAll(keepingCapacity: true)
        graphics = nil
        renderLayout = nil
    }

    public func invalidate(rows: IndexSet) {
        onInvalidateRows?(rows)
        for row in rows where row < slots.count { slots[row] = nil }
    }

    public func prepare(_ state: TerminalRenderState) {
        let configurationChanged = palette != state.palette || fontGeneration != state.fonts.generation
            || renderLayout != state.layout || renderMetrics != state.metrics
        if configurationChanged {
            invalidateAll()
            palette = state.palette
            fontGeneration = state.fonts.generation
            renderLayout = state.layout
            renderMetrics = state.metrics
        }
        let rowCount = Int(state.layout.viewport.rows)
        if slots.count != rowCount {
            slots = Array(repeating: nil, count: rowCount)
            surfaces = Array(repeating: nil, count: rowCount)
            surfaceKeys = Array(repeating: nil, count: rowCount)
        }
        let graphicsChanged = graphics != state.grid.graphics
        if graphicsChanged || configurationChanged {
            graphics = state.grid.graphics
            prepareImages(state)
        }
        isBackgroundOpaque = state.palette.isOpaque
        stamp &+= 1
        for row in 0..<rowCount {
            let content = state.firstRow + row
            let runs = state.grid.contentRow(content) ?? []
            let selected = selectedColumns(state, row: content - state.grid.history.count)
            let item = preparedRow(runs, selected: selected, row: row, state: state)
            let selection = state.selection?.columns(row: content - state.grid.history.count, in: state.grid)
            let link = state.link.flatMap { $0.row == content - state.grid.history.count ? $0 : nil }
            let cursor = state.cursor.visible && state.cursor.row == row ? state.cursor : nil
            let marked = state.cursor.row == row ? state.markedText : nil
            let key = PaintKey(row: item.key, selection: selection, find: state.find, link: link,
                               cursor: cursor, marked: marked, scroll: preparedImages.isEmpty ? 0 : state.grid.scrollOffset)
            guard graphicsChanged || surfaceKeys[row] != key || surfaces[row] == nil else { continue }
            let rect = state.layout.rowRect(row)
            if surfaces[row]?.rect != rect {
                surfaces[row] = RowSurface(rect: rect, scale: state.metrics.scale)
                surfaceAllocationCount += 1
            }
            guard let surface = surfaces[row] else { continue }
            paint(item, row: row, state: state, in: surface.context)
            surfaceKeys[row] = key
            rasterCount += 1
            onRasterRow?(row)
        }
        trimLayouts()
    }

    public func draw(_ state: TerminalRenderState, dirty: [CGRect], in context: CGContext) {
        guard let layout = renderLayout else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        for row in surfaces.indices {
            guard let surface = surfaces[row],
                  dirty.contains(where: { $0.intersects(layout.rowRect(row)) }) else { continue }
            context.saveGState()
            context.translateBy(x: surface.rect.minX, y: surface.rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(surface.layer, in: CGRect(origin: .zero, size: surface.rect.size))
            context.restoreGState()
            drawCount += 1
            onDrawRow?(row)
        }
    }

    private func paint(_ item: PreparedRow, row: Int, state: TerminalRenderState, in context: CGContext) {
        let rect = state.layout.rowRect(row)
        context.clear(rect)
        context.setFillColor(color(state.palette.background, alpha: CGFloat(state.palette.backgroundOpacity)))
        context.fill(rect)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        drawImages(state, row: row, z: Int64.min..<(-1_073_741_824), in: context)
        drawBackgrounds(item, row: row, state: state, backgroundAlpha: CGFloat(state.palette.backgroundOpacity), in: context)
        drawImages(state, row: row, z: -1_073_741_824..<0, in: context)
        drawHighlights(state, row: row, content: state.firstRow + row, in: context)
        let top = state.layout.grid.minY + CGFloat(row) * state.layout.cellHeight
        drawDecorations(item, top: top, state: state, in: context)
        context.saveGState()
        context.clip(to: state.layout.grid)
        drawGlyphs(item, origin: CGPoint(x: state.layout.grid.minX, y: top + state.metrics.baseline),
                   fonts: state.fonts, override: nil, in: context)
        context.restoreGState()
        drawImages(state, row: row, z: 0..<Int64.max, in: context)
        drawLink(state, rows: IndexSet(integer: row), in: context)
        if state.cursor.visible, state.cursor.row == row { drawCursor(state, row: item, in: context) }
        if let text = state.markedText, !text.isEmpty, state.cursor.row == row {
            drawMarkedText(text, state: state, in: context)
        }
    }

    private func trimLayouts() {
        while cache.count > Self.lineLimit || layoutBytes > Self.lineByteLimit {
            guard let oldest = cache.min(by: { $0.value.stamp < $1.value.stamp }) else { return }
            layoutBytes -= oldest.value.bytes
            cache.removeValue(forKey: oldest.key)
        }
    }

    private func selectedColumns(_ state: TerminalRenderState, row: Int) -> Range<UInt16>? {
        guard state.palette.selectionForeground != nil, let selection = state.selection else { return nil }
        let columns = selection.columns(row: row, in: state.grid)
        return columns.isEmpty ? nil : columns
    }

    /// The cached layout of a row, laid out again only for new content.
    private func preparedRow(_ runs: [Run], selected: Range<UInt16>?, row: Int, state: TerminalRenderState)
        -> PreparedRow {
        if row < slots.count, let slot = slots[row], slot.key.selected == selected, slot.key.runs == runs {
            slot.stamp = stamp
            return slot
        }
        let key = RowKey(runs: runs, selected: selected)
        let item: PreparedRow
        if let cached = cache[key] {
            item = cached
        } else {
            item = layoutRow(key, state: state)
            cache[key] = item
            layoutBytes += item.bytes
            layoutCount += 1
            onLayoutRow?(row)
        }
        item.stamp = stamp
        if row < slots.count { slots[row] = item }
        return item
    }

    /// Lays out one row: background spans merged by color, decorations, and
    /// glyphs placed on their cells.
    func layoutRow(_ key: RowKey, state: TerminalRenderState) -> PreparedRow {
        let palette = state.palette
        let fonts = state.fonts
        let cols = state.layout.viewport.cols
        let item = PreparedRow(key: key)
        item.backgrounds = Self.backgroundSpans(key.runs, palette: palette, cols: cols)
        item.fullWidth = Self.coversRow(key.runs, palette: palette, cols: cols)
        var text = ""
        var length = 0
        var columns: [UInt16] = []
        var segments: [Segment] = []
        var column: UInt16 = 0
        let cellWidth = state.layout.cellWidth
        var pending = PendingGlyphs()
        for run in key.runs {
            let start = column
            column &+= run.width
            guard start < cols else { break }
            let colors = palette.style(run.style)
            let foreground = colors.foreground
            decorate(item, run.style, start..<min(column, cols), foreground: foreground, palette: palette)
            if run.style.invisible || run.text.utf8.allSatisfy({ $0 == 0x20 }) { continue }
            let simple = TerminalCells.isSimple(run)
            let face = fonts.face(bold: run.style.bold, italic: run.style.italic)
            let alpha: CGFloat = run.style.faint ? 0.5 : 1
            let parts = key.selected == nil ? [Part(text: run.text[...], column: start, selected: false)]
                : split(run, start: start, simple: simple, selected: key.selected)
            for part in parts {
                var color = foreground
                if part.selected, let selection = palette.selectionForeground {
                    color = palette.resolveCell(selection, foreground: colors.foreground, background: colors.background)
                }
                if simple, let ascii = face.ascii, !fonts.mapsASCII {
                    if !pending.matches(face, color, alpha) {
                        pending.flush(into: item)
                        pending.start(face, color, alpha)
                    }
                    pending.append(part.text, column: Int(part.column), glyphs: ascii, cellWidth: cellWidth)
                    continue
                }
                if !simple {
                    pending.flush(into: item)
                    let shapes = shapedCell(String(part.text), bold: run.style.bold, italic: run.style.italic, state: state)
                    for var glyphs in shapes {
                        glyphs.color = color
                        glyphs.alpha = alpha
                        glyphs.positions = glyphs.positions.map {
                            CGPoint(x: $0.x + CGFloat(part.column) * cellWidth, y: $0.y)
                        }
                        item.glyphs.append(glyphs)
                    }
                    continue
                }
                let begin = length
                text += part.text
                let added = part.text.utf16.count
                length += added
                if simple {
                    for offset in 0..<added { columns.append(part.column &+ UInt16(offset)) }
                } else {
                    columns.append(contentsOf: repeatElement(part.column, count: added))
                }
                segments.append(Segment(range: CFRange(location: begin, length: added), color: color,
                                        alpha: alpha, bold: run.style.bold, italic: run.style.italic))
            }
        }
        pending.flush(into: item)
        guard !segments.isEmpty else { return item }
        let string = CFAttributedStringCreateMutable(nil, 0)!
        CFAttributedStringBeginEditing(string)
        CFAttributedStringReplaceString(string, CFRange(location: 0, length: 0), text as CFString)
        for (index, segment) in segments.enumerated() {
            let face = fonts.face(bold: segment.bold, italic: segment.italic)
            let attributes = [kCTFontAttributeName: face.font, Self.segmentKey: index as CFNumber] as CFDictionary
            CFAttributedStringSetAttributes(string, segment.range, attributes, true)
        }
        if fonts.hasMappedRanges {
            applyMappedFonts(string, text: text, segments: segments, fonts: fonts)
        }
        CFAttributedStringEndEditing(string)
        let line = CTLineCreateWithAttributedString(string)
        let glyphRuns = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in glyphRuns {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let index = (attributes[Self.segmentKey] as? NSNumber)?.intValue, segments.indices.contains(index),
                  let fontValue = attributes[kCTFontAttributeName] else { continue }
            let font = fontValue as! CTFont
            let segment = segments[index]
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            var anchorColumn = -1
            var anchor: CGFloat = 0
            for glyph in 0..<count {
                let utf16 = indices[glyph]
                let cell = utf16 < columns.count ? Int(columns[utf16]) : anchorColumn
                if cell != anchorColumn {
                    anchorColumn = cell
                    anchor = positions[glyph].x
                }
                positions[glyph] = CGPoint(x: CGFloat(cell) * cellWidth + positions[glyph].x - anchor, y: 0)
            }
            let base = fonts.face(bold: segment.bold, italic: segment.italic)
            item.glyphs.append(GlyphRun(
                font: font, glyphs: glyphs, positions: positions, color: segment.color, alpha: segment.alpha,
                syntheticBold: base.syntheticBold && CFEqual(font, base.font),
                isColor: CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)))
        }
        return item
    }

    /// Shapes a cluster once, sharing fallback and mapped-font glyph geometry
    /// across rows; color and cell origin are applied by the row layout.
    private func shapedCell(_ text: String, bold: Bool, italic: Bool, state: TerminalRenderState) -> [GlyphRun] {
        let key = GlyphKey(text: text, bold: bold, italic: italic)
        if let cached = glyphCache[key] { return cached }
        let face = state.fonts.face(bold: bold, italic: italic)
        let string = CFAttributedStringCreateMutable(nil, 0)!
        CFAttributedStringReplaceString(string, CFRange(location: 0, length: 0), text as CFString)
        CFAttributedStringSetAttribute(string, CFRange(location: 0, length: text.utf16.count), kCTFontAttributeName, face.font)
        let segments = [Segment(range: CFRange(location: 0, length: text.utf16.count), color: 0, alpha: 1,
                                bold: bold, italic: italic)]
        if state.fonts.hasMappedRanges { applyMappedFonts(string, text: text, segments: segments, fonts: state.fonts) }
        let line = CTLineCreateWithAttributedString(string)
        var result: [GlyphRun] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            result.append(GlyphRun(font: font, glyphs: glyphs, positions: positions, color: 0, alpha: 1,
                                   syntheticBold: face.syntheticBold && CFEqual(font, face.font),
                                   isColor: CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)))
        }
        let bytes = text.utf8.count + result.reduce(128) {
            $0 + $1.glyphs.count * MemoryLayout<CGGlyph>.stride + $1.positions.count * MemoryLayout<CGPoint>.stride + 128
        }
        if glyphCache.count >= Self.glyphLimit || glyphBytes + bytes > Self.glyphByteLimit {
            glyphCache.removeAll(keepingCapacity: true)
            glyphBytes = 0
        }
        if bytes <= Self.glyphByteLimit {
            glyphCache[key] = result
            glyphBytes += bytes
        }
        glyphLayoutCount += 1
        return result
    }

    private func applyMappedFonts(_ string: CFMutableAttributedString, text: String, segments: [Segment],
                                  fonts: TerminalFontSet) {
        var offset = 0
        var segment = 0
        for scalar in text.unicodeScalars {
            let length = scalar.utf16.count
            while segment + 1 < segments.count, segments[segment].range.location + segments[segment].range.length <= offset {
                segment += 1
            }
            let face = fonts.face(bold: segments[segment].bold, italic: segments[segment].italic)
            if let font = fonts.mappedFont(for: scalar, base: face.font) {
                CFAttributedStringSetAttribute(string, CFRange(location: offset, length: length), kCTFontAttributeName,
                                               font)
            }
            offset += length
        }
    }

    private struct Part {
        var text: Substring
        var column: UInt16
        var selected: Bool
    }

    /// A run split where the selection starts and ends, so selected cells
    /// can take the selection's text color.
    private func split(_ run: Run, start: UInt16, simple: Bool, selected: Range<UInt16>?) -> [Part] {
        let end = start &+ run.width
        guard let selected, selected.lowerBound < end, selected.upperBound > start else {
            return [Part(text: run.text[...], column: start, selected: false)]
        }
        guard simple else { return [Part(text: run.text[...], column: start, selected: true)] }
        var parts: [Part] = []
        let bounds = [start, max(start, selected.lowerBound), min(end, selected.upperBound), end]
        let utf8 = run.text.utf8
        for index in 0..<3 where bounds[index] < bounds[index + 1] {
            let from = utf8.index(utf8.startIndex, offsetBy: Int(bounds[index] - start))
            let to = utf8.index(utf8.startIndex, offsetBy: Int(bounds[index + 1] - start))
            parts.append(Part(text: run.text[from..<to], column: bounds[index], selected: index == 1))
        }
        return parts
    }

    private func decorate(_ item: PreparedRow, _ style: Style, _ columns: Range<UInt16>, foreground: UInt32,
                          palette: TerminalPalette) {
        guard !columns.isEmpty, !style.invisible else { return }
        let alpha: CGFloat = style.faint ? 0.5 : 1
        if style.underline != .none {
            let color = palette.resolve(style.underlineColor, default: foreground)
            item.decorations.append(Decoration(kind: .underline(style.underline), columns: columns, color: color,
                                               alpha: alpha))
        }
        if style.strikethrough {
            item.decorations.append(Decoration(kind: .strikethrough, columns: columns, color: foreground, alpha: alpha))
        }
        if style.overline {
            item.decorations.append(Decoration(kind: .overline, columns: columns, color: foreground, alpha: alpha))
        }
    }

    /// Background color runs of a row, adjacent equal colors merged, the
    /// default background left out (the base fill draws it).
    public static func backgroundSpans(_ runs: [Run], palette: TerminalPalette, cols: UInt16)
        -> [(columns: Range<UInt16>, color: UInt32)] {
        var spans: [(columns: Range<UInt16>, color: UInt32)] = []
        var column: UInt16 = 0
        for run in runs {
            let start = column
            column &+= run.width
            guard start < cols else { break }
            let end = min(column, cols)
            let background = palette.style(run.style).background
            guard background != palette.background || run.style.bg != .default || run.style.inverse else { continue }
            if let last = spans.last, last.color == background, last.columns.upperBound == start {
                spans[spans.count - 1].columns = last.columns.lowerBound..<end
            } else {
                spans.append((start..<end, background))
            }
        }
        return spans
    }

    /// Whether the row is colored edge to edge (padding extends it vertically).
    static func coversRow(_ runs: [Run], palette: TerminalPalette, cols: UInt16) -> Bool {
        var width: UInt16 = 0
        for run in runs where run.width > 0 {
            if palette.style(run.style).background == palette.background { return false }
            if run.text.unicodeScalars.contains(where: { (0xE0B0...0xE0D4).contains($0.value) }) { return false }
            width &+= run.width
            if width >= cols { return true }
        }
        return false
    }

    private func drawBackgrounds(_ item: PreparedRow, row: Int, state: TerminalRenderState, backgroundAlpha: CGFloat,
                                 in context: CGContext) {
        let layout = state.layout
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.copy)
        let alpha = state.palette.backgroundOpacityCells ? backgroundAlpha : 1
        let top = layout.grid.minY + CGFloat(row) * layout.cellHeight
        let height = layout.cellHeight
        let lastRow = Int(layout.viewport.rows) - 1
        for span in item.backgrounds {
            var left = layout.grid.minX + CGFloat(span.columns.lowerBound) * layout.cellWidth
            var right = layout.grid.minX + CGFloat(span.columns.upperBound) * layout.cellWidth
            var minY = top
            var maxY = top + height
            if layout.paddingColor != .background {
                let vertical = layout.paddingColor == .extendAlways || item.fullWidth
                if span.columns.lowerBound == 0 { left = layout.bounds.minX }
                if span.columns.upperBound >= layout.viewport.cols { right = layout.bounds.maxX }
                if vertical, row == 0 { minY = layout.bounds.minY }
                if vertical, row == lastRow { maxY = layout.bounds.maxY }
            }
            let rect = CGRect(x: left, y: minY, width: right - left, height: maxY - minY)
            context.setFillColor(color(span.color, alpha: alpha))
            context.fill(rect)
        }
    }

    private func drawHighlights(_ state: TerminalRenderState, row: Int, content: Int, in context: CGContext) {
        let layout = state.layout
        let palette = state.palette
        if let find = state.find {
            for highlight in find.highlights(in: state.grid, contentRow: content) {
                context.setFillColor(color(palette.indexed(3), alpha: highlight.current ? 0.65 : 0.25))
                context.fill(layout.cellRect(row: row, column: Int(highlight.columns.lowerBound),
                                             width: highlight.columns.count))
            }
        }
        guard let selection = state.selection else { return }
        let screenRow = content - state.grid.history.count
        let columns = selection.columns(row: screenRow, in: state.grid)
        guard !columns.isEmpty else { return }
        let rect = layout.cellRect(row: row, column: Int(columns.lowerBound), width: columns.count)
        guard let background = palette.selectionBackground else {
            context.setFillColor(color(palette.indexed(4), alpha: 0.35))
            context.fill(rect)
            return
        }
        context.setFillColor(color(palette.resolveCell(background, foreground: palette.foreground,
                                                       background: palette.background)))
        context.fill(rect)
        var column: UInt16 = 0
        for run in Selection.runs(screenRow, state.grid) {
            let start = max(column, columns.lowerBound)
            let end = min(column &+ run.width, columns.upperBound)
            column &+= run.width
            guard start < end else { continue }
            let colors = palette.style(run.style)
            context.setFillColor(color(palette.resolveCell(background, foreground: colors.foreground,
                                                           background: colors.background)))
            context.fill(layout.cellRect(row: row, column: Int(start), width: Int(end - start)))
        }
    }

    private func drawDecorations(_ item: PreparedRow, top: CGFloat, state: TerminalRenderState, in context: CGContext) {
        guard !item.decorations.isEmpty else { return }
        let layout = state.layout
        let scale = state.metrics.scale
        let thickness = state.metrics.lineThickness
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let bottom = snap(top + layout.cellHeight) - thickness * 2
        for decoration in item.decorations {
            let left = snap(layout.grid.minX + CGFloat(decoration.columns.lowerBound) * layout.cellWidth)
            let right = snap(layout.grid.minX + CGFloat(decoration.columns.upperBound) * layout.cellWidth)
            let fill = color(decoration.color, alpha: decoration.alpha)
            context.setFillColor(fill)
            switch decoration.kind {
            case .strikethrough:
                context.fill(CGRect(x: left, y: snap(top + layout.cellHeight / 2), width: right - left,
                                    height: thickness))
            case .overline:
                context.fill(CGRect(x: left, y: snap(top), width: right - left, height: thickness))
            case .underline(let style):
                switch style {
                case .none:
                    break
                case .single:
                    context.fill(CGRect(x: left, y: bottom, width: right - left, height: thickness))
                case .double:
                    context.fill(CGRect(x: left, y: bottom, width: right - left, height: thickness))
                    context.fill(CGRect(x: left, y: bottom - thickness * 2, width: right - left, height: thickness))
                case .dotted, .dashed:
                    context.saveGState()
                    context.setStrokeColor(fill)
                    context.setLineWidth(thickness)
                    let dash = style == .dashed ? thickness * 3 : thickness
                    context.setLineDash(phase: 0, lengths: [dash, thickness])
                    context.move(to: CGPoint(x: left, y: bottom + thickness / 2))
                    context.addLine(to: CGPoint(x: right, y: bottom + thickness / 2))
                    context.strokePath()
                    context.restoreGState()
                case .curly:
                    context.saveGState()
                    context.setStrokeColor(fill)
                    context.setLineWidth(thickness)
                    let amplitude = thickness * 1.5
                    let period = max(thickness * 4, 3)
                    let middle = bottom - amplitude / 2
                    context.move(to: CGPoint(x: left, y: middle))
                    var x = left
                    var up = true
                    while x < right {
                        let next = min(x + period / 2, right)
                        context.addQuadCurve(to: CGPoint(x: next, y: middle),
                                             control: CGPoint(x: (x + next) / 2, y: middle + (up ? -amplitude : amplitude)))
                        up.toggle()
                        x = next
                    }
                    context.strokePath()
                    context.restoreGState()
                }
            }
        }
    }

    private func drawGlyphs(_ item: PreparedRow, origin: CGPoint, fonts: TerminalFontSet, override: CGColor?,
                            in context: CGContext) {
        guard !item.glyphs.isEmpty else { return }
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        let thicken = fonts.thicken && fonts.thickenStrength > 0
        for run in item.glyphs {
            let stroke = !run.isColor && (run.syntheticBold || thicken)
            let grouped = stroke && override == nil && run.alpha < 1
            if grouped {
                context.saveGState()
                context.setAlpha(run.alpha)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            let fill = override ?? color(run.color, alpha: grouped ? 1 : run.alpha)
            context.setFillColor(fill)
            context.setTextDrawingMode(.fill)
            run.glyphs.withUnsafeBufferPointer { glyphs in
                run.positions.withUnsafeBufferPointer { positions in
                    guard let glyphs = glyphs.baseAddress, let positions = positions.baseAddress else { return }
                    CTFontDrawGlyphs(run.font, glyphs, positions, run.glyphs.count, context)
                    guard stroke else { return }
                    context.setStrokeColor(fill)
                    context.setLineWidth(run.syntheticBold ? max(fonts.size / 24, 0.5) : 0.35 * fonts.thickenStrength)
                    context.setTextDrawingMode(.stroke)
                    CTFontDrawGlyphs(run.font, glyphs, positions, run.glyphs.count, context)
                }
            }
            if grouped {
                context.endTransparencyLayer()
                context.restoreGState()
            }
        }
        context.restoreGState()
    }

    private func prepareImages(_ state: TerminalRenderState) {
        preparedImages.removeAll(keepingCapacity: true)
        images.removeAll(keepingCapacity: true)
        guard let graphics = state.grid.graphics else { return }
        let layout = state.layout
        let sx = layout.cellWidth / CGFloat(max(graphics.cell.width, 1))
        let sy = layout.cellHeight / CGFloat(max(graphics.cell.height, 1))
        for placement in graphics.placements.sorted(by: { $0.z < $1.z }) {
            guard let image = graphics.images.first(where: { $0.id == placement.image }),
                  let cgImage = cgImage(image) else { continue }
            let source = CGRect(x: Int(placement.source.x), y: Int(placement.source.y),
                                width: Int(placement.source.width), height: Int(placement.source.height))
            let crop = source.width == 0 || source.height == 0
                ? CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height) : source
            guard let cropped = cgImage.cropping(to: crop) else { continue }
            let rect = CGRect(x: layout.grid.minX + CGFloat(placement.column) * layout.cellWidth + CGFloat(placement.offset.x) * sx,
                              y: layout.grid.minY + CGFloat(placement.row) * layout.cellHeight + CGFloat(placement.offset.y) * sy,
                              width: placement.size.cols > 0 ? CGFloat(placement.size.cols) * layout.cellWidth : crop.width * sx,
                              height: placement.size.rows > 0 ? CGFloat(placement.size.rows) * layout.cellHeight : crop.height * sy)
            preparedImages.append(ImagePlacement(image: cropped, rect: rect, z: placement.z))
        }
    }

    private func drawImages(_ state: TerminalRenderState, row: Int, z: Range<Int64>, in context: CGContext) {
        for placement in preparedImages where z.contains(Int64(placement.z)) {
            let rect = placement.rect.offsetBy(dx: 0, dy: CGFloat(state.grid.scrollOffset) * state.layout.cellHeight)
            guard rect.intersects(state.layout.rowRect(row)) else { continue }
            context.saveGState()
            context.clip(to: state.layout.grid)
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(placement.image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
    }

    private func cgImage(_ image: GraphicImage) -> CGImage? {
        let key = ImageKey(id: image.id, generation: image.generation)
        if let cached = images[key] { return cached }
        let width = Int(image.width)
        let height = Int(image.height)
        guard width > 0, height > 0, width <= Self.imageByteLimit / 4 / height,
              imageBytes + width * height * 4 <= Self.imageByteLimit,
              image.rgba.count >= width * height * 4,
              let provider = CGDataProvider(data: image.rgba as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        images[key] = cgImage
        return cgImage
    }

    private func drawLink(_ state: TerminalRenderState, rows: IndexSet, in context: CGContext) {
        guard let link = state.link else { return }
        let row = link.row + state.grid.history.count - state.firstRow
        guard rows.contains(row) else { return }
        let rect = state.layout.cellRect(row: row, column: Int(link.columns.lowerBound), width: link.columns.count)
        let thickness = state.metrics.lineThickness
        context.setFillColor(color(state.palette.foreground))
        context.fill(CGRect(x: rect.minX, y: rect.maxY - thickness * 2, width: rect.width, height: thickness))
    }

    private func drawCursor(_ state: TerminalRenderState, row item: PreparedRow, in context: CGContext) {
        let cursor = state.cursor
        let palette = state.palette
        let layout = state.layout
        var style = Style()
        var width = 1
        var column: UInt16 = 0
        for run in Selection.runs(cursor.row + state.firstRow - state.grid.history.count, state.grid) {
            let end = column &+ run.width
            if Int(end) > cursor.column {
                style = run.style
                if !TerminalCells.isSimple(run) { width = max(1, Int(run.width)) }
                break
            }
            column = end
        }
        let colors = palette.style(style)
        let cursorColor = palette.cursorColor.map {
            palette.resolveCell($0, foreground: colors.foreground, background: colors.background)
        } ?? palette.cursor
        let textColor = palette.cursorText.map {
            palette.resolveCell($0, foreground: colors.foreground, background: colors.background)
        } ?? palette.background
        let rect = layout.cellRect(row: cursor.row, column: cursor.column, width: width)
        let scale = state.metrics.scale
        let natural = cursor.shape == .hollow ? 1 : 1 / scale
        let thickness = min(CGFloat(cursor.thickness.apply(natural: Double(natural), scale: Double(scale))),
                            rect.width, rect.height)
        let fill = color(cursorColor, alpha: CGFloat(palette.cursorOpacity))
        context.setFillColor(fill)
        switch cursor.shape {
        case .bar:
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: thickness, height: rect.height))
        case .underline:
            context.fill(CGRect(x: rect.minX, y: rect.maxY - thickness, width: rect.width, height: thickness))
        case .hollow:
            context.setStrokeColor(fill)
            context.setLineWidth(thickness)
            context.stroke(rect.insetBy(dx: thickness / 2, dy: thickness / 2))
        case .block:
            context.fill(rect)
            context.saveGState()
            context.clip(to: rect)
            drawGlyphs(item, origin: CGPoint(x: layout.grid.minX, y: rect.minY + state.metrics.baseline),
                       fonts: state.fonts, override: color(textColor), in: context)
            context.restoreGState()
        }
    }

    private func drawMarkedText(_ text: String, state: TerminalRenderState, in context: CGContext) {
        let layout = state.layout
        let font = state.fonts.regular.font
        let foreground = color(state.palette.foreground)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: foreground,
                          kCTUnderlineStyleAttributeName: CTUnderlineStyle.single.rawValue as CFNumber] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, text as CFString, attributes) else { return }
        let line = CTLineCreateWithAttributedString(string)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let cells = max(1, Int((width / layout.cellWidth).rounded(.up)))
        let rect = layout.cellRect(row: state.cursor.row, column: state.cursor.column, width: cells)
        context.setFillColor(color(state.palette.background))
        context.fill(rect)
        context.textPosition = CGPoint(x: rect.minX, y: rect.minY + state.metrics.baseline)
        CTLineDraw(line, context)
    }

    private func color(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        let alphaByte = UInt64(min(max(alpha, 0), 1) * 255)
        let key = UInt64(value) | alphaByte << 32
        if let cached = colors[key] { return cached }
        let created = CGColor.terminal(value, alpha: CGFloat(alphaByte) / 255)
        if colors.count >= 512 { colors.removeAll(keepingCapacity: true) }
        colors[key] = created
        return created
    }

    static let segmentKey = "TabTerminalSegment" as CFString
}

struct RowKey: Hashable {
    var runs: [Run]
    var selected: Range<UInt16>?
}

struct ImageKey: Hashable {
    var id: UInt32
    var generation: UInt64
}

private struct Segment {
    var range: CFRange
    var color: UInt32
    var alpha: CGFloat
    var bold: Bool
    var italic: Bool
}

/// ASCII glyphs being collected for one font and color, taken straight from
/// the font's table, one per cell, without shaping.
private struct PendingGlyphs {
    var face: TerminalFontSet.Face?
    var color: UInt32 = 0
    var alpha: CGFloat = 1
    var glyphs: [CGGlyph] = []
    var positions: [CGPoint] = []

    func matches(_ face: TerminalFontSet.Face, _ color: UInt32, _ alpha: CGFloat) -> Bool {
        self.face?.font === face.font && self.color == color && self.alpha == alpha
    }

    mutating func start(_ face: TerminalFontSet.Face, _ color: UInt32, _ alpha: CGFloat) {
        self.face = face
        self.color = color
        self.alpha = alpha
    }

    mutating func append(_ text: Substring, column: Int, glyphs table: [CGGlyph], cellWidth: CGFloat) {
        var x = CGFloat(column) * cellWidth
        text.utf8.withContiguousStorageIfAvailable { bytes in
            table.withUnsafeBufferPointer { table in
                for byte in bytes {
                    if byte > 0x20, byte < 0x7F {
                        glyphs.append(table[Int(byte)])
                        positions.append(CGPoint(x: x, y: 0))
                    }
                    x += cellWidth
                }
            }
        } ?? {
            for byte in text.utf8 {
                if byte > 0x20, byte < 0x7F {
                    glyphs.append(table[Int(byte)])
                    positions.append(CGPoint(x: x, y: 0))
                }
                x += cellWidth
            }
        }()
    }

    mutating func flush(into item: PreparedRow) {
        guard let face, !glyphs.isEmpty else { return }
        item.glyphs.append(GlyphRun(font: face.font, glyphs: glyphs, positions: positions, color: color, alpha: alpha,
                                    syntheticBold: face.syntheticBold, isColor: false))
        glyphs.removeAll(keepingCapacity: false)
        positions.removeAll(keepingCapacity: false)
    }
}

/// Glyphs of one font and color, positioned on their cells relative to the
/// row's left edge and baseline.
struct GlyphRun {
    var font: CTFont
    var glyphs: [CGGlyph]
    var positions: [CGPoint]
    var color: UInt32
    var alpha: CGFloat
    var syntheticBold: Bool
    var isColor: Bool
}

struct Decoration {
    enum Kind {
        case underline(Underline)
        case strikethrough
        case overline
    }

    var kind: Kind
    var columns: Range<UInt16>
    var color: UInt32
    var alpha: CGFloat
}

/// A laid-out row, shared by every visible row with the same content.
final class PreparedRow {
    let key: RowKey
    var backgrounds: [(columns: Range<UInt16>, color: UInt32)] = []
    var fullWidth = false
    var glyphs: [GlyphRun] = []
    var decorations: [Decoration] = []
    var stamp: UInt64 = 0
    /// Retained payload estimate; excludes Core Text's process-wide font storage.
    var bytes: Int {
        256 + key.runs.reduce(0) { $0 + $1.text.utf8.count + MemoryLayout<Run>.stride }
            + glyphs.reduce(0) { $0 + 128 + $1.glyphs.count * MemoryLayout<CGGlyph>.stride
                + $1.positions.count * MemoryLayout<CGPoint>.stride }
            + backgrounds.count * 32 + decorations.count * MemoryLayout<Decoration>.stride
    }

    init(key: RowKey) {
        self.key = key
    }
}

private typealias Selection = TerminalSelection

/// Reused bitmap storage for a visible row, including its padding and overlays.
private final class RowSurface {
    let rect: CGRect
    let context: CGContext
    let layer: CGLayer
    /// Backing pixel payload; Core Graphics owns the layer's allocation metadata.
    let bytes: Int

    init?(rect: CGRect, scale: CGFloat) {
        let width = Int(ceil(rect.width * scale))
        let height = Int(ceil(rect.height * scale))
        guard width > 0, height > 0,
              let reference = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue),
              let layer = CGLayer(reference, size: CGSize(width: width, height: height), auxiliaryInfo: nil),
              let context = layer.context else { return nil }
        self.rect = rect
        self.context = context
        self.layer = layer
        bytes = ((width * 4 + 63) / 64 * 64) * height
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
    }
}

private struct ImagePlacement {
    var image: CGImage
    var rect: CGRect
    var z: Int32
}

private struct PaintKey: Equatable {
    var row: RowKey
    var selection: Range<UInt16>?
    var find: TerminalFind?
    var link: TerminalLinkCandidate?
    var cursor: TerminalCursorState?
    var marked: String?
    var scroll: Int
}

private struct GlyphKey: Hashable {
    var text: String
    var bold: Bool
    var italic: Bool
}
