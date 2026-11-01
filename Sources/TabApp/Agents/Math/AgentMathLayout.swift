import AppKit
import CoreText

/// What color a draw item takes; resolved when drawing so cached layouts stay color independent.
enum AgentMathInk {
    case foreground
    case error
    case custom(CGColor)
}

/// A TeX box: a width, a height above the baseline and a depth below it, with
/// what to draw relative to its baseline origin in a y-up coordinate space.
struct AgentMathBox {
    var width: CGFloat = 0
    var height: CGFloat = 0
    var depth: CGFloat = 0
    var italicCorrection: CGFloat = 0
    /// Where an accent centers over this box, from the font's top accent attachment.
    var accentAttachment: CGFloat?
    /// A single glyph; scripts on characters start from the font's shifts instead of the box edges.
    var isCharacter = false
    var items: [AgentMathDrawItem] = []

    /// Adds `box` with its baseline origin at (`x`, `y`) without changing the metrics.
    mutating func place(_ box: AgentMathBox, x: CGFloat, y: CGFloat) {
        guard !box.items.isEmpty else { return }
        if x == 0, y == 0, box.items.count == 1 {
            items.append(box.items[0])
            return
        }
        items.append(.box(box, CGPoint(x: x, y: y)))
    }
}

indirect enum AgentMathDrawItem {
    case glyphs(CTFont, [CGGlyph], [CGPoint], AgentMathInk)
    case line(CTLine, CGPoint, AgentMathInk)
    case rule(CGRect, AgentMathInk)
    case stroke(CGPath, lineWidth: CGFloat, AgentMathInk)
    case box(AgentMathBox, CGPoint)
}

/// The style, crampedness, alphabet and color in effect while laying out a node.
struct AgentMathLayoutContext {
    var style: AgentMathStyle
    var cramped = false
    var variant: AgentMathFontVariant = .normal
    var ink: AgentMathInk = .foreground

    private var smaller: AgentMathStyle {
        switch style {
        case .display, .text: return .script
        case .script, .scriptScript: return .scriptScript
        }
    }

    var superscript: Self {
        var context = self
        context.style = smaller
        return context
    }

    var `subscript`: Self {
        var context = superscript
        context.cramped = true
        return context
    }

    var numerator: Self {
        var context = self
        context.style = style == .display ? .text : smaller
        return context
    }

    var denominator: Self {
        var context = numerator
        context.cramped = true
        return context
    }

    var crampedVersion: Self {
        var context = self
        context.cramped = true
        return context
    }
}

/// Lays out a parse tree into boxes following TeX's rules, with the
/// parameters and glyph variants of the OpenType MATH table.
final class AgentMathLayout {
    private struct Atom {
        var box: AgentMathBox
        /// nil for explicit spaces, which don't take part in inter-atom spacing.
        var atomClass: AgentMathAtomClass?
        var style: AgentMathStyle
        var middleDelimiter: String?
    }

    private let font: AgentMathFont
    private let baseSize: CGFloat
    private let textFontName: String?
    private(set) var hasErrors = false

    init(font: AgentMathFont = .shared, fontSize: CGFloat, textFontName: String? = nil) {
        self.font = font
        baseSize = max(fontSize, 1)
        self.textFontName = textFontName
    }

    /// Lays out a whole expression; `\tag`s go to the right of the content.
    func layout(_ parsed: AgentMathParseResult, displayMode: Bool) -> AgentMathBox {
        hasErrors = !parsed.errors.isEmpty
        let context = AgentMathLayoutContext(style: displayMode ? .display : .text)
        var tags: [String] = []
        let content = parsed.nodes.filter { node in
            guard case .tag(let tag) = node else { return true }
            tags.append(tag)
            return false
        }
        var box = layoutList(content, context)
        guard let tag = tags.first else { return box }
        let tagBox = textBox("(\(tag))", variant: .normal, context)
        var tagged = AgentMathBox()
        tagged.place(box, x: 0, y: 0)
        let x = box.width + 2 * baseSize
        tagged.place(tagBox, x: x, y: 0)
        tagged.width = x + tagBox.width
        tagged.height = max(box.height, tagBox.height)
        tagged.depth = max(box.depth, tagBox.depth)
        box = tagged
        return box
    }

    func size(of style: AgentMathStyle) -> CGFloat {
        switch style {
        case .display, .text: return baseSize
        case .script: return baseSize * 0.7
        case .scriptScript: return baseSize * 0.5
        }
    }

    private func value(_ constant: AgentMathConstant, _ context: AgentMathLayoutContext) -> CGFloat {
        font.value(constant, size: size(of: context.style))
    }

    // MARK: Lists

    private static func nodes(of node: AgentMathNode) -> [AgentMathNode] {
        if case .group(let nodes) = node { return nodes }
        return [node]
    }

    func layoutList(_ nodes: [AgentMathNode], _ context: AgentMathLayoutContext) -> AgentMathBox {
        var atoms: [Atom] = []
        collectAtoms(nodes, context, into: &atoms)
        return pack(atoms)
    }

    private func collectAtoms(_ nodes: [AgentMathNode], _ context: AgentMathLayoutContext, into atoms: inout [Atom]) {
        for node in nodes {
            switch node {
            case .font(let variant, let children):
                var inner = context
                inner.variant = variant
                collectAtoms(children, inner, into: &atoms)
            case .style(let style, let children):
                var inner = context
                inner.style = style
                inner.cramped = false
                collectAtoms(children, inner, into: &atoms)
            case .color(let name, let children):
                var inner = context
                if let value = AgentMathSymbols.colorValue(name) { inner.ink = .custom(Self.color(value)) }
                collectAtoms(children, inner, into: &atoms)
            case .tag:
                continue
            case .middle(let delimiter):
                atoms.append(Atom(box: AgentMathBox(), atomClass: .ord, style: context.style, middleDelimiter: delimiter))
            default:
                atoms.append(layoutAtom(node, context))
            }
        }
    }

    private static func color(_ value: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private func pack(_ input: [Atom]) -> AgentMathBox {
        if input.count == 1, input[0].atomClass != nil { return input[0].box }
        var atoms = input
        reclassifyBinaryOperators(&atoms)
        var box = AgentMathBox()
        var x: CGFloat = 0
        var previous: AgentMathAtomClass?
        for atom in atoms {
            if let atomClass = atom.atomClass {
                if let previous { x += spacing(previous, atomClass, style: atom.style) }
                previous = atomClass
            }
            box.place(atom.box, x: x, y: 0)
            box.height = max(box.height, atom.box.height)
            box.depth = max(box.depth, atom.box.depth)
            x += atom.box.width
        }
        box.width = x
        box.italicCorrection = atoms.last?.box.italicCorrection ?? 0
        return box
    }

    /// TeX rules 5 and 6: a binary operator with nothing to operate on becomes ordinary.
    private func reclassifyBinaryOperators(_ atoms: inout [Atom]) {
        var previousIndex: Int?
        for index in atoms.indices {
            guard let atomClass = atoms[index].atomClass else { continue }
            let previousClass = previousIndex.flatMap { atoms[$0].atomClass }
            if atomClass == .bin {
                if previousClass == nil || [.bin, .op, .rel, .open, .punct].contains(previousClass) {
                    atoms[index].atomClass = .ord
                }
            } else if [.rel, .close, .punct].contains(atomClass), let previousIndex, previousClass == .bin {
                atoms[previousIndex].atomClass = .ord
            }
            previousIndex = index
        }
        if let previousIndex, atoms[previousIndex].atomClass == .bin {
            atoms[previousIndex].atomClass = .ord
        }
    }

    /// TeX's inter-atom spacing table; negative entries apply only in display and text styles.
    private static let spacingTable: [[Int]] = [
        [0, 1, -2, -3, 0, 0, 0, -1],
        [1, 1, 0, -3, 0, 0, 0, -1],
        [-2, -2, 0, 0, -2, 0, 0, -2],
        [-3, -3, 0, 0, -3, 0, 0, -3],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 1, -2, -3, 0, 0, 0, -1],
        [-1, -1, 0, -1, -1, -1, -1, -1],
        [-1, 1, -2, -3, -1, 0, -1, -1],
    ]

    private static func index(of atomClass: AgentMathAtomClass) -> Int {
        switch atomClass {
        case .ord: return 0
        case .op: return 1
        case .bin: return 2
        case .rel: return 3
        case .open: return 4
        case .close: return 5
        case .punct: return 6
        case .inner: return 7
        }
    }

    func spacing(_ left: AgentMathAtomClass, _ right: AgentMathAtomClass, style: AgentMathStyle) -> CGFloat {
        let entry = Self.spacingTable[Self.index(of: left)][Self.index(of: right)]
        let isScript = style == .script || style == .scriptScript
        if entry < 0, isScript { return 0 }
        let mu: CGFloat = switch abs(entry) {
        case 1: 3
        case 2: 4
        case 3: 5
        default: 0
        }
        return mu * size(of: style) / 18
    }

    // MARK: Atoms

    private func layoutAtom(_ node: AgentMathNode, _ context: AgentMathLayoutContext) -> Atom {
        func atom(_ box: AgentMathBox, _ atomClass: AgentMathAtomClass? = .ord) -> Atom {
            Atom(box: box, atomClass: atomClass, style: context.style)
        }
        switch node {
        case .symbol(let text, let atomClass):
            return atom(glyphBox(text, context), atomClass)
        case .number(let digits):
            return atom(glyphBox(digits, context))
        case .text(let text, let variant):
            return atom(textBox(text, variant: variant, context))
        case .group(let nodes):
            return atom(layoutList(nodes, context))
        case .scripts(let base, let sub, let sup):
            return scriptsAtom(base: base, sub: sub, sup: sup, context)
        case .largeOperator(let op):
            return atom(operatorBox(op, context), .op)
        case .fraction(let numerator, let denominator, let hasRule, let style):
            return atom(fractionBox(numerator, denominator, hasRule: hasRule, style: style, context))
        case .radical(let radicand, let index):
            return atom(radicalBox(radicand, index: index, context))
        case .leftRight(let left, let body, let right):
            return atom(leftRightBox(left: left, body: body, right: right, context), .inner)
        case .middle(let delimiter):
            return atom(delimiterBox(delimiter, total: 0, context))
        case .sizedDelimiter(let delimiter, let level, let atomClass):
            let heights: [CGFloat] = [1.2, 1.8, 2.4, 3.0]
            let total = heights[min(max(level, 1), 4) - 1] * size(of: context.style)
            return atom(delimiterBox(delimiter, total: total, context, sized: true), atomClass)
        case .accent(let base, let accent, let isStretchy):
            return atom(accentBox(base, accent: accent, isStretchy: isStretchy, context))
        case .overline(let base):
            return atom(overlineBox(base, context))
        case .underline(let base):
            return atom(underlineBox(base, context))
        case .horizontalBrace(let base, let isOver):
            return atom(braceBox(base, isOver: isOver, context))
        case .underOver(let base, let over, let under, let atomClass):
            let baseBox = layoutList(Self.nodes(of: base), context)
            return atom(limitsBox(baseBox, sub: under, sup: over, context), atomClass)
        case .extensibleArrow(let arrow, let over, let under):
            return atom(extensibleArrowBox(arrow, over: over, under: under, context), .rel)
        case .font, .style, .color:
            var atoms: [Atom] = []
            collectAtoms([node], context, into: &atoms)
            if atoms.count == 1 { return atoms[0] }
            return atom(pack(atoms))
        case .space(let mu):
            var box = AgentMathBox()
            box.width = CGFloat(mu) * size(of: context.style) / 18
            return atom(box, nil)
        case .array(let array):
            return atom(arrayBox(array, context))
        case .negated(let base):
            return atom(negatedBox(base, context))
        case .cancel(let base, let kind):
            return atom(cancelBox(base, kind: kind, context))
        case .boxed(let base):
            return atom(framedBox(base, context))
        case .phantom(let base, let keepsWidth, let keepsHeight):
            let inner = layoutList(Self.nodes(of: base), context)
            var box = AgentMathBox()
            box.width = keepsWidth ? inner.width : 0
            box.height = keepsHeight ? inner.height : 0
            box.depth = keepsHeight ? inner.depth : 0
            return atom(box)
        case .classed(let atomClass, let base):
            return atom(layoutList(Self.nodes(of: base), context), atomClass)
        case .tag:
            return atom(AgentMathBox(), nil)
        case .error(let source):
            hasErrors = true
            var errorContext = context
            errorContext.ink = .error
            return atom(textBox(source, variant: .normal, errorContext))
        }
    }

    // MARK: Glyphs and text

    /// Characters from the math font, mapped to the context's alphabet, with
    /// per-character font fallback for anything the math font lacks.
    func glyphBox(_ text: String, _ context: AgentMathLayoutContext, mapsAlphabet: Bool = true) -> AgentMathBox {
        let size = size(of: context.style)
        let mathFont = font.font(size: size)
        var box = AgentMathBox()
        var runFont = mathFont
        var runGlyphs: [CGGlyph] = []
        var runPositions: [CGPoint] = []
        var lastGlyph: CGGlyph = 0
        var lastFont = mathFont
        var count = 0
        var lastBounds = CGRect.zero
        func flush() {
            guard !runGlyphs.isEmpty else { return }
            box.items.append(.glyphs(runFont, runGlyphs, runPositions, context.ink))
            runGlyphs = []
            runPositions = []
        }
        for original in text.unicodeScalars {
            let scalar = mapsAlphabet ? AgentMathAlphabet.map(original, context.variant) : original
            let (glyphFont, glyph) = Self.glyph(for: scalar, in: mathFont)
            if glyphFont != runFont { flush() }
            runFont = glyphFont
            var advance = CGSize.zero
            var bounds = CGRect.zero
            var glyphs = [glyph]
            CTFontGetAdvancesForGlyphs(glyphFont, .horizontal, &glyphs, &advance, 1)
            CTFontGetBoundingRectsForGlyphs(glyphFont, .horizontal, &glyphs, &bounds, 1)
            runGlyphs.append(glyph)
            runPositions.append(CGPoint(x: box.width, y: 0))
            if !bounds.isNull, !bounds.isEmpty {
                box.height = max(box.height, bounds.maxY)
                box.depth = max(box.depth, -bounds.minY)
            }
            box.width += advance.width
            lastGlyph = glyph
            lastFont = glyphFont
            lastBounds = bounds.offsetBy(dx: box.width - advance.width, dy: 0)
            count += 1
        }
        flush()
        guard count == 1, lastFont == mathFont, font.isMathFont else { return box }
        box.isCharacter = true
        box.italicCorrection = font.italicCorrection(lastGlyph, size: size)
        box.accentAttachment = font.topAccentAttachment(lastGlyph, size: size) ?? (lastBounds.isNull ? nil : lastBounds.midX)
        return box
    }

    private static func glyph(for scalar: Unicode.Scalar, in font: CTFont) -> (CTFont, CGGlyph) {
        var units = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        if CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count), glyphs[0] != 0 {
            return (font, glyphs[0])
        }
        let string = String(Character(scalar)) as CFString
        let fallback = CTFontCreateForString(font, string, CFRange(location: 0, length: units.count))
        if CTFontGetGlyphsForCharacters(fallback, &units, &glyphs, units.count), glyphs[0] != 0 {
            return (fallback, glyphs[0])
        }
        return (font, 0)
    }

    /// A single glyph by id, as used for size variants and assembly parts.
    private func singleGlyphBox(_ glyph: CGGlyph, font ctFont: CTFont, ink: AgentMathInk) -> (box: AgentMathBox, bounds: CGRect) {
        var glyphs = [glyph]
        var advance = CGSize.zero
        var bounds = CGRect.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyphs, &advance, 1)
        CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &glyphs, &bounds, 1)
        var box = AgentMathBox()
        box.width = advance.width
        if !bounds.isNull {
            box.height = max(bounds.maxY, 0)
            box.depth = max(-bounds.minY, 0)
        }
        box.items = [.glyphs(ctFont, glyphs, [.zero], ink)]
        return (box, bounds)
    }

    func textBox(_ text: String, variant: AgentMathTextVariant, _ context: AgentMathLayoutContext) -> AgentMathBox {
        let size = size(of: context.style)
        let textFont = Self.textFont(name: textFontName, size: size, variant: variant)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: textFont,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        let line = CTLineCreateWithAttributedString(string ?? CFAttributedStringCreate(nil, "" as CFString, nil))
        var box = AgentMathBox()
        box.width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        if !ink.isNull, !ink.isEmpty {
            box.height = max(ink.maxY, 0)
            box.depth = max(-ink.minY, 0)
        }
        box.items = [.line(line, .zero, context.ink)]
        return box
    }

    private static func textFont(name: String?, size: CGFloat, variant: AgentMathTextVariant) -> CTFont {
        let base: CTFont
        if let name {
            base = CTFontCreateWithName(name as CFString, size, nil)
        } else {
            base = NSFont.systemFont(ofSize: size) as CTFont
        }
        switch variant {
        case .normal, .sansSerif:
            return base
        case .bold:
            return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
        case .italic:
            return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitItalic, .traitItalic) ?? base
        case .monospace:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        }
    }

    // MARK: Operators and scripts

    private func operatorBox(_ op: AgentMathOperator, _ context: AgentMathLayoutContext) -> AgentMathBox {
        guard op.isLargeSymbol else {
            var roman = context
            roman.variant = .roman
            var box = glyphBox(op.text, roman)
            box.isCharacter = false
            box.italicCorrection = 0
            return box
        }
        let size = size(of: context.style)
        let mathFont = font.font(size: size)
        guard let scalar = op.text.unicodeScalars.first else { return AgentMathBox() }
        var (glyphFont, glyph) = Self.glyph(for: scalar, in: mathFont)
        if context.style == .display, glyphFont == mathFont, let construction = font.verticalConstruction(glyph) {
            let minimum = font.displayOperatorMinHeight
            glyph = construction.variants.first { $0.advance >= minimum }?.glyph
                ?? construction.variants.last?.glyph ?? glyph
        } else if context.style == .display, !font.isMathFont {
            glyphFont = font.font(size: size * 1.4)
        }
        let (glyphBox, _) = singleGlyphBox(glyph, font: glyphFont, ink: context.ink)
        var box = centeredOnAxis(glyphBox, context)
        box.italicCorrection = glyphFont == mathFont ? font.italicCorrection(glyph, size: size) : 0
        return box
    }

    private func centeredOnAxis(_ inner: AgentMathBox, _ context: AgentMathLayoutContext) -> AgentMathBox {
        let axis = value(.axisHeight, context)
        let shift = (inner.height - inner.depth) / 2 - axis
        var box = AgentMathBox()
        box.place(inner, x: 0, y: -shift)
        box.width = inner.width
        box.height = inner.height - shift
        box.depth = inner.depth + shift
        return box
    }

    private func scriptsAtom(base: AgentMathNode, sub: AgentMathNode?, sup: AgentMathNode?, _ context: AgentMathLayoutContext) -> Atom {
        func atom(_ box: AgentMathBox, _ atomClass: AgentMathAtomClass) -> Atom {
            Atom(box: box, atomClass: atomClass, style: context.style)
        }
        switch base {
        case .largeOperator(let op):
            let box = operatorBox(op, context)
            let usesLimits = op.limits == .limits
                || (op.limits == .automatic && op.takesLimitsInDisplay && context.style == .display)
            if usesLimits { return atom(limitsBox(box, sub: sub, sup: sup, context), .op) }
            return atom(attachScripts(to: box, sub: sub, sup: sup, isLargeOperator: op.isLargeSymbol, context), .op)
        case .horizontalBrace:
            let box = layoutAtom(base, context).box
            return atom(limitsBox(box, sub: sub, sup: sup, context), .ord)
        case .classed(.op, let inner) where context.style == .display:
            let box = layoutList(Self.nodes(of: inner), context)
            return atom(limitsBox(box, sub: sub, sup: sup, context), .op)
        default:
            let baseAtom = layoutAtom(base, context)
            let box = attachScripts(to: baseAtom.box, sub: sub, sup: sup, isLargeOperator: false, context)
            return atom(box, baseAtom.atomClass ?? .ord)
        }
    }

    private func attachScripts(
        to base: AgentMathBox,
        sub: AgentMathNode?,
        sup: AgentMathNode?,
        isLargeOperator: Bool,
        _ context: AgentMathLayoutContext
    ) -> AgentMathBox {
        let supContext = context.superscript
        let subContext = context.subscript
        let supBox = sup.map { layoutList(Self.nodes(of: $0), supContext) }
        let subBox = sub.map { layoutList(Self.nodes(of: $0), subContext) }
        var supShift: CGFloat = 0
        var subShift: CGFloat = 0
        if !base.isCharacter {
            supShift = base.height - font.value(.superscriptBaselineDropMax, size: size(of: supContext.style))
            subShift = base.depth + font.value(.subscriptBaselineDropMin, size: size(of: subContext.style))
        }
        let minimumSupShift = value(context.cramped ? .superscriptShiftUpCramped : .superscriptShiftUp, context)
        if let supBox {
            supShift = max(supShift, minimumSupShift, supBox.depth + value(.superscriptBottomMin, context))
        }
        if let subBox {
            if supBox == nil {
                subShift = max(subShift, value(.subscriptShiftDown, context), subBox.height - value(.subscriptTopMax, context))
            } else {
                subShift = max(subShift, value(.subscriptShiftDown, context))
            }
        }
        if let supBox, let subBox {
            let gap = (supShift - supBox.depth) - (subBox.height - subShift)
            let minimumGap = value(.subSuperscriptGapMin, context)
            if gap < minimumGap {
                subShift += minimumGap - gap
                let lift = value(.superscriptBottomMaxWithSubscript, context) - (supShift - supBox.depth)
                if lift > 0 {
                    supShift += lift
                    subShift -= lift
                }
            }
        }
        var box = AgentMathBox()
        box.place(base, x: 0, y: 0)
        box.height = base.height
        box.depth = base.depth
        var width = base.width
        if let supBox {
            let x = base.width + (isLargeOperator ? 0 : base.italicCorrection)
            box.place(supBox, x: x, y: supShift)
            box.height = max(box.height, supShift + supBox.height)
            box.depth = max(box.depth, supBox.depth - supShift)
            width = max(width, x + supBox.width)
        }
        if let subBox {
            let x = base.width - (isLargeOperator ? base.italicCorrection : 0)
            box.place(subBox, x: x, y: -subShift)
            box.depth = max(box.depth, subShift + subBox.depth)
            box.height = max(box.height, subBox.height - subShift)
            width = max(width, x + subBox.width)
        }
        box.width = width + value(.spaceAfterScript, context)
        return box
    }

    /// Scripts stacked above and below `base`, as for display-style `\sum` or `\lim`.
    private func limitsBox(_ base: AgentMathBox, sub: AgentMathNode?, sup: AgentMathNode?, _ context: AgentMathLayoutContext) -> AgentMathBox {
        let supBox = sup.map { layoutList(Self.nodes(of: $0), context.superscript) }
        let subBox = sub.map { layoutList(Self.nodes(of: $0), context.subscript) }
        let width = max(base.width, supBox?.width ?? 0, subBox?.width ?? 0)
        let extra = 0.1 * size(of: context.style)
        var box = AgentMathBox()
        box.width = width
        box.place(base, x: (width - base.width) / 2, y: 0)
        box.height = base.height
        box.depth = base.depth
        if let supBox {
            let rise = max(value(.upperLimitGapMin, context) + supBox.depth, value(.upperLimitBaselineRiseMin, context))
            let y = base.height + rise
            box.place(supBox, x: (width - supBox.width) / 2, y: y)
            box.height = y + supBox.height + extra
        }
        if let subBox {
            let drop = max(value(.lowerLimitGapMin, context) + subBox.height, value(.lowerLimitBaselineDropMin, context))
            let y = base.depth + drop
            box.place(subBox, x: (width - subBox.width) / 2, y: -y)
            box.depth = y + subBox.depth + extra
        }
        return box
    }

    // MARK: Fractions and radicals

    private func fractionBox(
        _ numerator: AgentMathNode,
        _ denominator: AgentMathNode,
        hasRule: Bool,
        style: AgentMathStyle?,
        _ outer: AgentMathLayoutContext
    ) -> AgentMathBox {
        var context = outer
        if let style {
            context.style = style
            context.cramped = false
        }
        let isDisplay = context.style == .display
        let numeratorBox = layoutList(Self.nodes(of: numerator), context.numerator)
        let denominatorBox = layoutList(Self.nodes(of: denominator), context.denominator)
        let axis = value(.axisHeight, context)
        var numeratorShift: CGFloat
        var denominatorShift: CGFloat
        var thickness: CGFloat = 0
        if hasRule {
            thickness = value(.fractionRuleThickness, context)
            numeratorShift = value(isDisplay ? .fractionNumeratorDisplayStyleShiftUp : .fractionNumeratorShiftUp, context)
            denominatorShift = value(isDisplay ? .fractionDenominatorDisplayStyleShiftDown : .fractionDenominatorShiftDown, context)
            let numeratorGap = value(isDisplay ? .fractionNumDisplayStyleGapMin : .fractionNumeratorGapMin, context)
            let denominatorGap = value(isDisplay ? .fractionDenomDisplayStyleGapMin : .fractionDenominatorGapMin, context)
            numeratorShift = max(numeratorShift, axis + thickness / 2 + numeratorGap + numeratorBox.depth)
            denominatorShift = max(denominatorShift, denominatorBox.height + denominatorGap - axis + thickness / 2)
        } else {
            numeratorShift = value(isDisplay ? .stackTopDisplayStyleShiftUp : .stackTopShiftUp, context)
            denominatorShift = value(isDisplay ? .stackBottomDisplayStyleShiftDown : .stackBottomShiftDown, context)
            let minimumGap = value(isDisplay ? .stackDisplayStyleGapMin : .stackGapMin, context)
            let gap = (numeratorShift - numeratorBox.depth) - (denominatorBox.height - denominatorShift)
            if gap < minimumGap {
                numeratorShift += (minimumGap - gap) / 2
                denominatorShift += (minimumGap - gap) / 2
            }
        }
        let padding = 0.12 * size(of: context.style)
        let innerWidth = max(numeratorBox.width, denominatorBox.width)
        var box = AgentMathBox()
        box.width = innerWidth + 2 * padding
        box.place(numeratorBox, x: padding + (innerWidth - numeratorBox.width) / 2, y: numeratorShift)
        box.place(denominatorBox, x: padding + (innerWidth - denominatorBox.width) / 2, y: -denominatorShift)
        if hasRule {
            box.items.append(.rule(CGRect(x: padding, y: axis - thickness / 2, width: innerWidth, height: thickness), context.ink))
        }
        box.height = numeratorShift + numeratorBox.height
        box.depth = denominatorShift + denominatorBox.depth
        return box
    }

    private func radicalBox(_ radicand: AgentMathNode, index: AgentMathNode?, _ context: AgentMathLayoutContext) -> AgentMathBox {
        let body = layoutList(Self.nodes(of: radicand), context.crampedVersion)
        let thickness = value(.radicalRuleThickness, context)
        var gap = value(context.style == .display ? .radicalDisplayStyleVerticalGap : .radicalVerticalGap, context)
        let target = body.height + body.depth + gap + thickness
        let surd = stretchedVerticalGlyph("√", minimumTotal: target, context)
        let surdTotal = surd.height + surd.depth
        if surdTotal > target { gap += (surdTotal - target) / 2 }
        let ruleBottom = body.height + gap
        let surdShift = ruleBottom + thickness - surd.height
        var box = AgentMathBox()
        var x: CGFloat = 0
        box.height = ruleBottom + thickness + value(.radicalExtraAscender, context)
        if let index {
            var indexContext = context
            indexContext.style = .scriptScript
            indexContext.cramped = false
            let indexBox = layoutList(Self.nodes(of: index), indexContext)
            let before = value(.radicalKernBeforeDegree, context)
            let after = value(.radicalKernAfterDegree, context)
            let raise = font.radicalDegreeBottomRaisePercent / 100 * surdTotal
            let indexY = surdShift - surd.depth + raise + indexBox.depth
            box.place(indexBox, x: before, y: indexY)
            box.height = max(box.height, indexY + indexBox.height)
            x = max(before + indexBox.width + after, 0)
        }
        box.place(surd, x: x, y: surdShift)
        let ruleX = x + surd.width
        box.items.append(.rule(CGRect(x: ruleX, y: ruleBottom, width: body.width, height: thickness), context.ink))
        box.place(body, x: ruleX, y: 0)
        box.width = ruleX + body.width
        box.depth = max(body.depth, surd.depth - surdShift)
        return box
    }

    // MARK: Delimiters and stretchy glyphs

    private static let delimiterAlternates: [String: String] = ["|": "∣", "‖": "∥"]

    /// A glyph at least `minimumTotal` tall (height + depth), from size variants or an assembly.
    private func stretchedVerticalGlyph(
        _ character: String,
        minimumTotal: CGFloat,
        _ context: AgentMathLayoutContext,
        sized: Bool = false
    ) -> AgentMathBox {
        let size = size(of: context.style)
        let mathFont = font.font(size: size)
        guard let scalar = character.unicodeScalars.first else { return AgentMathBox() }
        let (glyphFont, baseGlyph) = Self.glyph(for: scalar, in: mathFont)
        var construction = glyphFont == mathFont ? font.verticalConstruction(baseGlyph) : nil
        if construction == nil, let alternate = Self.delimiterAlternates[character]?.unicodeScalars.first {
            let (alternateFont, alternateGlyph) = Self.glyph(for: alternate, in: mathFont)
            if alternateFont == mathFont, let found = font.verticalConstruction(alternateGlyph) {
                construction = found
            }
        }
        guard let construction else {
            let base = singleGlyphBox(baseGlyph, font: glyphFont, ink: context.ink).box
            let total = base.height + base.depth
            guard total > 0, total < minimumTotal else { return base }
            let scaled = CTFontCreateCopyWithAttributes(glyphFont, CTFontGetSize(glyphFont) * minimumTotal / total, nil, nil)
            return singleGlyphBox(baseGlyph, font: scaled, ink: context.ink).box
        }
        let scale = size / font.unitsPerEm
        let baseAdvance = construction.variants.first.map { $0.advance * scale } ?? 0
        for variant in construction.variants {
            let advance = variant.advance * scale
            if sized, advance <= baseAdvance, construction.variants.count > 1, minimumTotal > baseAdvance { continue }
            if advance >= minimumTotal * (sized ? 0.9 : 1) {
                return singleGlyphBox(variant.glyph, font: mathFont, ink: context.ink).box
            }
        }
        if !construction.parts.isEmpty {
            return assembly(construction.parts, length: minimumTotal, vertical: true, font: mathFont, ink: context.ink)
        }
        let last = construction.variants.last?.glyph ?? baseGlyph
        return singleGlyphBox(last, font: mathFont, ink: context.ink).box
    }

    /// A glyph at least `minimumWidth` wide, and the x its accent attachment sits at.
    private func stretchedHorizontalGlyph(
        _ character: String,
        minimumWidth: CGFloat,
        _ context: AgentMathLayoutContext
    ) -> (box: AgentMathBox, attachment: CGFloat) {
        let size = size(of: context.style)
        let mathFont = font.font(size: size)
        guard let scalar = character.unicodeScalars.first else { return (AgentMathBox(), 0) }
        let (glyphFont, baseGlyph) = Self.glyph(for: scalar, in: mathFont)
        let construction = glyphFont == mathFont ? font.horizontalConstruction(baseGlyph) : nil
        if let construction {
            let scale = size / font.unitsPerEm
            for variant in construction.variants where variant.advance * scale >= minimumWidth {
                let (box, bounds) = singleGlyphBox(variant.glyph, font: mathFont, ink: context.ink)
                let attachment = font.topAccentAttachment(variant.glyph, size: size) ?? bounds.midX
                return (box, attachment)
            }
            if !construction.parts.isEmpty {
                let box = assembly(construction.parts, length: minimumWidth, vertical: false, font: mathFont, ink: context.ink)
                return (box, box.width / 2)
            }
        }
        let (base, bounds) = singleGlyphBox(construction?.variants.last?.glyph ?? baseGlyph, font: glyphFont, ink: context.ink)
        guard !bounds.isNull, bounds.width > 0, bounds.width < minimumWidth else {
            return (base, font.topAccentAttachment(baseGlyph, size: size) ?? bounds.midX)
        }
        let factor = minimumWidth / bounds.width
        var matrix = CGAffineTransform(scaleX: factor, y: 1)
        let stretched = CTFontCreateCopyWithAttributes(glyphFont, CTFontGetSize(glyphFont), &matrix, nil)
        let glyph = construction?.variants.last?.glyph ?? baseGlyph
        let (box, stretchedBounds) = singleGlyphBox(glyph, font: stretched, ink: context.ink)
        var shifted = AgentMathBox()
        shifted.place(box, x: -stretchedBounds.minX, y: 0)
        shifted.width = stretchedBounds.width
        shifted.height = box.height
        shifted.depth = box.depth
        return (shifted, stretchedBounds.width / 2)
    }

    /// Builds a glyph from its parts, repeating extenders until it reaches `length`.
    private func assembly(
        _ parts: [AgentMathGlyphConstruction.Part],
        length: CGFloat,
        vertical: Bool,
        font ctFont: CTFont,
        ink: AgentMathInk
    ) -> AgentMathBox {
        let scale = CTFontGetSize(ctFont) / font.unitsPerEm
        let minimumOverlap = font.minConnectorOverlap * scale
        let hasExtenders = parts.contains { $0.isExtender }
        var sequence: [AgentMathGlyphConstruction.Part] = []
        var overlap = minimumOverlap
        for repeats in 1...64 {
            sequence = parts.flatMap { part in
                part.isExtender ? Array(repeating: part, count: repeats) : [part]
            }
            let full = sequence.reduce(0) { $0 + $1.fullAdvance * scale }
            let joints = CGFloat(max(sequence.count - 1, 1))
            let longest = full - CGFloat(sequence.count - 1) * minimumOverlap
            guard longest >= length || !hasExtenders || repeats == 64 else { continue }
            if sequence.count > 1 {
                let allowed = zip(sequence, sequence.dropFirst())
                    .map { min($0.endConnector, $1.startConnector) * scale }
                    .min() ?? minimumOverlap
                overlap = min(max((full - length) / joints, minimumOverlap), max(allowed, minimumOverlap))
            }
            break
        }
        var box = AgentMathBox()
        var glyphs: [CGGlyph] = []
        var positions: [CGPoint] = []
        var offset: CGFloat = 0
        var thickness: CGFloat = 0
        for part in sequence {
            var glyph = [part.glyph]
            var bounds = CGRect.zero
            var advance = CGSize.zero
            CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &glyph, &bounds, 1)
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
            glyphs.append(part.glyph)
            if vertical {
                positions.append(CGPoint(x: 0, y: offset - (bounds.isNull ? 0 : bounds.minY)))
                thickness = max(thickness, advance.width)
            } else {
                positions.append(CGPoint(x: offset, y: 0))
                if !bounds.isNull {
                    box.height = max(box.height, bounds.maxY)
                    box.depth = max(box.depth, -bounds.minY)
                }
            }
            offset += part.fullAdvance * scale - overlap
        }
        let total = offset + overlap
        box.items = [.glyphs(ctFont, glyphs, positions, ink)]
        if vertical {
            box.width = thickness
            box.height = total
            box.depth = 0
        } else {
            box.width = total
        }
        return box
    }

    /// A delimiter centered on the math axis, at least `total` tall; "" is the null delimiter.
    private func delimiterBox(_ delimiter: String, total: CGFloat, _ context: AgentMathLayoutContext, sized: Bool = false) -> AgentMathBox {
        guard !delimiter.isEmpty else {
            var box = AgentMathBox()
            box.width = 0.12 * size(of: context.style)
            return box
        }
        let glyph = stretchedVerticalGlyph(delimiter, minimumTotal: total, context, sized: sized)
        return centeredOnAxis(glyph, context)
    }

    private func leftRightBox(left: String, body: [AgentMathNode], right: String, _ context: AgentMathLayoutContext) -> AgentMathBox {
        var atoms: [Atom] = []
        collectAtoms(body, context, into: &atoms)
        let inner = pack(atoms.filter { $0.middleDelimiter == nil })
        let axis = value(.axisHeight, context)
        let delta = max(inner.height - axis, inner.depth + axis)
        let total = max(2 * delta * 0.901, 2 * delta - 0.5 * size(of: context.style))
        for index in atoms.indices {
            guard let middle = atoms[index].middleDelimiter else { continue }
            atoms[index].box = delimiterBox(middle, total: total, context)
            atoms[index].middleDelimiter = nil
        }
        let style = context.style
        let all = [Atom(box: delimiterBox(left, total: total, context), atomClass: .open, style: style)]
            + atoms
            + [Atom(box: delimiterBox(right, total: total, context), atomClass: .close, style: style)]
        var box = pack(all)
        box.italicCorrection = 0
        return box
    }

    // MARK: Accents, bars and braces

    private func accentBox(_ base: AgentMathNode, accent: String, isStretchy: Bool, _ context: AgentMathLayoutContext) -> AgentMathBox {
        let baseBox = layoutList(Self.nodes(of: base), context.crampedVersion)
        let isCombining = accent.unicodeScalars.first?.properties.generalCategory == .nonspacingMark
        let accentBox: AgentMathBox
        let accentAttachment: CGFloat
        if isStretchy {
            (accentBox, accentAttachment) = stretchedHorizontalGlyph(accent, minimumWidth: baseBox.width, context)
        } else {
            let size = size(of: context.style)
            let mathFont = font.font(size: size)
            let scalar = accent.unicodeScalars.first ?? " "
            let (glyphFont, glyph) = Self.glyph(for: scalar, in: mathFont)
            let (box, bounds) = singleGlyphBox(glyph, font: glyphFont, ink: context.ink)
            accentBox = box
            accentAttachment = (glyphFont == mathFont ? font.topAccentAttachment(glyph, size: size) : nil)
                ?? (bounds.isNull ? 0 : bounds.midX)
        }
        let baseAttachment = baseBox.accentAttachment ?? baseBox.width / 2
        let y: CGFloat
        if isCombining {
            y = max(0, baseBox.height - value(.accentBaseHeight, context))
        } else {
            y = baseBox.height + 0.08 * size(of: context.style) + accentBox.depth
        }
        var box = AgentMathBox()
        box.place(baseBox, x: 0, y: 0)
        box.place(accentBox, x: baseAttachment - accentAttachment, y: y)
        box.width = baseBox.width
        box.height = max(baseBox.height, y + accentBox.height)
        box.depth = baseBox.depth
        box.italicCorrection = baseBox.italicCorrection
        return box
    }

    private func overlineBox(_ base: AgentMathNode, _ context: AgentMathLayoutContext) -> AgentMathBox {
        let baseBox = layoutList(Self.nodes(of: base), context.crampedVersion)
        let thickness = value(.overbarRuleThickness, context)
        let gap = value(.overbarVerticalGap, context)
        var box = AgentMathBox()
        box.place(baseBox, x: 0, y: 0)
        box.items.append(.rule(CGRect(x: 0, y: baseBox.height + gap, width: baseBox.width, height: thickness), context.ink))
        box.width = baseBox.width
        box.height = baseBox.height + gap + thickness + value(.overbarExtraAscender, context)
        box.depth = baseBox.depth
        return box
    }

    private func underlineBox(_ base: AgentMathNode, _ context: AgentMathLayoutContext) -> AgentMathBox {
        let baseBox = layoutList(Self.nodes(of: base), context)
        let thickness = value(.underbarRuleThickness, context)
        let gap = value(.underbarVerticalGap, context)
        var box = AgentMathBox()
        box.place(baseBox, x: 0, y: 0)
        let y = -(baseBox.depth + gap + thickness)
        box.items.append(.rule(CGRect(x: 0, y: y, width: baseBox.width, height: thickness), context.ink))
        box.width = baseBox.width
        box.height = baseBox.height
        box.depth = -y + value(.underbarExtraDescender, context)
        return box
    }

    private func braceBox(_ base: AgentMathNode, isOver: Bool, _ context: AgentMathLayoutContext) -> AgentMathBox {
        let baseBox = layoutList(Self.nodes(of: base), context)
        let (brace, _) = stretchedHorizontalGlyph(isOver ? "⏞" : "⏟", minimumWidth: baseBox.width, context)
        let gap = 0.1 * size(of: context.style)
        let width = max(baseBox.width, brace.width)
        var box = AgentMathBox()
        box.width = width
        box.place(baseBox, x: (width - baseBox.width) / 2, y: 0)
        box.height = baseBox.height
        box.depth = baseBox.depth
        if isOver {
            let y = baseBox.height + gap + brace.depth
            box.place(brace, x: (width - brace.width) / 2, y: y)
            box.height = y + brace.height
        } else {
            let y = -(baseBox.depth + gap + brace.height)
            box.place(brace, x: (width - brace.width) / 2, y: y)
            box.depth = -y + brace.depth
        }
        return box
    }

    private func extensibleArrowBox(_ arrow: String, over: AgentMathNode?, under: AgentMathNode?, _ context: AgentMathLayoutContext) -> AgentMathBox {
        let size = size(of: context.style)
        let overWidth = over.map { layoutList(Self.nodes(of: $0), context.superscript).width } ?? 0
        let underWidth = under.map { layoutList(Self.nodes(of: $0), context.subscript).width } ?? 0
        let target = max(max(overWidth, underWidth) + 0.8 * size, 1.5 * size)
        let (arrowBox, _) = stretchedHorizontalGlyph(arrow, minimumWidth: target, context)
        return limitsBox(arrowBox, sub: under, sup: over, context)
    }

    // MARK: Arrays

    private func arrayBox(_ array: AgentMathArray, _ context: AgentMathLayoutContext) -> AgentMathBox {
        let size = size(of: context.style)
        var cellContext = context
        cellContext.cramped = false
        switch array.kind {
        case .matrix, .cases, .array:
            cellContext.style = context.style == .display ? .text : context.style
        case .smallMatrix:
            cellContext.style = context.style == .scriptScript ? .scriptScript : .script
        case .aligned, .gather:
            cellContext.style = .display
        }
        let columnCount = max(array.rows.map(\.count).max() ?? 0, array.columns.count)
        guard columnCount > 0 else { return AgentMathBox() }
        let cells: [[AgentMathBox]] = array.rows.map { row in
            row.enumerated().map { column, cell in
                var nodes = Self.nodes(of: cell)
                if array.kind == .aligned, column % 2 == 1 { nodes.insert(.group([]), at: 0) }
                return layoutList(nodes, cellContext)
            }
        }
        var widths = [CGFloat](repeating: 0, count: columnCount)
        for row in cells {
            for (column, cell) in row.enumerated() { widths[column] = max(widths[column], cell.width) }
        }
        func alignment(_ column: Int) -> AgentMathColumnAlignment {
            switch array.kind {
            case .array: return column < array.columns.count ? array.columns[column] : .center
            case .matrix, .smallMatrix, .gather: return .center
            case .cases: return .left
            case .aligned: return column % 2 == 0 ? .right : .left
            }
        }
        func gap(after column: Int) -> CGFloat {
            switch array.kind {
            case .aligned: return column % 2 == 0 ? 0 : 2 * size
            case .smallMatrix: return 0.333 * size
            default: return size
            }
        }
        let edge: CGFloat = array.kind == .array ? 0.5 * size : 0
        var columnX: [CGFloat] = []
        var x = edge
        for column in 0..<columnCount {
            columnX.append(x)
            x += widths[column] + (column < columnCount - 1 ? gap(after: column) : 0)
        }
        let totalWidth = x + edge
        let stretch: CGFloat = array.kind == .cases ? 1.2 : array.kind == .smallMatrix ? 0.5 : 1
        let baselineSkip = 1.2 * size * stretch
        let jot: CGFloat = array.kind == .aligned || array.kind == .gather ? 0.3 * size : 0
        var rowBaselines: [CGFloat] = []
        var rowBottoms: [CGFloat] = []
        var y: CGFloat = 0
        for row in cells {
            let height = max(row.map(\.height).max() ?? 0, 0.7 * baselineSkip)
            let depth = max(row.map(\.depth).max() ?? 0, 0.3 * baselineSkip)
            if !rowBaselines.isEmpty { y -= jot }
            let baseline = y - height
            rowBaselines.append(baseline)
            y = baseline - depth
            rowBottoms.append(y)
        }
        let totalHeight = -y
        let axis = value(.axisHeight, context)
        let top = totalHeight / 2 + axis
        var box = AgentMathBox()
        box.width = totalWidth
        box.height = top
        box.depth = totalHeight - top
        for (rowIndex, row) in cells.enumerated() {
            for (column, cell) in row.enumerated() {
                let slack = widths[column] - cell.width
                let offset: CGFloat = switch alignment(column) {
                case .left: 0
                case .center: slack / 2
                case .right: slack
                }
                box.place(cell, x: columnX[column] + offset, y: top + rowBaselines[rowIndex])
            }
        }
        let rule = 0.04 * size
        for boundary in array.horizontalRules.sorted() where boundary <= cells.count {
            let ruleY = top + (boundary == 0 ? 0 : rowBottoms[boundary - 1]) - (boundary == 0 ? rule : 0)
            box.items.append(.rule(CGRect(x: 0, y: ruleY, width: totalWidth, height: rule), context.ink))
        }
        for boundary in array.verticalRules.sorted() where boundary <= columnCount {
            let ruleX: CGFloat
            if boundary == 0 {
                ruleX = 0
            } else if boundary == columnCount {
                ruleX = totalWidth - rule
            } else {
                ruleX = columnX[boundary] - gap(after: boundary - 1) / 2 - rule / 2
            }
            box.items.append(.rule(CGRect(x: ruleX, y: -box.depth, width: rule, height: totalHeight), context.ink))
        }
        return box
    }

    // MARK: Decorations

    private func negatedBox(_ base: AgentMathNode, _ context: AgentMathLayoutContext) -> AgentMathBox {
        let baseBox = layoutList(Self.nodes(of: base), context)
        let size = size(of: context.style)
        let center = baseBox.width / 2
        let half = max(baseBox.width * 0.3, 0.15 * size)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center - half, y: -baseBox.depth - 0.05 * size))
        path.addLine(to: CGPoint(x: center + half, y: baseBox.height + 0.05 * size))
        var box = baseBox
        box.items.append(.stroke(path, lineWidth: 0.05 * size, context.ink))
        box.isCharacter = false
        return box
    }

    private func cancelBox(_ base: AgentMathNode, kind: AgentMathCancelKind, _ context: AgentMathLayoutContext) -> AgentMathBox {
        let baseBox = layoutList(Self.nodes(of: base), context)
        let size = size(of: context.style)
        let path = CGMutablePath()
        let bottom = -baseBox.depth, top = baseBox.height
        switch kind {
        case .forward:
            path.move(to: CGPoint(x: 0, y: bottom))
            path.addLine(to: CGPoint(x: baseBox.width, y: top))
        case .backward:
            path.move(to: CGPoint(x: 0, y: top))
            path.addLine(to: CGPoint(x: baseBox.width, y: bottom))
        case .cross:
            path.move(to: CGPoint(x: 0, y: bottom))
            path.addLine(to: CGPoint(x: baseBox.width, y: top))
            path.move(to: CGPoint(x: 0, y: top))
            path.addLine(to: CGPoint(x: baseBox.width, y: bottom))
        case .strikeout:
            let axis = value(.axisHeight, context)
            path.move(to: CGPoint(x: 0, y: axis))
            path.addLine(to: CGPoint(x: baseBox.width, y: axis))
        }
        var box = baseBox
        box.items.append(.stroke(path, lineWidth: 0.05 * size, context.ink))
        box.isCharacter = false
        return box
    }

    private func framedBox(_ base: AgentMathNode, _ context: AgentMathLayoutContext) -> AgentMathBox {
        let baseBox = layoutList(Self.nodes(of: base), context)
        let size = size(of: context.style)
        let padding = 0.3 * size
        let rule = 0.04 * size
        var box = AgentMathBox()
        box.width = baseBox.width + 2 * padding
        box.height = baseBox.height + padding
        box.depth = baseBox.depth + padding
        box.place(baseBox, x: padding, y: 0)
        let frame = CGRect(x: 0, y: -box.depth, width: box.width, height: box.height + box.depth)
            .insetBy(dx: rule / 2, dy: rule / 2)
        box.items.append(.stroke(CGPath(rect: frame, transform: nil), lineWidth: rule, context.ink))
        return box
    }
}

/// Maps letters and digits into the Unicode Mathematical Alphanumeric Symbols block.
enum AgentMathAlphabet {
    private static let italicExceptions: [UInt32: UInt32] = [0x1D455: 0x210E]
    private static let scriptExceptions: [UInt32: UInt32] = [
        0x1D49D: 0x212C, 0x1D4A0: 0x2130, 0x1D4A1: 0x2131, 0x1D4A3: 0x210B, 0x1D4A4: 0x2110,
        0x1D4A7: 0x2112, 0x1D4A8: 0x2133, 0x1D4AD: 0x211B, 0x1D4BA: 0x212F, 0x1D4BC: 0x210A,
        0x1D4C4: 0x2134,
    ]
    private static let frakturExceptions: [UInt32: UInt32] = [
        0x1D506: 0x212D, 0x1D50B: 0x210C, 0x1D50C: 0x2111, 0x1D515: 0x211C, 0x1D51D: 0x2128,
    ]
    private static let doubleStruckExceptions: [UInt32: UInt32] = [
        0x1D53A: 0x2102, 0x1D53F: 0x210D, 0x1D545: 0x2115, 0x1D547: 0x2119, 0x1D548: 0x211A,
        0x1D549: 0x211D, 0x1D551: 0x2124,
    ]
    /// Greek symbols after the 25 lowercase letters, in block order (offset 51 onwards is ∂).
    private static let greekSymbolIndex: [UInt32: UInt32] = [
        0x2202: 51, 0x03F5: 52, 0x03D1: 53, 0x03F0: 54, 0x03D5: 55, 0x03F1: 56, 0x03D6: 57,
    ]

    static func map(_ scalar: Unicode.Scalar, _ variant: AgentMathFontVariant) -> Unicode.Scalar {
        let value = scalar.value
        let isUpper = (0x41...0x5A).contains(value)
        let isLower = (0x61...0x7A).contains(value)
        let isDigit = (0x30...0x39).contains(value)
        let greekIndex = greekIndex(of: value)
        let isLowerGreek = greekIndex.map { $0 >= 26 } ?? false
        func latin(_ base: UInt32, _ exceptions: [UInt32: UInt32] = [:]) -> Unicode.Scalar {
            let mapped = base + (isUpper ? value - 0x41 : 26 + value - 0x61)
            return Unicode.Scalar(exceptions[mapped] ?? mapped) ?? scalar
        }
        func greek(_ base: UInt32) -> Unicode.Scalar {
            guard let greekIndex else { return scalar }
            return Unicode.Scalar(base + greekIndex) ?? scalar
        }
        func digit(_ base: UInt32) -> Unicode.Scalar {
            Unicode.Scalar(base + value - 0x30) ?? scalar
        }
        switch variant {
        case .normal:
            if isUpper || isLower { return latin(0x1D434, italicExceptions) }
            if isLowerGreek, value != 0x2202 { return greek(0x1D6E2) }
            if value == 0x131 { return Unicode.Scalar(0x1D6A4) ?? scalar }
            if value == 0x237 { return Unicode.Scalar(0x1D6A5) ?? scalar }
            return scalar
        case .roman:
            return scalar
        case .italic:
            if isUpper || isLower { return latin(0x1D434, italicExceptions) }
            return greekIndex == nil ? scalar : greek(0x1D6E2)
        case .bold:
            if isUpper || isLower { return latin(0x1D400) }
            if isDigit { return digit(0x1D7CE) }
            return greekIndex == nil ? scalar : greek(0x1D6A8)
        case .boldItalic:
            if isUpper || isLower { return latin(0x1D468) }
            if isDigit { return digit(0x1D7CE) }
            return greekIndex == nil ? scalar : greek(0x1D71C)
        case .doubleStruck:
            if isUpper || isLower { return latin(0x1D538, doubleStruckExceptions) }
            return isDigit ? digit(0x1D7D8) : scalar
        case .script:
            return isUpper || isLower ? latin(0x1D49C, scriptExceptions) : scalar
        case .fraktur:
            return isUpper || isLower ? latin(0x1D504, frakturExceptions) : scalar
        case .sansSerif:
            if isUpper || isLower { return latin(0x1D5A0) }
            return isDigit ? digit(0x1D7E2) : scalar
        case .monospace:
            if isUpper || isLower { return latin(0x1D670) }
            return isDigit ? digit(0x1D7F6) : scalar
        }
    }

    /// The offset of a Greek letter inside a Mathematical Alphanumeric Greek alphabet.
    private static func greekIndex(of value: UInt32) -> UInt32? {
        if (0x391...0x3A9).contains(value), value != 0x3A2 { return value - 0x391 }
        if value == 0x2207 { return 25 }
        if (0x3B1...0x3C9).contains(value) { return 26 + value - 0x3B1 }
        return greekSymbolIndex[value]
    }
}
