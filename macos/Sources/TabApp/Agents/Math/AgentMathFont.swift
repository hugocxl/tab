import AppKit
import CoreText

/// Math constants from the OpenType MATH table, in the order of its MathValueRecords.
enum AgentMathConstant: Int, CaseIterable {
    case mathLeading = 0, axisHeight, accentBaseHeight, flattenedAccentBaseHeight
    case subscriptShiftDown, subscriptTopMax, subscriptBaselineDropMin
    case superscriptShiftUp, superscriptShiftUpCramped, superscriptBottomMin, superscriptBaselineDropMax
    case subSuperscriptGapMin, superscriptBottomMaxWithSubscript, spaceAfterScript
    case upperLimitGapMin, upperLimitBaselineRiseMin, lowerLimitGapMin, lowerLimitBaselineDropMin
    case stackTopShiftUp, stackTopDisplayStyleShiftUp, stackBottomShiftDown, stackBottomDisplayStyleShiftDown
    case stackGapMin, stackDisplayStyleGapMin
    case stretchStackTopShiftUp, stretchStackBottomShiftDown, stretchStackGapAboveMin, stretchStackGapBelowMin
    case fractionNumeratorShiftUp, fractionNumeratorDisplayStyleShiftUp
    case fractionDenominatorShiftDown, fractionDenominatorDisplayStyleShiftDown
    case fractionNumeratorGapMin, fractionNumDisplayStyleGapMin, fractionRuleThickness
    case fractionDenominatorGapMin, fractionDenomDisplayStyleGapMin
    case skewedFractionHorizontalGap, skewedFractionVerticalGap
    case overbarVerticalGap, overbarRuleThickness, overbarExtraAscender
    case underbarVerticalGap, underbarRuleThickness, underbarExtraDescender
    case radicalVerticalGap, radicalDisplayStyleVerticalGap, radicalRuleThickness
    case radicalExtraAscender, radicalKernBeforeDegree, radicalKernAfterDegree
}

/// A glyph variant or a recipe for building a stretched glyph from parts.
struct AgentMathGlyphConstruction: Sendable {
    struct Variant: Sendable {
        var glyph: CGGlyph
        var advance: CGFloat
    }

    struct Part: Sendable {
        var glyph: CGGlyph
        var startConnector: CGFloat
        var endConnector: CGFloat
        var fullAdvance: CGFloat
        var isExtender: Bool
    }

    var variants: [Variant]
    var parts: [Part]
}

/// STIX Two Math with its OpenType MATH table, or the system font with
/// TeX-like defaults when it is missing. All values are in font design units.
final class AgentMathFont: @unchecked Sendable {
    static let shared = AgentMathFont()

    let isMathFont: Bool
    let unitsPerEm: CGFloat
    let minConnectorOverlap: CGFloat
    let delimitedSubFormulaMinHeight: CGFloat
    let displayOperatorMinHeight: CGFloat
    let radicalDegreeBottomRaisePercent: CGFloat
    private let baseFont: CTFont
    private let constants: [CGFloat]
    private let italicCorrections: [CGGlyph: CGFloat]
    private let topAccentAttachments: [CGGlyph: CGFloat]
    private let verticalConstructions: [CGGlyph: AgentMathGlyphConstruction]
    private let horizontalConstructions: [CGGlyph: AgentMathGlyphConstruction]
    private let lock = NSLock()
    private var fontsBySize: [CGFloat: CTFont] = [:]

    private init() {
        let candidate = CTFontCreateWithName("STIXTwoMath-Regular" as CFString, 12, nil)
        let isStix = (CTFontCopyPostScriptName(candidate) as String) == "STIXTwoMath-Regular"
        let table = isStix ? CTFontCopyTable(candidate, CTFontTableTag(0x4D41_5448), []) as Data? : nil
        let reader = table.flatMap(MathTableReader.init)
        if let reader {
            baseFont = candidate
            isMathFont = true
            unitsPerEm = CGFloat(CTFontGetUnitsPerEm(candidate))
            constants = reader.constants
            minConnectorOverlap = reader.minConnectorOverlap
            delimitedSubFormulaMinHeight = reader.delimitedSubFormulaMinHeight
            displayOperatorMinHeight = reader.displayOperatorMinHeight
            radicalDegreeBottomRaisePercent = reader.radicalDegreeBottomRaisePercent
            italicCorrections = reader.italicCorrections
            topAccentAttachments = reader.topAccentAttachments
            verticalConstructions = reader.verticalConstructions
            horizontalConstructions = reader.horizontalConstructions
            return
        }
        baseFont = isStix ? candidate : CTFontCreateUIFontForLanguage(.system, 12, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        isMathFont = false
        unitsPerEm = 1000
        constants = Self.fallbackConstants
        minConnectorOverlap = 20
        delimitedSubFormulaMinHeight = 1325
        displayOperatorMinHeight = 1800
        radicalDegreeBottomRaisePercent = 55
        italicCorrections = [:]
        topAccentAttachments = [:]
        verticalConstructions = [:]
        horizontalConstructions = [:]
    }

    /// The math font at `size`, cached because layout asks for the same few sizes repeatedly.
    func font(size: CGFloat) -> CTFont {
        lock.lock()
        defer { lock.unlock() }
        if let font = fontsBySize[size] { return font }
        let font = CTFontCreateCopyWithAttributes(baseFont, size, nil, nil)
        if fontsBySize.count > 64 { fontsBySize.removeAll() }
        fontsBySize[size] = font
        return font
    }

    /// A constant scaled to points at `size`.
    func value(_ constant: AgentMathConstant, size: CGFloat) -> CGFloat {
        constants[constant.rawValue] * size / unitsPerEm
    }

    func italicCorrection(_ glyph: CGGlyph, size: CGFloat) -> CGFloat {
        (italicCorrections[glyph] ?? 0) * size / unitsPerEm
    }

    func topAccentAttachment(_ glyph: CGGlyph, size: CGFloat) -> CGFloat? {
        topAccentAttachments[glyph].map { $0 * size / unitsPerEm }
    }

    func verticalConstruction(_ glyph: CGGlyph) -> AgentMathGlyphConstruction? {
        verticalConstructions[glyph]
    }

    func horizontalConstruction(_ glyph: CGGlyph) -> AgentMathGlyphConstruction? {
        horizontalConstructions[glyph]
    }

    /// STIX Two Math's values, used when the font has no readable MATH table.
    private static let fallbackConstants: [CGFloat] = {
        var values = [CGFloat](repeating: 0, count: AgentMathConstant.allCases.count)
        let pairs: [(AgentMathConstant, CGFloat)] = [
            (.mathLeading, 150), (.axisHeight, 258), (.accentBaseHeight, 480), (.flattenedAccentBaseHeight, 656),
            (.subscriptShiftDown, 210), (.subscriptTopMax, 368), (.subscriptBaselineDropMin, 160),
            (.superscriptShiftUp, 360), (.superscriptShiftUpCramped, 252), (.superscriptBottomMin, 120),
            (.superscriptBaselineDropMax, 230), (.subSuperscriptGapMin, 150),
            (.superscriptBottomMaxWithSubscript, 380), (.spaceAfterScript, 40), (.upperLimitGapMin, 150),
            (.upperLimitBaselineRiseMin, 300), (.lowerLimitGapMin, 150), (.lowerLimitBaselineDropMin, 600),
            (.stackTopShiftUp, 470), (.stackTopDisplayStyleShiftUp, 780), (.stackBottomShiftDown, 385),
            (.stackBottomDisplayStyleShiftDown, 690), (.stackGapMin, 150), (.stackDisplayStyleGapMin, 300),
            (.stretchStackTopShiftUp, 800), (.stretchStackBottomShiftDown, 590), (.stretchStackGapAboveMin, 68),
            (.stretchStackGapBelowMin, 68), (.fractionNumeratorShiftUp, 394),
            (.fractionNumeratorDisplayStyleShiftUp, 677), (.fractionDenominatorShiftDown, 345),
            (.fractionDenominatorDisplayStyleShiftDown, 686), (.fractionNumeratorGapMin, 40),
            (.fractionNumDisplayStyleGapMin, 120), (.fractionRuleThickness, 68),
            (.fractionDenominatorGapMin, 40), (.fractionDenomDisplayStyleGapMin, 120),
            (.overbarVerticalGap, 150), (.overbarRuleThickness, 66), (.overbarExtraAscender, 50),
            (.underbarVerticalGap, 150), (.underbarRuleThickness, 66), (.underbarExtraDescender, 50),
            (.radicalVerticalGap, 74), (.radicalDisplayStyleVerticalGap, 170), (.radicalRuleThickness, 68),
            (.radicalExtraAscender, 66), (.radicalKernBeforeDegree, 65), (.radicalKernAfterDegree, -335),
        ]
        for (constant, value) in pairs { values[constant.rawValue] = value }
        return values
    }()
}

/// Reads the parts of the OpenType MATH table that layout needs.
private struct MathTableReader {
    var constants: [CGFloat] = []
    var minConnectorOverlap: CGFloat = 0
    var delimitedSubFormulaMinHeight: CGFloat = 0
    var displayOperatorMinHeight: CGFloat = 0
    var radicalDegreeBottomRaisePercent: CGFloat = 0
    var italicCorrections: [CGGlyph: CGFloat] = [:]
    var topAccentAttachments: [CGGlyph: CGFloat] = [:]
    var verticalConstructions: [CGGlyph: AgentMathGlyphConstruction] = [:]
    var horizontalConstructions: [CGGlyph: AgentMathGlyphConstruction] = [:]

    private let bytes: [UInt8]

    init?(_ data: Data) {
        bytes = [UInt8](data)
        guard bytes.count >= 10, u16(0) == 1 else { return nil }
        let constantsOffset = Int(u16(4))
        let glyphInfoOffset = Int(u16(6))
        let variantsOffset = Int(u16(8))
        let recordCount = AgentMathConstant.allCases.count
        guard constantsOffset > 0, constantsOffset + 8 + recordCount * 4 + 2 <= bytes.count else { return nil }
        delimitedSubFormulaMinHeight = CGFloat(u16(constantsOffset + 4))
        displayOperatorMinHeight = CGFloat(u16(constantsOffset + 6))
        constants = (0..<recordCount).map { CGFloat(i16(constantsOffset + 8 + $0 * 4)) }
        radicalDegreeBottomRaisePercent = CGFloat(i16(constantsOffset + 8 + recordCount * 4))
        if glyphInfoOffset > 0 { readGlyphInfo(at: glyphInfoOffset) }
        if variantsOffset > 0 { readVariants(at: variantsOffset) }
    }

    private func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private func i16(_ offset: Int) -> Int16 {
        Int16(bitPattern: u16(offset))
    }

    private func coverage(at offset: Int) -> [CGGlyph] {
        switch u16(offset) {
        case 1:
            let count = Int(u16(offset + 2))
            return (0..<count).map { u16(offset + 4 + $0 * 2) }
        case 2:
            var glyphs: [CGGlyph] = []
            let ranges = Int(u16(offset + 2))
            for range in 0..<ranges {
                let record = offset + 4 + range * 6
                let start = u16(record), end = u16(record + 2)
                guard start <= end else { continue }
                glyphs += Array(start...end)
            }
            return glyphs
        default:
            return []
        }
    }

    /// A coverage table paired with a MathValueRecord array, as used by italics and accents.
    private func valueTable(at offset: Int) -> [CGGlyph: CGFloat] {
        let glyphs = coverage(at: offset + Int(u16(offset)))
        let count = Int(u16(offset + 2))
        var table: [CGGlyph: CGFloat] = [:]
        for (index, glyph) in glyphs.prefix(count).enumerated() {
            table[glyph] = CGFloat(i16(offset + 4 + index * 4))
        }
        return table
    }

    private mutating func readGlyphInfo(at offset: Int) {
        let italicsOffset = Int(u16(offset))
        let accentOffset = Int(u16(offset + 2))
        if italicsOffset > 0 { italicCorrections = valueTable(at: offset + italicsOffset) }
        if accentOffset > 0 { topAccentAttachments = valueTable(at: offset + accentOffset) }
    }

    private mutating func readVariants(at offset: Int) {
        minConnectorOverlap = CGFloat(u16(offset))
        let verticalCoverage = coverage(at: offset + Int(u16(offset + 2)))
        let horizontalCoverage = coverage(at: offset + Int(u16(offset + 4)))
        let verticalCount = Int(u16(offset + 6))
        let horizontalCount = Int(u16(offset + 8))
        for (index, glyph) in verticalCoverage.prefix(verticalCount).enumerated() {
            let constructionOffset = Int(u16(offset + 10 + index * 2))
            guard constructionOffset > 0 else { continue }
            verticalConstructions[glyph] = construction(at: offset + constructionOffset)
        }
        for (index, glyph) in horizontalCoverage.prefix(horizontalCount).enumerated() {
            let constructionOffset = Int(u16(offset + 10 + (verticalCount + index) * 2))
            guard constructionOffset > 0 else { continue }
            horizontalConstructions[glyph] = construction(at: offset + constructionOffset)
        }
    }

    private func construction(at offset: Int) -> AgentMathGlyphConstruction {
        let assemblyOffset = Int(u16(offset))
        let variantCount = Int(u16(offset + 2))
        let variants = (0..<variantCount).map { index in
            AgentMathGlyphConstruction.Variant(
                glyph: u16(offset + 4 + index * 4),
                advance: CGFloat(u16(offset + 6 + index * 4))
            )
        }
        guard assemblyOffset > 0 else { return AgentMathGlyphConstruction(variants: variants, parts: []) }
        let assembly = offset + assemblyOffset
        let partCount = Int(u16(assembly + 4))
        let parts = (0..<partCount).map { index in
            let record = assembly + 6 + index * 10
            return AgentMathGlyphConstruction.Part(
                glyph: u16(record),
                startConnector: CGFloat(u16(record + 2)),
                endConnector: CGFloat(u16(record + 4)),
                fullAdvance: CGFloat(u16(record + 6)),
                isExtender: u16(record + 8) & 1 == 1
            )
        }
        return AgentMathGlyphConstruction(variants: variants, parts: parts)
    }
}
