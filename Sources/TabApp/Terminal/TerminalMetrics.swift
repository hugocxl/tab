import AppKit
import CoreText
import TabCore
import TabProtocol

/// The fonts a terminal draws with, resolved once per font configuration:
/// the primary family with the other configured families as its fallback
/// cascade, bold and italic faces (configured, from the family, or
/// synthesized), OpenType features, and Unicode-range fonts.
public final class TerminalFontSet {
    public struct Face {
        public let font: CTFont
        /// No bold face exists: draw with a stroke.
        public let syntheticBold: Bool
        /// Glyphs of printable ASCII by code point, when the font never
        /// substitutes them (no ligatures or contextual alternates), so ASCII
        /// text skips shaping.
        let ascii: [CGGlyph]?

        init(font: CTFont, syntheticBold: Bool) {
            self.font = font
            self.syntheticBold = syntheticBold
            ascii = Self.asciiGlyphs(font)
        }

        /// The cmap glyphs of ASCII 0x20...0x7E, or `nil` when shaping sample
        /// ligature sequences changes any glyph.
        static func asciiGlyphs(_ font: CTFont) -> [CGGlyph]? {
            var characters = (0..<128).map { UniChar($0) }
            var glyphs = [CGGlyph](repeating: 0, count: 128)
            CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 128)
            guard (0x21...0x7E).allSatisfy({ glyphs[$0] != 0 }) else { return nil }
            let sample = "fi fl ffi -> => == != === <= >= <> :: ::: www <!-- /* */ && || ++ -- ... |> <| ## ;; .= $( ~~"
            let string = CFAttributedStringCreate(nil, sample as CFString,
                                                  [kCTFontAttributeName: font] as CFDictionary)!
            let line = CTLineCreateWithAttributedString(string)
            let scalars = Array(sample.utf16)
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let count = CTRunGetGlyphCount(run)
                var runGlyphs = [CGGlyph](repeating: 0, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &runGlyphs)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                for index in 0..<count where runGlyphs[index] != glyphs[Int(scalars[indices[index]])] {
                    return nil
                }
            }
            guard CTLineGetGlyphCount(line) == scalars.count else { return nil }
            return glyphs
        }
    }

    public let size: CGFloat
    public let regular: Face
    public let bold: Face
    public let italic: Face
    public let boldItalic: Face
    public let thicken: Bool
    /// 0...1, from `font-thicken-strength`.
    public let thickenStrength: CGFloat
    /// Changes whenever a different font set is built, for cache keys.
    public let generation: UInt64
    private let maps: [FontMap]
    private var mapped: [String: CTFont] = [:]

    private static var nextGeneration: UInt64 = 0

    public init(families: [String], size: CGFloat, options: FontOptions) {
        Self.nextGeneration &+= 1
        generation = Self.nextGeneration
        self.size = size
        maps = options.codepoints
        thicken = options.thicken
        thickenStrength = CGFloat(options.thickenStrength) / 255
        let features = options.features.map { feature -> [CFString: Any] in
            [kCTFontOpenTypeFeatureTag: feature.tag, kCTFontOpenTypeFeatureValue: feature.value]
        }
        let fallbacks = families.dropFirst().map { family in
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        }
        func make(_ family: String?) -> CTFont? {
            guard let family else { return nil }
            var attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: family]
            if !features.isEmpty { attributes[kCTFontFeatureSettingsAttribute] = features }
            if !fallbacks.isEmpty { attributes[kCTFontCascadeListAttribute] = fallbacks }
            let font = CTFontCreateWithFontDescriptor(
                CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
            let name = CTFontCopyFamilyName(font) as String
            return name.caseInsensitiveCompare(family) == .orderedSame ? font : nil
        }
        let base = make(families.first)
            ?? make("Menlo")
            ?? CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
        regular = Face(font: base, syntheticBold: false)
        func variant(_ configured: [String], _ traits: CTFontSymbolicTraits) -> Face {
            if let font = make(configured.first) { return Face(font: font, syntheticBold: false) }
            if let font = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) {
                return Face(font: font, syntheticBold: false)
            }
            let wantsBold = traits.contains(.traitBold)
            let wantsItalic = traits.contains(.traitItalic)
            var font = base
            if wantsBold, let bold = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) {
                font = bold
            }
            var syntheticBold = wantsBold && font === base
            if wantsItalic {
                if let italic = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitItalic, .traitItalic) {
                    font = italic
                } else {
                    var skew = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
                    font = CTFontCreateCopyWithAttributes(font, size, &skew, nil)
                }
            }
            if wantsBold, !syntheticBold, !(CTFontGetSymbolicTraits(font).contains(.traitBold)) {
                syntheticBold = true
            }
            return Face(font: font, syntheticBold: syntheticBold)
        }
        bold = variant(options.bold, .traitBold)
        italic = variant(options.italic, .traitItalic)
        boldItalic = variant(options.boldItalic.isEmpty ? options.bold : options.boldItalic, [.traitBold, .traitItalic])
    }

    public convenience init(settings: TerminalSettings, size: Double? = nil) {
        self.init(families: settings.fontFamilies, size: CGFloat(size ?? settings.fontSize), options: settings.font)
    }

    public func face(bold isBold: Bool, italic isItalic: Bool) -> Face {
        switch (isBold, isItalic) {
        case (false, false): return regular
        case (true, false): return bold
        case (false, true): return italic
        case (true, true): return boldItalic
        }
    }

    /// The font a Unicode range is mapped to, if any.
    func mappedFont(for scalar: Unicode.Scalar, base: CTFont) -> CTFont? {
        guard !maps.isEmpty,
              let map = maps.last(where: { $0.start <= scalar.value && scalar.value <= $0.end }) else { return nil }
        if let font = mapped[map.family] { return font }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: map.family] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        mapped[map.family] = font
        return font
    }

    var hasMappedRanges: Bool { !maps.isEmpty }

    /// Whether a Unicode-range font covers printable ASCII.
    var mapsASCII: Bool { maps.contains { $0.start <= 0x7E && $0.end >= 0x20 } }
}

/// The size of a cell and where text sits in it, in points, snapped to the
/// display's pixels.
public struct TerminalMetrics: Equatable, Sendable {
    public var cellWidth: CGFloat
    public var cellHeight: CGFloat
    public var ascent: CGFloat
    public var descent: CGFloat
    public var leading: CGFloat
    /// From the top of a cell to the text baseline.
    public var baseline: CGFloat
    /// Pixels per point.
    public var scale: CGFloat
    /// One device pixel, in points; at least the font's underline thickness.
    public var lineThickness: CGFloat

    public init(cellWidth: CGFloat, cellHeight: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat = 0,
                baseline: CGFloat, scale: CGFloat, lineThickness: CGFloat) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        self.baseline = baseline
        self.scale = scale
        self.lineThickness = lineThickness
    }

    /// Measures the regular face: the advance of `M` for the width and
    /// ascent + descent + leading for the height, with the configured cell
    /// width and height adjustments.
    public init(fonts: TerminalFontSet, cellWidth widthAdjustment: CellHeight, cellHeight heightAdjustment: CellHeight,
                scale: CGFloat) {
        let font = fonts.regular.font
        let scale = max(scale, 1)
        var glyph = CGGlyph()
        var character = UniChar(UInt8(ascii: "M"))
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let naturalWidth = advance.width > 0 ? advance.width : fonts.size * 0.6
        let width = widthAdjustment.apply(natural: Double(naturalWidth), scale: Double(scale))
        let height = heightAdjustment.apply(natural: Double(ascent + descent + leading), scale: Double(scale))
        self.cellWidth = CGFloat(width)
        self.cellHeight = CGFloat(height)
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        self.scale = scale
        let extra = CGFloat(height) - (ascent + descent)
        baseline = ((extra / 2 + ascent) * scale).rounded() / scale
        lineThickness = max(1 / scale, (CTFontGetUnderlineThickness(font) * scale).rounded() / scale)
    }

    /// A cell in physical pixels, for kitty graphics placement on the server.
    public var physicalCellSize: CellSize {
        CellSize(width: UInt16(clamping: Int((cellWidth * scale).rounded())),
                 height: UInt16(clamping: Int((cellHeight * scale).rounded())))
    }
}

/// Where the cell grid sits in a terminal view: padding per edge, the
/// leftover space balanced when asked, and the grid size that fits.
public struct TerminalLayout: Equatable, Sendable {
    /// The whole view.
    public var bounds: CGRect
    /// The cell grid, `viewport.cols × viewport.rows` cells.
    public var grid: CGRect
    public var viewport: Size
    public var cellWidth: CGFloat
    public var cellHeight: CGFloat
    public var paddingColor: PaddingColor

    /// `basePadding` is the inset the host already gives the view (the pane
    /// card's), subtracted from the configured padding.
    public init(bounds: CGRect, metrics: TerminalMetrics, options: TerminalOptions, basePadding: CGFloat = 0) {
        func inset(_ values: [Double], _ index: Int) -> CGFloat {
            max(0, CGFloat(values.indices.contains(index) ? values[index] : 0) - basePadding)
        }
        let left = inset(options.paddingX, 0)
        let right = inset(options.paddingX, 1)
        let top = inset(options.paddingY, 0)
        let bottom = inset(options.paddingY, 1)
        var content = CGRect(x: bounds.minX + left, y: bounds.minY + top,
                             width: max(0, bounds.width - left - right), height: max(0, bounds.height - top - bottom))
        let cols = max(1, Int(content.width / metrics.cellWidth))
        let rows = max(1, Int(content.height / metrics.cellHeight))
        let viewport = Size(cols: UInt16(clamping: min(cols, Int(Limits.maxCols))),
                            rows: UInt16(clamping: min(rows, Int(Limits.maxRows))))
        let gridWidth = CGFloat(viewport.cols) * metrics.cellWidth
        let gridHeight = CGFloat(viewport.rows) * metrics.cellHeight
        if options.paddingBalance {
            let scale = metrics.scale
            content.origin.x += (max(0, content.width - gridWidth) / 2 * scale).rounded(.down) / scale
            content.origin.y += (max(0, content.height - gridHeight) / 2 * scale).rounded(.down) / scale
        }
        self.bounds = bounds
        grid = CGRect(x: content.minX, y: content.minY, width: gridWidth, height: gridHeight)
        self.viewport = viewport
        cellWidth = metrics.cellWidth
        cellHeight = metrics.cellHeight
        paddingColor = options.paddingColor
    }

    /// The view rectangle of a visible row, across the whole width so that
    /// padding colors redraw with it.
    public func rowRect(_ row: Int) -> CGRect {
        var rect = CGRect(x: bounds.minX, y: grid.minY + CGFloat(row) * cellHeight, width: bounds.width, height: cellHeight)
        if row == 0 { rect = rect.union(CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 0)) }
        if row == Int(viewport.rows) - 1 {
            rect = rect.union(CGRect(x: bounds.minX, y: bounds.maxY, width: bounds.width, height: 0))
        }
        return rect
    }

    public func cellRect(row: Int, column: Int, width: Int = 1) -> CGRect {
        CGRect(x: grid.minX + CGFloat(column) * cellWidth, y: grid.minY + CGFloat(row) * cellHeight,
               width: CGFloat(width) * cellWidth, height: cellHeight)
    }

    /// The visible rows a rectangle touches; the padding above and below
    /// belongs to the first and last rows.
    public func rows(in rect: CGRect) -> Range<Int> {
        let rows = Int(viewport.rows)
        guard rows > 0, rect.maxY > bounds.minY, rect.minY < bounds.maxY else { return 0..<0 }
        var first = Int(((rect.minY - grid.minY) / cellHeight).rounded(.down))
        var last = Int(((rect.maxY - grid.minY) / cellHeight).rounded(.up))
        first = Swift.min(Swift.max(first, 0), rows - 1)
        last = Swift.min(Swift.max(last, first + 1), rows)
        return first..<last
    }
}
