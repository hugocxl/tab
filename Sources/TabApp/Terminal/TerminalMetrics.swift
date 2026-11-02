import AppKit
import CoreText
import TabCore
import TabProtocol

/// The fonts a terminal draws with, resolved once per font configuration:
/// the family in the chosen style with the fallback fonts as its cascade,
/// bold and italic faces (from the family, or synthesized), and ligatures.
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
            guard let string = CFAttributedStringCreate(nil, sample as CFString,
                                                        [kCTFontAttributeName: font] as CFDictionary) else { return nil }
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
    /// Draws glyphs with macOS font smoothing, which renders them heavier.
    public let smoothing: Bool
    /// Changes whenever a different font set is built, for cache keys.
    public let generation: UInt64

    private static var nextGeneration: UInt64 = 0
    /// Turn off ligatures and contextual alternates.
    private static let noLigatures: [[CFString: Any]] = ["calt", "liga", "dlig"].map {
        [kCTFontOpenTypeFeatureTag: $0, kCTFontOpenTypeFeatureValue: 0]
    }

    public init(family: String, style: String, fallbacks: [String], size: CGFloat, ligatures: Bool = true,
                smoothing: Bool = false) {
        Self.nextGeneration &+= 1
        generation = Self.nextGeneration
        self.size = size
        self.smoothing = smoothing
        let features = ligatures ? [] : Self.noLigatures
        let cascade = fallbacks.map { family in
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        }
        func make(_ family: String, style: String?) -> CTFont? {
            var attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: family]
            if let style { attributes[kCTFontStyleNameAttribute] = style }
            if !features.isEmpty { attributes[kCTFontFeatureSettingsAttribute] = features }
            if !cascade.isEmpty { attributes[kCTFontCascadeListAttribute] = cascade }
            let font = CTFontCreateWithFontDescriptor(
                CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
            guard (CTFontCopyFamilyName(font) as String).caseInsensitiveCompare(family) == .orderedSame else { return nil }
            if let style, (CTFontCopyName(font, kCTFontStyleNameKey) as String?)?.caseInsensitiveCompare(style) != .orderedSame {
                return nil
            }
            return font
        }
        let base = make(family, style: style) ?? make(family, style: nil) ?? make("Menlo", style: nil)
            ?? CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
        regular = Face(font: base, syntheticBold: false)
        func variant(_ traits: CTFontSymbolicTraits) -> Face {
            if let font = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) {
                return Face(font: font, syntheticBold: false)
            }
            let wantsBold = traits.contains(.traitBold)
            var font = base
            if wantsBold, let bold = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) {
                font = bold
            }
            var syntheticBold = wantsBold && font === base
            if traits.contains(.traitItalic) {
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
        bold = variant(.traitBold)
        italic = variant(.traitItalic)
        boldItalic = variant([.traitBold, .traitItalic])
    }

    public convenience init(settings: TerminalSettings, size: Double? = nil) {
        self.init(family: settings.fontFamily, style: settings.fontStyle, fallbacks: settings.fallbackFonts,
                  size: CGFloat(size ?? settings.fontSize), ligatures: settings.ligatures,
                  smoothing: settings.fontSmoothing)
    }

    public func face(bold isBold: Bool, italic isItalic: Bool) -> Face {
        switch (isBold, isItalic) {
        case (false, false): return regular
        case (true, false): return bold
        case (false, true): return italic
        case (true, true): return boldItalic
        }
    }
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
    /// ascent + descent + leading for the height, with the configured
    /// character spacing and line height.
    public init(fonts: TerminalFontSet, cellWidth widthAdjustment: CellAdjustment, cellHeight heightAdjustment: CellAdjustment,
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

    /// Measures `fonts` with the settings' character spacing and line height.
    public init(fonts: TerminalFontSet, settings: TerminalSettings, scale: CGFloat) {
        self.init(fonts: fonts, cellWidth: settings.characterSpacing,
                  cellHeight: settings.lineHeight == 0 ? .natural : .percent(settings.lineHeight), scale: scale)
    }

    /// A cell in physical pixels, for kitty graphics placement on the server.
    public var physicalCellSize: CellSize {
        CellSize(width: UInt16(clamping: Int((cellWidth * scale).rounded())),
                 height: UInt16(clamping: Int((cellHeight * scale).rounded())))
    }
}

/// Where the cell grid sits in a terminal view: inside a small padding, and
/// the grid size that fits.
public struct TerminalLayout: Equatable, Sendable {
    /// Space around the cell grid, in points, before the host's own inset.
    public static let padding: CGFloat = 2

    /// The whole view.
    public var bounds: CGRect
    /// The cell grid, `viewport.cols × viewport.rows` cells.
    public var grid: CGRect
    public var viewport: Size
    public var cellWidth: CGFloat
    public var cellHeight: CGFloat

    /// `basePadding` is the inset the host already gives the view (the pane
    /// card's), subtracted from the padding.
    public init(bounds: CGRect, metrics: TerminalMetrics, basePadding: CGFloat = 0) {
        let inset = max(0, Self.padding - basePadding)
        let content = bounds.insetBy(dx: min(inset, bounds.width / 2), dy: min(inset, bounds.height / 2))
        let cols = max(1, Int(content.width / metrics.cellWidth))
        let rows = max(1, Int(content.height / metrics.cellHeight))
        let viewport = Size(cols: UInt16(clamping: min(cols, Int(Limits.maxCols))),
                            rows: UInt16(clamping: min(rows, Int(Limits.maxRows))))
        self.bounds = bounds
        grid = CGRect(x: content.minX, y: content.minY, width: CGFloat(viewport.cols) * metrics.cellWidth,
                      height: CGFloat(viewport.rows) * metrics.cellHeight)
        self.viewport = viewport
        cellWidth = metrics.cellWidth
        cellHeight = metrics.cellHeight
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
