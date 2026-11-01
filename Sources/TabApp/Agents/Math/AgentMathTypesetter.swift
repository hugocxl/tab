import AppKit
import CoreText

/// Typesets LaTeX math natively. Thread-safe to call from any thread for parsing and measurement.
enum AgentMathTypesetter {
    /// How to typeset an expression.
    struct Options {
        /// Display style (`$$…$$`): larger operators with limits above and below.
        var displayMode: Bool
        var fontSize: CGFloat
        var color: NSColor
        /// The color of source that couldn't be interpreted, such as unknown commands.
        var errorColor: NSColor
        /// The PostScript or family name of the font for `\text`; nil uses the system font.
        var textFontName: String? = nil
    }

    /// A typeset expression, ready to draw.
    struct Result {
        var size: CGSize
        /// The ascent above the baseline, measured from the top of `size`.
        var baseline: CGFloat
        /// Draws the expression with its top-left corner at the origin of a flipped (y-down) context.
        var draw: (CGContext) -> Void
        /// Whether some of the source couldn't be interpreted and is shown in the error color.
        var hasErrors: Bool
    }

    /// Parses and lays out `latex`, reusing a cached result for identical input.
    static func typeset(_ latex: String, options: Options) -> Result {
        let key = CacheKey(
            latex: latex,
            displayMode: options.displayMode,
            fontSize: options.fontSize,
            color: options.color,
            errorColor: options.errorColor,
            textFontName: options.textFontName
        )
        if let cached = cache.value(for: key) { return cached }
        let result = typesetUncached(latex, options: options)
        cache.insert(result, for: key)
        return result
    }

    /// An NSImage rendered at the current screen scale for use as a text attachment (inline math);
    /// `baselineOffset` is the attachment bounds y so the math baseline aligns with the text baseline.
    static func image(_ latex: String, options: Options, scale: CGFloat) -> (image: NSImage, baselineOffset: CGFloat) {
        let result = typeset(latex, options: options)
        let baselineOffset = result.baseline - result.size.height
        let scale = max(scale, 1)
        let pixelWidth = max(Int((result.size.width * scale).rounded(.up)), 1)
        let pixelHeight = max(Int((result.size.height * scale).rounded(.up)), 1)
        let image = NSImage(size: result.size)
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (image, baselineOffset)
        }
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        result.draw(context)
        guard let cgImage = context.makeImage() else { return (image, baselineOffset) }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        representation.size = result.size
        image.addRepresentation(representation)
        return (image, baselineOffset)
    }

    /// Parses and lays out without consulting the cache.
    static func typesetUncached(_ latex: String, options: Options) -> Result {
        let parsed = AgentMathParser.parse(latex)
        let layout = AgentMathLayout(fontSize: options.fontSize, textFontName: options.textFontName)
        let box = layout.layout(parsed, displayMode: options.displayMode)
        let ink = AgentMathRenderer.inkBounds(of: box)
        let left = ink.isNull ? 0 : max(0, -ink.minX).rounded(.up)
        let right = ink.isNull ? 0 : max(0, ink.maxX - box.width)
        let top = ink.isNull ? 0 : max(0, ink.maxY - box.height)
        let bottom = ink.isNull ? 0 : max(0, -ink.minY - box.depth)
        let ascent = box.height + top
        let size = CGSize(
            width: (left + box.width + right).rounded(.up),
            height: (ascent + box.depth + bottom).rounded(.up)
        )
        let color = options.color
        let errorColor = options.errorColor
        let draw: (CGContext) -> Void = { context in
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: left, y: ascent)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            let palette = AgentMathRenderer.Palette(foreground: color.cgColor, error: errorColor.cgColor)
            AgentMathRenderer.draw(box, in: context, at: .zero, palette: palette)
        }
        return Result(size: size, baseline: ascent, draw: draw, hasErrors: layout.hasErrors)
    }

    // MARK: Cache

    struct CacheKey: Hashable {
        var latex: String
        var displayMode: Bool
        var fontSize: CGFloat
        var color: NSColor
        var errorColor: NSColor
        var textFontName: String?
    }

    static let cache = AgentMathCache(capacity: 256)
}

/// A small thread-safe least-recently-used cache of typeset results.
final class AgentMathCache: @unchecked Sendable {
    private struct Entry {
        var result: AgentMathTypesetter.Result
        var lastUse: UInt64
    }

    let capacity: Int
    private let lock = NSLock()
    private var entries: [AgentMathTypesetter.CacheKey: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var hits = 0
    private(set) var misses = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func value(for key: AgentMathTypesetter.CacheKey) -> AgentMathTypesetter.Result? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else {
            misses += 1
            return nil
        }
        clock += 1
        entry.lastUse = clock
        entries[key] = entry
        hits += 1
        return entry.result
    }

    func insert(_ result: AgentMathTypesetter.Result, for key: AgentMathTypesetter.CacheKey) {
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        entries[key] = Entry(result: result, lastUse: clock)
        guard entries.count > capacity else { return }
        if let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            entries.removeValue(forKey: oldest)
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        hits = 0
        misses = 0
    }

    func contains(_ key: AgentMathTypesetter.CacheKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[key] != nil
    }
}

/// Draws laid-out boxes into a y-up context whose origin is on the baseline.
enum AgentMathRenderer {
    struct Palette {
        var foreground: CGColor
        var error: CGColor

        func color(_ ink: AgentMathInk) -> CGColor {
            switch ink {
            case .foreground: return foreground
            case .error: return error
            case .custom(let color): return color
            }
        }
    }

    static func draw(_ box: AgentMathBox, in context: CGContext, at origin: CGPoint, palette: Palette) {
        for item in box.items {
            switch item {
            case .glyphs(let font, let glyphs, let positions, let ink):
                context.setFillColor(palette.color(ink))
                let shifted = positions.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
                context.textPosition = .zero
                CTFontDrawGlyphs(font, glyphs, shifted, glyphs.count, context)
            case .line(let line, let position, let ink):
                context.setFillColor(palette.color(ink))
                context.textPosition = CGPoint(x: position.x + origin.x, y: position.y + origin.y)
                CTLineDraw(line, context)
            case .rule(let rect, let ink):
                context.setFillColor(palette.color(ink))
                context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
            case .stroke(let path, let lineWidth, let ink):
                context.saveGState()
                context.translateBy(x: origin.x, y: origin.y)
                context.setStrokeColor(palette.color(ink))
                context.setLineWidth(lineWidth)
                context.setLineCap(.round)
                context.addPath(path)
                context.strokePath()
                context.restoreGState()
            case .box(let child, let position):
                draw(child, in: context, at: CGPoint(x: origin.x + position.x, y: origin.y + position.y), palette: palette)
            }
        }
    }

    /// The union of everything a box draws, in its y-up coordinates; null when it draws nothing.
    static func inkBounds(of box: AgentMathBox, at origin: CGPoint = .zero) -> CGRect {
        var bounds = CGRect.null
        for item in box.items {
            switch item {
            case .glyphs(let font, let glyphs, let positions, _):
                var rects = [CGRect](repeating: .zero, count: glyphs.count)
                CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &rects, glyphs.count)
                for (rect, position) in zip(rects, positions) where !rect.isNull && !rect.isEmpty {
                    bounds = bounds.union(rect.offsetBy(dx: position.x + origin.x, dy: position.y + origin.y))
                }
            case .line(let line, let position, _):
                let rect = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                if !rect.isNull, !rect.isEmpty {
                    bounds = bounds.union(rect.offsetBy(dx: position.x + origin.x, dy: position.y + origin.y))
                }
            case .rule(let rect, _):
                bounds = bounds.union(rect.offsetBy(dx: origin.x, dy: origin.y))
            case .stroke(let path, let lineWidth, _):
                let rect = path.boundingBoxOfPath.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
                bounds = bounds.union(rect.offsetBy(dx: origin.x, dy: origin.y))
            case .box(let child, let position):
                bounds = bounds.union(inkBounds(of: child, at: CGPoint(x: origin.x + position.x, y: origin.y + position.y)))
            }
        }
        return bounds
    }
}
