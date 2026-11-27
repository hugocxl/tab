import CoreText
import TabProtocol
import TabShared
import UIKit

/// Draws one terminal row into a context whose origin is the row's top-left.
/// Backgrounds first, then selection, then glyphs and decorations, so wide
/// glyphs never get painted over by a neighbour's background.
struct TerminalRowPainter {
    let font: TerminalFont
    let palette: TerminalPalette

    /// Columns `range` of the row are selected.
    func draw(_ runs: [Run], selection: Range<Int>?, links: [LinkSpan], width: CGFloat, in context: CGContext) {
        let cell = CGSize(width: font.cellWidth, height: font.cellHeight)

        var column = 0
        for run in runs {
            let span = Self.columns(run)
            if let background = palette.colors(run.style).background {
                context.setFillColor(background)
                context.fill(CGRect(x: CGFloat(column) * cell.width, y: 0, width: CGFloat(span) * cell.width,
                                    height: cell.height))
            }
            column += span
        }
        if let selection, !selection.isEmpty {
            context.setFillColor(palette.cgColor(palette.selection, alpha: 0.6))
            let end = selection.upperBound == Int.max ? width : CGFloat(selection.upperBound) * cell.width
            context.fill(CGRect(x: CGFloat(selection.lowerBound) * cell.width, y: 0,
                                width: end - CGFloat(selection.lowerBound) * cell.width, height: cell.height))
        }

        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        column = 0
        for run in runs {
            let span = Self.columns(run)
            defer { column += span }
            let style = run.style
            guard !style.invisible, !run.text.isEmpty else { continue }
            let (foreground, _) = palette.colors(style)
            let x = CGFloat(column) * cell.width
            let face = font.face(bold: style.bold, italic: style.italic)
            context.setFillColor(foreground)
            // Drawing a line moves the text matrix's origin; start each run from zero.
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            if Self.isSimple(run) {
                drawASCII(run.text, face: face, x: x, in: context)
            } else if !run.text.allSatisfy({ $0 == " " }) {
                drawCluster(run.text, face: face, color: foreground, x: x, in: context)
            }
            drawDecorations(style, color: foreground, x: x, width: CGFloat(span) * cell.width, in: context)
        }
        for link in links {
            context.setFillColor(palette.cgColor(palette.foreground, alpha: 0.5))
            context.fill(CGRect(x: CGFloat(link.start) * cell.width, y: font.cellHeight - 1.5,
                                width: CGFloat(Int(link.end) - Int(link.start)) * cell.width, height: 1))
        }
    }

    private func drawASCII(_ text: String, face: Int, x: CGFloat, in context: CGContext) {
        var glyphs: [CGGlyph] = []
        var positions: [CGPoint] = []
        glyphs.reserveCapacity(text.utf8.count)
        positions.reserveCapacity(text.utf8.count)
        for (offset, byte) in text.utf8.enumerated() where byte != 0x20 {
            glyphs.append(font.asciiGlyph(byte, face: face))
            // Positions are in text space, which the flipped text matrix turns upside down.
            positions.append(CGPoint(x: x + CGFloat(offset) * font.cellWidth, y: -font.ascent))
        }
        guard !glyphs.isEmpty else { return }
        withSlant(face, x: x, in: context) {
            CTFontDrawGlyphs(font.faces[face], glyphs, positions, glyphs.count, context)
        }
    }

    private func drawCluster(_ text: String, face: Int, color: CGColor, x: CGFloat, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font.faces[face],
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        withSlant(face, x: x, in: context) {
            context.textPosition = CGPoint(x: x, y: font.ascent)
            CTLineDraw(line, context)
        }
    }

    private func withSlant(_ face: Int, x: CGFloat, in context: CGContext, _ body: () -> Void) {
        guard font.syntheticItalic[face] else {
            body()
            return
        }
        context.saveGState()
        // Slant about the baseline, so the cell's left edge stays put there.
        context.textMatrix = CGAffineTransform(a: 1, b: 0, c: -0.2, d: -1, tx: -0.2 * font.ascent, ty: 0)
        body()
        context.restoreGState()
    }

    private func drawDecorations(_ style: Style, color: CGColor, x: CGFloat, width: CGFloat, in context: CGContext) {
        let thickness = max(1, (font.size / 13).rounded())
        if style.underline != .none {
            let underline = palette.rgb(style.underlineColor).map { palette.cgColor($0) } ?? color
            context.setFillColor(underline)
            let y = font.ascent + max(1, (font.cellHeight - font.ascent) / 3)
            context.fill(CGRect(x: x, y: y, width: width, height: thickness))
            if style.underline == .double {
                context.fill(CGRect(x: x, y: y + thickness * 2, width: width, height: thickness))
            }
            context.setFillColor(color)
        }
        if style.strikethrough {
            context.fill(CGRect(x: x, y: (font.ascent * 0.68).rounded(), width: width, height: thickness))
        }
        if style.overline {
            context.fill(CGRect(x: x, y: 0, width: width, height: thickness))
        }
    }

    /// One byte per cell, as the server merges plain ASCII.
    static func isSimple(_ run: Run) -> Bool {
        run.text.utf8.count == Int(run.width) && run.text.utf8.allSatisfy { $0 < 0x80 }
    }

    /// The columns a run covers.
    static func columns(_ run: Run) -> Int {
        isSimple(run) ? Int(run.width) : max(1, Int(run.width))
    }
}

/// A layer per visible row: a frame redraws only the rows it changed.
final class TerminalRowLayer: CALayer {
    var runs: [Run] = []
    var selection: Range<Int>?
    var links: [LinkSpan] = []
    var painter: TerminalRowPainter?

    override init() {
        super.init()
        isOpaque = true
        needsDisplayOnBoundsChange = false
        drawsAsynchronously = true
        actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Takes new content, and redraws only if it differs from what's drawn.
    func update(_ runs: [Run], selection: Range<Int>?, links: [LinkSpan]) {
        guard runs != self.runs || selection != self.selection || links != self.links else { return }
        self.runs = runs
        self.selection = selection
        self.links = links
        setNeedsDisplay()
    }

    override func draw(in context: CGContext) {
        guard let painter else { return }
        context.setFillColor(painter.palette.cgColor(painter.palette.background))
        context.fill(bounds)
        painter.draw(runs, selection: selection, links: links, width: bounds.width, in: context)
    }
}

/// The cursor, drawn apart from the rows so moving or blinking it never
/// redraws text. Blinking is a render-server animation.
final class TerminalCursorLayer: CALayer {
    var shape: CursorShape = .block
    var focused = true
    var glyph: Run?
    var painter: TerminalRowPainter?

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(),
                   "opacity": NSNull()]
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setBlinking(_ blinking: Bool) {
        removeAnimation(forKey: "blink")
        guard blinking else { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 0]
        animation.keyTimes = [0, 0.5]
        animation.calculationMode = .discrete
        animation.duration = 1.1
        animation.repeatCount = .infinity
        animation.beginTime = CACurrentMediaTime() + 0.6
        add(animation, forKey: "blink")
    }

    override func draw(in context: CGContext) {
        guard let painter else { return }
        let palette = painter.palette
        let color = palette.cgColor(palette.cursor)
        let thickness = max(2, (painter.font.size / 7).rounded())
        switch (focused, shape) {
        case (false, _), (_, .hollow):
            context.setStrokeColor(color)
            context.setLineWidth(1.5)
            context.stroke(bounds.insetBy(dx: 0.75, dy: 0.75))
        case (true, .bar):
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: thickness, height: bounds.height))
        case (true, .underline):
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: bounds.height - thickness, width: bounds.width, height: thickness))
        case (true, .block):
            context.setFillColor(color)
            context.fill(bounds)
            guard var glyph else { return }
            glyph.style.fg = .default
            glyph.style.bg = .default
            glyph.style.inverse = false
            // Draw the covered character in the cursor's text color.
            let inverted = TerminalPalette.Overlay(base: palette, foreground: palette.cursorText)
            inverted.draw(glyph, painter: painter, in: context)
        }
    }
}

extension TerminalPalette {
    /// Draws a single cell with a fixed foreground.
    struct Overlay {
        let base: TerminalPalette
        let foreground: RGBColor

        func draw(_ run: Run, painter: TerminalRowPainter, in context: CGContext) {
            guard !run.text.isEmpty, run.text != " " else { return }
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            let font = painter.font
            let face = font.face(bold: run.style.bold, italic: run.style.italic)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font.faces[face],
                .foregroundColor: base.cgColor(foreground),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: run.text, attributes: attributes))
            context.textPosition = CGPoint(x: 0, y: font.ascent)
            CTLineDraw(line, context)
        }
    }
}
