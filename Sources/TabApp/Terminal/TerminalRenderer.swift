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
    /// Draws the rows touching `dirty` (view coordinates, y down).
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
    public private(set) var isBackgroundOpaque = true

    private var slots: [PreparedRow?] = []
    private var cache: [RowKey: PreparedRow] = [:]
    private var colors: [UInt64: CGColor] = [:]
    private var images: [ImageKey: CGImage] = [:]
    private var stamp: UInt64 = 0
    private var palette: TerminalPalette?
    private var fontGeneration: UInt64 = 0
    private var cols: UInt16 = 0

    public init() {}

    public func invalidateAll() {
        slots = []
        cache = [:]
        images = [:]
        colors = [:]
    }

    public func invalidate(rows: IndexSet) {
        for row in rows where row < slots.count { slots[row] = nil }
    }

    // MARK: Drawing

    public func draw(_ state: TerminalRenderState, dirty: [CGRect], in context: CGContext) {
        prepareCaches(for: state)
        stamp &+= 1
        let layout = state.layout
        let palette = state.palette
        isBackgroundOpaque = palette.isOpaque
        let backgroundAlpha = CGFloat(min(max(palette.backgroundOpacity, 0), 1))
        var rows = IndexSet()
        for rect in dirty {
            if !palette.isOpaque { context.clear(rect) }
            context.setFillColor(color(palette.background, alpha: backgroundAlpha))
            context.fill(rect)
            rows.insert(integersIn: layout.rows(in: rect))
        }
        guard !rows.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let first = state.firstRow
        let screenOffset = state.grid.history.count - first
        var prepared: [Int: PreparedRow] = [:]
        for row in rows {
            let content = first + row
            let runs = state.grid.contentRow(content) ?? []
            let selected = selectedColumns(state, row: content - state.grid.history.count)
            let item = preparedRow(runs, selected: selected, row: row, state: state)
            prepared[row] = item
            drawBackgrounds(item, row: row, state: state, backgroundAlpha: backgroundAlpha, in: context)
        }
        drawImages(state, screenOffset: screenOffset, below: true, rows: rows, in: context)
        for row in rows {
            drawHighlights(state, row: row, content: first + row, in: context)
        }
        for row in rows {
            guard let item = prepared[row] else { continue }
            let top = layout.grid.minY + CGFloat(row) * layout.cellHeight
            drawDecorations(item, top: top, state: state, in: context)
            drawGlyphs(item, origin: CGPoint(x: layout.grid.minX, y: top + state.metrics.baseline), fonts: state.fonts,
                       override: nil, in: context)
        }
        drawImages(state, screenOffset: screenOffset, below: false, rows: rows, in: context)
        drawLink(state, rows: rows, in: context)
        if state.cursor.visible, rows.contains(state.cursor.row), let item = prepared[state.cursor.row] {
            drawCursor(state, row: item, in: context)
        }
        if let text = state.markedText, !text.isEmpty, rows.contains(state.cursor.row) {
            drawMarkedText(text, state: state, in: context)
        }
    }

    private func prepareCaches(for state: TerminalRenderState) {
        let rowCount = Int(state.layout.viewport.rows)
        if palette != state.palette || fontGeneration != state.fonts.generation || cols != state.layout.viewport.cols {
            palette = state.palette
            fontGeneration = state.fonts.generation
            cols = state.layout.viewport.cols
            slots = []
            cache = [:]
            colors = [:]
        }
        if slots.count != rowCount {
            slots = Array(repeating: nil, count: rowCount)
        }
        if cache.count > max(1024, rowCount * 8) {
            let horizon = stamp > 64 ? stamp - 64 : 0
            cache = cache.filter { $0.value.stamp >= horizon }
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
            layoutCount += 1
        }
        item.stamp = stamp
        if row < slots.count { slots[row] = item }
        return item
    }

    // MARK: Layout

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
            let font = fontValue as! CTFont // swiftlint:disable:this force_cast
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
            guard background != palette.background else { continue }
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
            if palette.resolve(run.style.bg, default: palette.background) == palette.background { return false }
            if run.text.unicodeScalars.contains(where: { (0xE0B0...0xE0D4).contains($0.value) }) { return false }
            width &+= run.width
            if width >= cols { return true }
        }
        return false
    }

    // MARK: Painting

    private func drawBackgrounds(_ item: PreparedRow, row: Int, state: TerminalRenderState, backgroundAlpha: CGFloat,
                                 in context: CGContext) {
        let layout = state.layout
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
            let fill = override ?? color(run.color, alpha: run.alpha)
            context.setFillColor(fill)
            let stroke = !run.isColor && (run.syntheticBold || thicken)
            if stroke {
                context.setStrokeColor(fill)
                context.setLineWidth(run.syntheticBold ? max(fonts.size / 24, 0.5) : 0.35 * fonts.thickenStrength)
                context.setTextDrawingMode(.fillStroke)
            } else {
                context.setTextDrawingMode(.fill)
            }
            run.glyphs.withUnsafeBufferPointer { glyphs in
                run.positions.withUnsafeBufferPointer { positions in
                    guard let glyphs = glyphs.baseAddress, let positions = positions.baseAddress else { return }
                    CTFontDrawGlyphs(run.font, glyphs, positions, run.glyphs.count, context)
                }
            }
        }
        context.restoreGState()
    }

    private func drawImages(_ state: TerminalRenderState, screenOffset: Int, below: Bool, rows: IndexSet,
                            in context: CGContext) {
        guard let graphics = state.grid.graphics, !graphics.placements.isEmpty else { return }
        let layout = state.layout
        let scale = state.metrics.scale
        if images.count > graphics.images.count + 8 {
            let live = Set(graphics.images.map { ImageKey(id: $0.id, generation: $0.generation) })
            images = images.filter { live.contains($0.key) }
        }
        for placement in graphics.placements where (placement.z < 0) == below {
            guard let image = graphics.images.first(where: { $0.id == placement.image }),
                  let cgImage = cgImage(image) else { continue }
            var source = CGRect(x: Int(placement.source.x), y: Int(placement.source.y),
                                width: Int(placement.source.width), height: Int(placement.source.height))
            if source.width == 0 || source.height == 0 {
                source = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
            }
            let row = Int(placement.row) + screenOffset
            let width = placement.size.cols > 0 ? CGFloat(placement.size.cols) * layout.cellWidth : source.width / scale
            let height = placement.size.rows > 0 ? CGFloat(placement.size.rows) * layout.cellHeight : source.height / scale
            let rect = CGRect(x: layout.grid.minX + CGFloat(placement.column) * layout.cellWidth
                                + CGFloat(placement.offset.x) / scale,
                              y: layout.grid.minY + CGFloat(row) * layout.cellHeight + CGFloat(placement.offset.y) / scale,
                              width: width, height: height)
            let touched = layout.rows(in: rect)
            guard touched.contains(where: rows.contains) else { continue }
            let cropped = source == CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
                ? cgImage : cgImage.cropping(to: source)
            guard let cropped else { continue }
            context.saveGState()
            context.clip(to: layout.grid)
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
    }

    private func cgImage(_ image: GraphicImage) -> CGImage? {
        let key = ImageKey(id: image.id, generation: image.generation)
        if let cached = images[key] { return cached }
        let width = Int(image.width)
        let height = Int(image.height)
        guard width > 0, height > 0, image.rgba.count >= width * height * 4,
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
        colors[key] = created
        return created
    }

    static let segmentKey = "TabTerminalSegment" as CFString
}

// MARK: - Cached rows

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

    init(key: RowKey) {
        self.key = key
    }
}

private typealias Selection = TerminalSelection
