import AppKit
import TabClient
import TabCore
import TabProtocol

/// A sample the Terminal settings page shows, drawn by the terminal renderer
/// so it looks exactly like a terminal with the same settings.
enum TerminalPreview: String {
    case typography, cursor, selection

    /// Cached drawings by what they depend on; Settings rebuilds its rows
    /// on every change.
    @MainActor private static var cache: [Key: NSImage] = [:]

    private struct Key: Hashable {
        var preview: TerminalPreview
        var settings: TerminalSettings
        var palette: TerminalPalette
        var cursor: Bool
        var scale: CGFloat
    }

    /// The sample drawn with `settings` and `palette`, the cursor shown or
    /// in its hidden blink phase.
    @MainActor
    func image(settings: TerminalSettings, palette: TerminalPalette, cursor: Bool, scale: CGFloat) -> NSImage? {
        let key = Key(preview: self, settings: settings, palette: palette, cursor: cursor, scale: scale)
        if let cached = Self.cache[key] { return cached }
        guard let image = draw(settings: settings, palette: palette, cursor: cursor, scale: scale) else { return nil }
        if Self.cache.count > 24 { Self.cache.removeAll() }
        Self.cache[key] = image
        return image
    }

    private var rows: [[Run]] {
        func run(_ text: String, bold: Bool = false, italic: Bool = false) -> Run {
            var style = Style()
            style.bold = bold
            style.italic = italic
            return Run(text: text, width: UInt16(text.count), style: style)
        }
        switch self {
        case .typography:
            return [
                [run("~/rex ⎇ main $ swift build && swift test")],
                [run("main.swift:4: warning: 'run() -> Bool' is deprecated")],
                [run("Build complete!", bold: true), run(" "), run("(1.24 sec)", italic: true)],
            ]
        case .cursor:
            return [[run("~/rex $ ")]]
        case .selection:
            return [[run("On branch feature/tabs")]]
        }
    }

    @MainActor
    private func draw(settings: TerminalSettings, palette: TerminalPalette, cursor: Bool, scale: CGFloat) -> NSImage? {
        let rows = rows
        let cols = UInt16(rows.map { $0.reduce(0) { $0 + Int($1.width) } }.max() ?? 0) + 1
        let size = Size(cols: cols, rows: UInt16(rows.count))
        let cursorColumn: UInt16 = self == .cursor ? 8 : 0
        let grid = RunGrid(snapshot: AttachSnapshot(
            channel: ChannelId(1), size: size,
            rows: rows.enumerated().map { Row(index: UInt16($0.offset), runs: $0.element) },
            cursor: Cursor(shape: palette.cursorStyle, row: 0, col: cursorColumn, visible: self == .cursor),
            directory: "/", prompts: [], history: [], historyTotal: 0))
        let fonts = TerminalFontSet(settings: settings)
        let metrics = TerminalMetrics(fonts: fonts, settings: settings, scale: scale)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(cols) * metrics.cellWidth + 2 * TerminalLayout.padding,
                            height: CGFloat(rows.count) * metrics.cellHeight + 2 * TerminalLayout.padding)
        let layout = TerminalLayout(bounds: bounds, metrics: metrics)
        let selection = self == .selection
            ? TerminalSelection(anchor: TerminalPoint(row: 0, column: 10), head: TerminalPoint(row: 0, column: 22)) : nil
        let state = TerminalRenderState(
            grid: grid, layout: layout, metrics: metrics, fonts: fonts, palette: palette,
            cursor: TerminalCursorState(visible: self == .cursor && cursor, shape: palette.cursorStyle, row: 0,
                                        column: Int(cursorColumn)),
            selection: selection, roundedSelection: settings.roundedSelection)
        let width = Int((bounds.width * scale).rounded(.up))
        let height = Int((bounds.height * scale).rounded(.up))
        guard let space = CGColorSpace(name: palette.displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let renderer = CoreTextRenderer()
        renderer.prepare(state)
        renderer.draw(state, dirty: [bounds], in: context)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: bounds.size)
    }
}
