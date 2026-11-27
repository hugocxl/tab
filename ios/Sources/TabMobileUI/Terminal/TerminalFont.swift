import CoreText
import UIKit

/// SF Mono in four faces, with cell metrics snapped to whole pixels and
/// ASCII glyphs looked up once, so drawing ASCII never shapes text.
final class TerminalFont {
    let size: CGFloat
    let scale: CGFloat
    let faces: [CTFont]
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let ascent: CGFloat
    /// Fallback slant for a face without a real italic.
    let syntheticItalic: [Bool]
    /// `glyphs[face][byte]` for printable ASCII.
    private let ascii: [[CGGlyph]]

    init(size: CGFloat, scale: CGFloat) {
        self.size = size
        self.scale = scale
        let regular = UIFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        let bold = UIFont.monospacedSystemFont(ofSize: size, weight: .semibold) as CTFont
        func italic(_ font: CTFont) -> (CTFont, Bool) {
            if let slanted = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitItalic, .traitItalic) {
                return (slanted, false)
            }
            return (font, true)
        }
        let (italicFace, italicSynthetic) = italic(regular)
        let (boldItalicFace, boldItalicSynthetic) = italic(bold)
        faces = [regular, bold, italicFace, boldItalicFace]
        syntheticItalic = [false, false, italicSynthetic, boldItalicSynthetic]

        var glyph = CGGlyph()
        var character = UniChar(UInt8(ascii: "M"))
        CTFontGetGlyphsForCharacters(regular, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.up) / scale }
        cellWidth = (advance.width * scale).rounded() / scale
        let lineHeight = CTFontGetAscent(regular) + CTFontGetDescent(regular) + CTFontGetLeading(regular)
        cellHeight = snap(lineHeight * 1.12)
        // Center the line in the taller cell, on a whole pixel.
        ascent = ((CTFontGetAscent(regular) + (cellHeight - lineHeight) / 2) * scale).rounded() / scale

        ascii = faces.map { face in
            var characters = (0..<128).map { UniChar($0) }
            var glyphs = [CGGlyph](repeating: 0, count: 128)
            CTFontGetGlyphsForCharacters(face, &characters, &glyphs, 128)
            return glyphs
        }
    }

    func face(bold: Bool, italic: Bool) -> Int { (bold ? 1 : 0) + (italic ? 2 : 0) }

    func asciiGlyph(_ byte: UInt8, face: Int) -> CGGlyph { ascii[face][Int(byte & 0x7F)] }
}
