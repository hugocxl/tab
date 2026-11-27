import XCTest
import AppKit
import CoreText
@testable import TabApp

final class AgentMathTypesetterTests: XCTestCase {
    private func parse(_ latex: String) -> [AgentMathNode] {
        AgentMathParser.parse(latex).nodes
    }

    private func options(display: Bool = false, size: CGFloat = 20, color: NSColor = .black) -> AgentMathTypesetter.Options {
        AgentMathTypesetter.Options(displayMode: display, fontSize: size, color: color, errorColor: .systemRed)
    }

    // MARK: Parser: atoms

    func testParsesOrdinarySymbolsAndBinaryOperators() {
        XCTAssertEqual(parse("a+b-c"), [
            .symbol("a", .ord), .symbol("+", .bin), .symbol("b", .ord), .symbol("−", .bin), .symbol("c", .ord),
        ])
    }

    func testGroupsDigitsIntoNumbers() {
        XCTAssertEqual(parse("3.14x 2."), [.number("3.14"), .symbol("x", .ord), .number("2"), .symbol(".", .ord)])
    }

    func testRelationsPunctuationAndFences() {
        XCTAssertEqual(parse("(a,b)=c"), [
            .symbol("(", .open), .symbol("a", .ord), .symbol(",", .punct), .symbol("b", .ord),
            .symbol(")", .close), .symbol("=", .rel), .symbol("c", .ord),
        ])
    }

    func testGreekLettersAndNamedSymbols() {
        XCTAssertEqual(parse("\\alpha \\Omega \\leq \\cdot \\infty \\to"), [
            .symbol("α", .ord), .symbol("Ω", .ord), .symbol("≤", .rel), .symbol("⋅", .bin),
            .symbol("∞", .ord), .symbol("→", .rel),
        ])
    }

    func testUnicodeInputPassesThroughWithClasses() {
        XCTAssertEqual(parse("α ≤ β"), [.symbol("α", .ord), .symbol("≤", .rel), .symbol("β", .ord)])
    }

    func testCommentsAreIgnored() {
        XCTAssertEqual(parse("a % comment\n+ b"), [.symbol("a", .ord), .symbol("+", .bin), .symbol("b", .ord)])
    }

    // MARK: Parser: scripts

    func testScriptsWithGroups() {
        XCTAssertEqual(parse("x^{2}_i"), [
            .scripts(base: .symbol("x", .ord), sub: .symbol("i", .ord), sup: .group([.number("2")])),
        ])
    }

    func testUngroupedScriptTakesOneToken() {
        XCTAssertEqual(parse("x^12"), [
            .scripts(base: .symbol("x", .ord), sub: nil, sup: .number("1")), .number("2"),
        ])
    }

    func testPrimesBecomeSuperscripts() {
        XCTAssertEqual(parse("f''^2"), [
            .scripts(base: .symbol("f", .ord), sub: nil, sup: .group([.symbol("′′", .ord), .number("2")])),
        ])
    }

    func testLargeOperatorsAndFunctionsCarryLimitBehavior() {
        guard case .scripts(.largeOperator(let sum), _, _) = parse("\\sum_{i=1}^n")[0],
              case .largeOperator(let integral) = parse("\\int")[0],
              case .largeOperator(let lim) = parse("\\lim")[0],
              case .largeOperator(let sin) = parse("\\sin")[0] else {
            return XCTFail("expected operators")
        }
        XCTAssertEqual(sum.text, "∑")
        XCTAssertTrue(sum.isLargeSymbol && sum.takesLimitsInDisplay)
        XCTAssertFalse(integral.takesLimitsInDisplay)
        XCTAssertTrue(lim.takesLimitsInDisplay)
        XCTAssertFalse(lim.isLargeSymbol)
        XCTAssertFalse(sin.takesLimitsInDisplay)
    }

    func testLimitsAndNoLimitsModifyTheOperator() {
        guard case .scripts(.largeOperator(let op), _, _) = parse("\\int\\limits_0^1")[0],
              case .scripts(.largeOperator(let sum), _, _) = parse("\\sum\\nolimits_i")[0] else {
            return XCTFail("expected scripted operators")
        }
        XCTAssertEqual(op.limits, .limits)
        XCTAssertEqual(sum.limits, .noLimits)
    }

    func testOperatorName() {
        XCTAssertEqual(parse("\\operatorname{rank}"), [.largeOperator(AgentMathOperator(
            text: "rank", isLargeSymbol: false, limits: .automatic, takesLimitsInDisplay: false
        ))])
        guard case .largeOperator(let op) = parse("\\operatorname*{argmax}")[0] else { return XCTFail() }
        XCTAssertTrue(op.takesLimitsInDisplay)
    }

    // MARK: Parser: structures

    func testFractionsAndForcedStyles() {
        XCTAssertEqual(parse("\\frac{a}{b}"), [.fraction(
            numerator: .group([.symbol("a", .ord)]), denominator: .group([.symbol("b", .ord)]), hasRule: true, style: nil
        )])
        XCTAssertEqual(parse("\\frac12"), [.fraction(numerator: .number("1"), denominator: .number("2"), hasRule: true, style: nil)])
        guard case .fraction(_, _, _, let display) = parse("\\dfrac ab")[0],
              case .fraction(_, _, _, let text) = parse("\\tfrac ab")[0] else { return XCTFail() }
        XCTAssertEqual(display, .display)
        XCTAssertEqual(text, .text)
    }

    func testBinomIsAParenthesizedRulelessFraction() {
        XCTAssertEqual(parse("\\binom nk"), [.leftRight(
            left: "(",
            body: [.fraction(numerator: .symbol("n", .ord), denominator: .symbol("k", .ord), hasRule: false, style: nil)],
            right: ")"
        )])
    }

    func testSquareRootWithOptionalIndex() {
        XCTAssertEqual(parse("\\sqrt{x}"), [.radical(radicand: .group([.symbol("x", .ord)]), index: nil)])
        XCTAssertEqual(parse("\\sqrt[3]{x}"), [.radical(radicand: .group([.symbol("x", .ord)]), index: .group([.number("3")]))])
    }

    func testLeftRightWithMiddleAndAllDelimiters() {
        XCTAssertEqual(parse("\\left\\langle a \\middle| b \\right\\rangle"), [.leftRight(
            left: "⟨", body: [.symbol("a", .ord), .middle("|"), .symbol("b", .ord)], right: "⟩"
        )])
        let pairs = ["(": ")", "[": "]", "\\{": "\\}", "|": "|", "\\|": "\\|", "\\lfloor": "\\rfloor", "\\lceil": "\\rceil", ".": "."]
        for (left, right) in pairs {
            let result = AgentMathParser.parse("\\left\(left) x \\right\(right)")
            XCTAssertTrue(result.errors.isEmpty, "\(left) \(right): \(result.errors)")
            guard case .leftRight = result.nodes.first else { return XCTFail("\(left)") }
        }
    }

    func testSizedDelimiters() {
        XCTAssertEqual(parse("\\big( \\Bigr] \\bigg| \\Biggl\\{"), [
            .sizedDelimiter("(", size: 1, .open), .sizedDelimiter("]", size: 2, .close),
            .sizedDelimiter("|", size: 3, .ord), .sizedDelimiter("{", size: 4, .open),
        ])
    }

    func testAccentsAndBars() {
        XCTAssertEqual(parse("\\hat x"), [.accent(base: .symbol("x", .ord), accent: "\u{0302}", isStretchy: false)])
        XCTAssertEqual(parse("\\widehat{ab}"), [.accent(
            base: .group([.symbol("a", .ord), .symbol("b", .ord)]), accent: "\u{0302}", isStretchy: true
        )])
        XCTAssertEqual(parse("\\overline{x}\\underline{y}"), [
            .overline(.group([.symbol("x", .ord)])), .underline(.group([.symbol("y", .ord)])),
        ])
    }

    func testOverUnderSetClasses() {
        XCTAssertEqual(parse("\\overset{!}{=}"), [.underOver(
            base: .group([.symbol("=", .rel)]), over: .group([.symbol("!", .close)]), under: nil, .rel
        )])
        guard case .underOver(_, _, _, let stackClass) = parse("\\stackrel{a}{b}")[0],
              case .underOver(_, nil, .some, let underClass) = parse("\\underset{x}{y}")[0] else { return XCTFail() }
        XCTAssertEqual(stackClass, .rel)
        XCTAssertEqual(underClass, .ord)
    }

    func testFontAndTextCommands() {
        XCTAssertEqual(parse("\\mathbb{R}\\mathbf x"), [.font(.doubleStruck, [.symbol("R", .ord)]), .font(.bold, [.symbol("x", .ord)])])
        XCTAssertEqual(parse("\\text{if  x > 0}"), [.text("if x > 0", .normal)])
        XCTAssertEqual(parse("\\textbf{a\\{b\\}}"), [.text("a{b}", .bold)])
        XCTAssertEqual(parse("\\mathcal{L}\\mathfrak{g}"), [.font(.script, [.symbol("L", .ord)]), .font(.fraktur, [.symbol("g", .ord)])])
    }

    func testSpacingCommands() {
        XCTAssertEqual(parse("a\\,b\\;c\\!d\\quad e~f\\ g"), [
            .symbol("a", .ord), .space(3), .symbol("b", .ord), .space(5), .symbol("c", .ord), .space(-3),
            .symbol("d", .ord), .space(18), .symbol("e", .ord), .space(6), .symbol("f", .ord), .space(6), .symbol("g", .ord),
        ])
        XCTAssertEqual(parse("\\hspace{1em}"), [.space(18)])
    }

    func testSwitchesApplyToTheRestOfTheGroup() {
        XCTAssertEqual(parse("{a \\displaystyle b} c"), [
            .group([.symbol("a", .ord), .style(.display, [.symbol("b", .ord)])]), .symbol("c", .ord),
        ])
        XCTAssertEqual(parse("\\color{red} x + \\textcolor{#00f}{y}"), [
            .color("red", [.symbol("x", .ord), .symbol("+", .bin), .color("#00f", [.symbol("y", .ord)])]),
        ])
    }

    func testNotPrefersPrecomposedNegations() {
        XCTAssertEqual(parse("\\not= \\not\\in"), [.symbol("≠", .rel), .symbol("∉", .rel)])
        XCTAssertEqual(parse("\\not\\alpha"), [.classed(.rel, .negated(.symbol("α", .ord)))])
    }

    func testDecorationsAndClassWrappers() {
        XCTAssertEqual(parse("\\cancel{x}\\boxed{y}\\phantom{z}\\hphantom{w}\\mathrel{R}"), [
            .cancel(.group([.symbol("x", .ord)]), .forward),
            .boxed(.group([.symbol("y", .ord)])),
            .phantom(.group([.symbol("z", .ord)]), keepsWidth: true, keepsHeight: true),
            .phantom(.group([.symbol("w", .ord)]), keepsWidth: true, keepsHeight: false),
            .classed(.rel, .group([.symbol("R", .ord)])),
        ])
    }

    func testTagAndEquationWrapper() {
        XCTAssertEqual(parse("\\begin{equation} E=mc^2 \\tag{1} \\end{equation}"), [.group([
            .symbol("E", .ord), .symbol("=", .rel), .symbol("m", .ord),
            .scripts(base: .symbol("c", .ord), sub: nil, sup: .number("2")), .tag("1"),
        ])])
    }

    // MARK: Parser: environments

    func testMatrixEnvironmentsWrapDelimiters() {
        let cell: (String) -> AgentMathNode = { .group([.number($0)]) }
        let array = AgentMathNode.array(AgentMathArray(kind: .matrix, rows: [[cell("1"), cell("2")], [cell("3"), cell("4")]]))
        XCTAssertEqual(parse("\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}"), [.leftRight(left: "(", body: [array], right: ")")])
        XCTAssertEqual(parse("\\begin{matrix} 1 & 2 \\\\ 3 & 4 \\\\ \\end{matrix}"), [array])
        let delimiters = ["bmatrix": ("[", "]"), "Bmatrix": ("{", "}"), "vmatrix": ("|", "|"), "Vmatrix": ("‖", "‖")]
        for (name, (left, right)) in delimiters {
            guard case .leftRight(let l, _, let r) = parse("\\begin{\(name)} a \\end{\(name)}")[0] else { return XCTFail(name) }
            XCTAssertEqual(l, left)
            XCTAssertEqual(r, right)
        }
    }

    func testCasesAndAligned() {
        guard case .leftRight("{", let body, "") = parse("\\begin{cases} 1 & x>0 \\\\ 0 & \\text{otherwise} \\end{cases}")[0],
              case .array(let cases) = body.first else { return XCTFail() }
        XCTAssertEqual(cases.kind, .cases)
        XCTAssertEqual(cases.rows.count, 2)
        XCTAssertEqual(cases.rows[1][1], .group([.text("otherwise", .normal)]))
        for name in ["aligned", "align", "align*"] {
            guard case .array(let aligned) = parse("\\begin{\(name)} a &= b \\\\ &= c \\end{\(name)}")[0] else { return XCTFail(name) }
            XCTAssertEqual(aligned.kind, .aligned)
            XCTAssertEqual(aligned.rows.map(\.count), [2, 2])
        }
        guard case .array(let gather) = parse("\\begin{gather} a \\\\ b \\end{gather}")[0] else { return XCTFail() }
        XCTAssertEqual(gather.kind, .gather)
    }

    func testArrayColumnSpecAndRules() {
        guard case .array(let array) = parse("\\begin{array}{l|cr} a & b & c \\\\ \\hline d & e & f \\end{array}")[0] else {
            return XCTFail()
        }
        XCTAssertEqual(array.kind, .array)
        XCTAssertEqual(array.columns, [.left, .center, .right])
        XCTAssertEqual(array.verticalRules, [1])
        XCTAssertEqual(array.horizontalRules, [1])
        XCTAssertEqual(array.rows.count, 2)
    }

    func testTopLevelLineBreaksMakeRows() {
        guard case .array(let rows) = parse("a = b \\\\ c = d")[0] else { return XCTFail() }
        XCTAssertEqual(rows.kind, .gather)
        XCTAssertEqual(rows.rows.count, 2)
    }

    // MARK: Parser: error tolerance

    func testUnknownCommandBecomesErrorNode() {
        let result = AgentMathParser.parse("a + \\foo b")
        XCTAssertEqual(result.nodes, [.symbol("a", .ord), .symbol("+", .bin), .error("\\foo"), .symbol("b", .ord)])
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testUnbalancedBracesRecover() {
        let open = AgentMathParser.parse("\\frac{a}{b")
        XCTAssertEqual(open.nodes, [.fraction(numerator: .group([.symbol("a", .ord)]), denominator: .group([.symbol("b", .ord)]), hasRule: true, style: nil)])
        XCTAssertFalse(open.errors.isEmpty)
        let stray = AgentMathParser.parse("a } b")
        XCTAssertEqual(stray.nodes, [.symbol("a", .ord), .error("}"), .symbol("b", .ord)])
        XCTAssertFalse(stray.errors.isEmpty)
    }

    func testMissingArgumentsAndRightRecover() {
        XCTAssertFalse(AgentMathParser.parse("\\frac{1}{").errors.isEmpty)
        XCTAssertFalse(AgentMathParser.parse("x^").errors.isEmpty)
        let left = AgentMathParser.parse("\\left( x")
        XCTAssertEqual(left.nodes, [.leftRight(left: "(", body: [.symbol("x", .ord)], right: "")])
        XCTAssertFalse(left.errors.isEmpty)
        XCTAssertFalse(AgentMathParser.parse("\\begin{pmatrix} 1 & 2").errors.isEmpty)
    }

    func testPathologicalInputDoesNotCrash() {
        for source in ["", "\\", "{", "}", "^_^", "\\left", "\\right)", "&&", "\\\\", "\\begin{}", "\\end{x}",
                       String(repeating: "{", count: 500), String(repeating: "\\sqrt", count: 200)] {
            let result = AgentMathTypesetter.typesetUncached(source, options: options())
            XCTAssertGreaterThanOrEqual(result.size.width, 0, source)
        }
    }

    func testValidInputHasNoErrorsAndInvalidDoes() {
        XCTAssertFalse(AgentMathTypesetter.typesetUncached("\\frac{a}{b} + \\sqrt{x}", options: options()).hasErrors)
        XCTAssertTrue(AgentMathTypesetter.typesetUncached("\\nosuchcommand x", options: options()).hasErrors)
    }

    // MARK: Fonts

    func testUsesStixTwoMathAndItsMathTable() {
        let font = AgentMathFont.shared
        XCTAssertTrue(font.isMathFont)
        XCTAssertGreaterThan(font.value(.axisHeight, size: 20), 0)
        XCTAssertGreaterThan(font.value(.fractionRuleThickness, size: 20), 0)
        let glyph = glyphID("(", size: 20)
        XCTAssertGreaterThan(font.verticalConstruction(glyph)?.variants.count ?? 0, 1)
    }

    func testMathAlphabetMapping() {
        XCTAssertEqual(AgentMathAlphabet.map("a", .normal).value, 0x1D44E)
        XCTAssertEqual(AgentMathAlphabet.map("h", .normal).value, 0x210E)
        XCTAssertEqual(AgentMathAlphabet.map("R", .doubleStruck).value, 0x211D)
        XCTAssertEqual(AgentMathAlphabet.map("A", .bold).value, 0x1D400)
        XCTAssertEqual(AgentMathAlphabet.map("L", .script).value, 0x2112)
        XCTAssertEqual(AgentMathAlphabet.map("α", .normal).value, 0x1D6FC)
        XCTAssertEqual(AgentMathAlphabet.map("Γ", .normal).value, 0x0393)
        XCTAssertEqual(AgentMathAlphabet.map("1", .normal).value, 0x31)
        XCTAssertEqual(AgentMathAlphabet.map("x", .roman).value, 0x78)
    }

    // MARK: Layout geometry

    private struct Placement {
        var glyph: CGGlyph
        var fontSize: CGFloat
        var frame: CGRect
    }

    private func glyphID(_ character: String, size: CGFloat, variant: AgentMathFontVariant = .roman) -> CGGlyph {
        let font = AgentMathFont.shared.font(size: size)
        let scalar = AgentMathAlphabet.map(character.unicodeScalars.first ?? " ", variant)
        var units = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
        return glyphs[0]
    }

    private func placements(_ box: AgentMathBox, at origin: CGPoint = .zero) -> [Placement] {
        var result: [Placement] = []
        for item in box.items {
            switch item {
            case .glyphs(let font, let glyphs, let positions, _):
                for (glyph, position) in zip(glyphs, positions) {
                    var glyph = glyph
                    var rect = CGRect.zero
                    CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &rect, 1)
                    result.append(Placement(
                        glyph: glyph,
                        fontSize: CTFontGetSize(font),
                        frame: rect.offsetBy(dx: origin.x + position.x, dy: origin.y + position.y)
                    ))
                }
            case .box(let child, let position):
                result += placements(child, at: CGPoint(x: origin.x + position.x, y: origin.y + position.y))
            default:
                break
            }
        }
        return result
    }

    private func layout(_ latex: String, display: Bool = false) -> AgentMathBox {
        AgentMathLayout(fontSize: 20).layout(AgentMathParser.parse(latex), displayMode: display)
    }

    private func find(_ character: String, in box: AgentMathBox, variant: AgentMathFontVariant = .normal) -> [Placement] {
        let all = placements(box)
        return all.filter { placement in placement.glyph == glyphID(character, size: placement.fontSize, variant: variant) }
    }

    func testFractionNumeratorAboveDenominator() throws {
        let box = layout("\\frac{a}{b}", display: true)
        let a = try XCTUnwrap(find("a", in: box).first)
        let b = try XCTUnwrap(find("b", in: box).first)
        XCTAssertGreaterThan(a.frame.minY, b.frame.maxY)
        XCTAssertGreaterThan(box.height, a.frame.maxY - 0.01)
        XCTAssertEqual(a.frame.midX, b.frame.midX, accuracy: 2)
    }

    func testDisplayFractionIsLargerThanInline() {
        XCTAssertGreaterThan(layout("\\frac{a}{b}", display: true).height, layout("\\frac{a}{b}").height)
    }

    func testSuperscriptRaisedAndSmallerSubscriptLowered() throws {
        let box = layout("x^2_i")
        let x = try XCTUnwrap(find("x", in: box).first)
        let two = try XCTUnwrap(find("2", in: box).first)
        let i = try XCTUnwrap(find("i", in: box).first)
        XCTAssertGreaterThan(two.frame.minY, 0)
        XCTAssertLessThan(i.frame.minY, x.frame.minY)
        XCTAssertEqual(two.fontSize, 14, accuracy: 0.01)
        XCTAssertGreaterThan(two.frame.minX, x.frame.minX)
    }

    func testScriptScriptSizeForNestedScripts() throws {
        let box = layout("e^{x^2}")
        let two = try XCTUnwrap(find("2", in: box).first)
        XCTAssertEqual(two.fontSize, 10, accuracy: 0.01)
    }

    func testDisplaySumLimitsAboveAndBelowInlineToTheSide() throws {
        let display = layout("\\sum_{i}^{n}", display: true)
        let inline = layout("\\sum_{i}^{n}")
        let displayN = try XCTUnwrap(find("n", in: display).first)
        let displayI = try XCTUnwrap(find("i", in: display).first)
        let inlineN = try XCTUnwrap(find("n", in: inline).first)
        let operatorBottom = display.depth
        XCTAssertLessThan(displayN.frame.minX, display.width / 2)
        XCTAssertGreaterThan(displayN.frame.maxX, display.width / 2)
        XCTAssertLessThan(displayI.frame.maxY, 0)
        XCTAssertGreaterThan(operatorBottom, -displayI.frame.minY - 0.01)
        XCTAssertGreaterThan(inlineN.frame.minX, inline.width / 2)
        XCTAssertGreaterThan(display.height, inline.height)
    }

    func testIntegralKeepsScriptsAtTheSideInDisplay() throws {
        let box = layout("\\int_0^1", display: true)
        let one = try XCTUnwrap(find("1", in: box).first)
        let zero = try XCTUnwrap(find("0", in: box).first)
        XCTAssertGreaterThan(one.frame.minX, zero.frame.minX)
        XCTAssertGreaterThan(one.frame.minX, box.width / 3)
    }

    func testLeftDelimiterGrowsWithContent() {
        let small = layout("\\left( x \\right)")
        let tall = layout("\\left( \\frac{\\frac{a}{b}}{\\frac{c}{d}} \\right)", display: true)
        let smallParen = placements(small).filter { $0.frame.minX < 2 }.map(\.frame.height).max() ?? 0
        let tallParen = placements(tall).filter { $0.frame.minX < 2 }.map(\.frame.height).max() ?? 0
        XCTAssertGreaterThan(tallParen, smallParen * 1.8)
        XCTAssertGreaterThan(tallParen, tall.height + tall.depth - 10)
    }

    func testVeryTallDelimitersUseAssemblies() {
        let rows = Array(repeating: "x", count: 12).joined(separator: " \\\\ ")
        let box = layout("\\left( \\begin{matrix} \(rows) \\end{matrix} \\right)")
        let parenGlyphs = placements(box).filter { $0.frame.minX < 2 }
        XCTAssertGreaterThan(parenGlyphs.count, 1)
        let top = parenGlyphs.map(\.frame.maxY).max() ?? 0
        let bottom = parenGlyphs.map(\.frame.minY).min() ?? 0
        XCTAssertGreaterThan(top - bottom, (box.height + box.depth) * 0.85)
    }

    func testBigDelimitersGrowStepwise() {
        let heights = ["\\big(", "\\Big(", "\\bigg(", "\\Bigg("].map { source -> CGFloat in
            let box = layout(source)
            return box.height + box.depth
        }
        XCTAssertEqual(heights, heights.sorted())
        XCTAssertGreaterThan(heights[3], heights[0] * 2)
    }

    func testMatrixColumnsAreAligned() throws {
        let box = layout("\\begin{matrix} 1 & 2 \\\\ 3333 & 4 \\end{matrix}")
        let one = try XCTUnwrap(find("1", in: box).first)
        let threes = find("3", in: box)
        let two = try XCTUnwrap(find("2", in: box).first)
        let four = try XCTUnwrap(find("4", in: box).first)
        XCTAssertEqual(threes.count, 4)
        let threesCenter = ((threes.map(\.frame.minX).min() ?? 0) + (threes.map(\.frame.maxX).max() ?? 0)) / 2
        XCTAssertEqual(one.frame.midX, threesCenter, accuracy: 1)
        XCTAssertEqual(two.frame.midX, four.frame.midX, accuracy: 1)
        XCTAssertGreaterThan(one.frame.minY, four.frame.maxY)
    }

    func testAlignedColumnsLineUpAtTheRelation() throws {
        let box = layout("\\begin{aligned} a &= b \\\\ ccc &= d \\end{aligned}")
        let equals = find("=", in: box, variant: .roman)
        XCTAssertEqual(equals.count, 2)
        XCTAssertEqual(equals[0].frame.minX, equals[1].frame.minX, accuracy: 0.5)
    }

    func testRadicalCoversItsRadicand() throws {
        let box = layout("\\sqrt{x}")
        let x = try XCTUnwrap(find("x", in: box).first)
        let surd = try XCTUnwrap(placements(box).first { $0.frame.minX < x.frame.minX })
        XCTAssertGreaterThan(surd.frame.maxY, x.frame.maxY)
        XCTAssertGreaterThan(box.height, x.frame.maxY)
    }

    func testAccentSitsAboveItsBase() throws {
        let plain = layout("x")
        let accented = layout("\\hat{x}")
        XCTAssertGreaterThan(accented.height, plain.height)
        XCTAssertEqual(accented.width, plain.width, accuracy: 0.01)
    }

    func testInterAtomSpacing() {
        let tight = layout("ab").width
        let binary = layout("a+b").width - layout("+").width
        let relation = layout("a=b").width - layout("=").width
        XCTAssertGreaterThan(binary, tight)
        XCTAssertGreaterThan(relation, binary)
        let leadingMinus = layout("-a").width
        XCTAssertEqual(leadingMinus, layout("-").width + layout("a").width, accuracy: 0.01)
    }

    func testScriptStyleDropsMediumSpaces() {
        let inline = layout("a+b").width
        let script = layout("x^{a+b}").width - layout("x").width
        XCTAssertLessThan(script, inline * 0.7)
    }

    func testPhantomTakesSpaceWithoutInk() {
        let box = layout("\\phantom{xyz}")
        XCTAssertGreaterThan(box.width, 10)
        XCTAssertTrue(placements(box).isEmpty)
    }

    func testTagGoesToTheRight() {
        let plain = layout("x", display: true)
        let tagged = layout("x \\tag{1}", display: true)
        XCTAssertGreaterThan(tagged.width, plain.width + 20)
    }

    // MARK: Typesetter, cache, image

    func testResultSizeAndBaseline() {
        let result = AgentMathTypesetter.typesetUncached("x^2", options: options())
        XCTAssertGreaterThan(result.size.width, 0)
        XCTAssertGreaterThan(result.baseline, 0)
        XCTAssertLessThanOrEqual(result.baseline, result.size.height)
    }

    func testCacheReusesResultsAndKeysOnColorAndMode() {
        let latex = "\\frac{cache}{\(UUID().uuidString)}"
        let cache = AgentMathTypesetter.cache
        _ = AgentMathTypesetter.typeset(latex, options: options())
        let hits = cache.hits
        _ = AgentMathTypesetter.typeset(latex, options: options())
        XCTAssertEqual(cache.hits, hits + 1)
        let base = AgentMathTypesetter.CacheKey(latex: latex, displayMode: false, fontSize: 20, color: .black, errorColor: .systemRed)
        XCTAssertTrue(cache.contains(base))
        var blue = base
        blue.color = .blue
        XCTAssertFalse(cache.contains(blue))
        _ = AgentMathTypesetter.typeset(latex, options: options(display: true))
        var display = base
        display.displayMode = true
        XCTAssertTrue(cache.contains(display))
    }

    func testCacheEvictsLeastRecentlyUsed() {
        let cache = AgentMathCache(capacity: 2)
        let result = AgentMathTypesetter.typesetUncached("x", options: options())
        func key(_ latex: String) -> AgentMathTypesetter.CacheKey {
            .init(latex: latex, displayMode: false, fontSize: 12, color: .black, errorColor: .red)
        }
        cache.insert(result, for: key("a"))
        cache.insert(result, for: key("b"))
        XCTAssertNotNil(cache.value(for: key("a")))
        cache.insert(result, for: key("c"))
        XCTAssertEqual(cache.count, 2)
        XCTAssertTrue(cache.contains(key("a")))
        XCTAssertFalse(cache.contains(key("b")))
        XCTAssertTrue(cache.contains(key("c")))
    }

    func testTypesettingIsSafeAcrossThreads() {
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let result = AgentMathTypesetter.typeset("\\sum_{k=0}^{\(index % 4)} \\frac{x^k}{k!}", options: options())
            XCTAssertGreaterThan(result.size.width, 0)
        }
    }

    func testImageAlignsBaselineForAttachments() {
        let result = AgentMathTypesetter.typeset("y_i", options: options())
        let (image, offset) = AgentMathTypesetter.image("y_i", options: options(), scale: 2)
        XCTAssertEqual(image.size, result.size)
        XCTAssertEqual(offset, result.baseline - result.size.height, accuracy: 0.001)
        XCTAssertLessThan(offset, 0)
        let representation = image.representations.first
        XCTAssertEqual(representation?.pixelsWide, Int((result.size.width * 2).rounded(.up)))
    }

    // MARK: Rendering

    private func inkedPixelCount(_ latex: String, display: Bool) throws -> Int {
        let result = AgentMathTypesetter.typesetUncached(latex, options: options(display: display))
        let width = Int(result.size.width.rounded(.up)) + 2
        let height = Int(result.size.height.rounded(.up)) + 2
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = try pixels.withUnsafeMutableBytes { buffer -> Bool in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            result.draw(context)
            return true
        }
        XCTAssertTrue(drew)
        return stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count
    }

    func testRenderingSmokeProducesInk() throws {
        let samples: [(String, Bool)] = [
            ("E = mc^2", false), ("\\frac{a}{b}", false), ("\\sqrt{x}", false), ("\\sum_{i=1}^{n} i", true),
            ("\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}", true), ("\\int_0^\\infty e^{-x} dx", true),
        ]
        for (latex, display) in samples {
            XCTAssertGreaterThan(try inkedPixelCount(latex, display: display), 30, latex)
        }
    }

    func testErrorsRenderInsteadOfThrowing() throws {
        XCTAssertGreaterThan(try inkedPixelCount("\\unknown{x}", display: false), 30)
    }

    // MARK: View

    func testMathViewSizesLabelsAndSkipsUnchangedUpdates() throws {
        let view = AgentMathView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        view.set(latex: "\\frac{1}{2}", fontSize: 18, color: .black, errorColor: .red)
        let result = try XCTUnwrap(view.result)
        XCTAssertEqual(view.intrinsicContentSize, result.size)
        XCTAssertEqual(view.accessibilityLabel(), "\\frac{1}{2}")
        let hits = AgentMathTypesetter.cache.hits
        view.set(latex: "\\frac{1}{2}", fontSize: 18, color: .black, errorColor: .red)
        XCTAssertEqual(AgentMathTypesetter.cache.hits, hits)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = try XCTUnwrap(view.menu(for: event))
        XCTAssertEqual(menu.items.map(\.title), ["Copy LaTeX"])
    }

    // MARK: Performance

    func testTypesettingALongExpressionIsFast() {
        let latex = "f(x) = \\sum_{k=0}^{\\infty} \\frac{f^{(k)}(a)}{k!}(x-a)^k + \\int_0^1 \\sqrt{1 + \\left(\\frac{dy}{dx}\\right)^2}\\,dx"
            + " - \\begin{pmatrix} \\alpha & \\beta \\\\ \\gamma & \\delta \\end{pmatrix} \\cdot \\vec{v} \\leq \\lim_{n\\to\\infty} a_n"
        XCTAssertGreaterThanOrEqual(latex.count, 200)
        let options = options(display: true)
        _ = AgentMathTypesetter.typesetUncached(latex, options: options)
        let start = DispatchTime.now().uptimeNanoseconds
        let iterations = 20
        for _ in 0..<iterations { _ = AgentMathTypesetter.typesetUncached(latex, options: options) }
        let average = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1_000_000
        XCTAssertLessThan(average, 4, "average \(average) ms")
        measure {
            _ = AgentMathTypesetter.typesetUncached(latex, options: options)
        }
    }
}
