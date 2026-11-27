import AppKit
import XCTest
@testable import TabApp

/// Draws a diagram layout into an RGBA bitmap and returns how many pixels are not transparent.
func renderedInkPixels(_ layout: AgentDiagramLayout) -> Int {
    let width = max(1, Int(ceil(layout.size.width)))
    let height = max(1, Int(ceil(layout.size.height)))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    layout.draw(context)
    guard let data = context.data else { return 0 }
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    var ink = 0
    for index in 0..<(width * height) where pixels[index * 4 + 3] > 0 { ink += 1 }
    return ink
}

func diagramStyle(dark: Bool) -> AgentDiagramStyle {
    var style = AgentDiagramStyle()
    style.foreground = dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.1, alpha: 1)
    style.muted = dark ? NSColor(white: 0.65, alpha: 1) : NSColor(white: 0.4, alpha: 1)
    style.surface = dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.98, alpha: 1)
    style.border = dark ? NSColor(white: 0.35, alpha: 1) : NSColor(white: 0.8, alpha: 1)
    style.accent = NSColor.systemBlue
    style.accentSoft = NSColor.systemBlue.withAlphaComponent(0.15)
    return style
}

final class AgentFlowchartDiagramTests: XCTestCase {
    private func parse(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> AgentFlowchartDiagram {
        try AgentFlowchartDiagram(source: source)
    }

    private func edge(_ diagram: AgentFlowchartDiagram, _ index: Int = 0) -> AgentFlowchartDiagram.Edge {
        diagram.edges[index]
    }

    private func assertError(_ source: String, line expected: Int?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try AgentFlowchartDiagram(source: source), file: file, line: line) { error in
            guard let diagramError = error as? AgentDiagramError else {
                return XCTFail("Unexpected error \(error)", file: file, line: line)
            }
            XCTAssertFalse(diagramError.message.isEmpty, file: file, line: line)
            if let expected { XCTAssertEqual(diagramError.line, expected, diagramError.message, file: file, line: line) }
        }
    }

    // MARK: Header

    func testKeywordsMatchTheSourceHeader() {
        XCTAssertEqual(AgentFlowchartDiagram.keywords, ["flowchart", "graph"])
        XCTAssertTrue(AgentFlowchartDiagram.keywords.contains(AgentDiagramSource.keyword(of: "%% hi\ngraph LR\nA-->B") ?? ""))
    }

    func testHeaderDirections() throws {
        XCTAssertEqual(try parse("flowchart").direction, .topToBottom)
        XCTAssertEqual(try parse("flowchart TD").direction, .topToBottom)
        XCTAssertEqual(try parse("graph TB").direction, .topToBottom)
        XCTAssertEqual(try parse("graph BT").direction, .bottomToTop)
        XCTAssertEqual(try parse("flowchart LR").direction, .leftToRight)
        XCTAssertEqual(try parse("flowchart RL").direction, .rightToLeft)
        XCTAssertEqual(try parse("graph LR;A-->B").edges.count, 1)
    }

    func testMissingOrWrongHeaderFails() {
        assertError("", line: nil)
        assertError("%% only a comment", line: nil)
        assertError("sequenceDiagram\nA->>B: hi", line: 1)
    }

    // MARK: Shapes

    func testEveryNodeShape() throws {
        let cases: [(String, AgentGraphScene.Shape)] = [
            ("A[text]", .rectangle), ("A(text)", .rounded), ("A([text])", .stadium), ("A[[text]]", .subroutine),
            ("A[(text)]", .cylinder), ("A((text))", .circle), ("A>text]", .asymmetric), ("A{text}", .diamond),
            ("A{{text}}", .hexagon), ("A[/text/]", .parallelogram), ("A[\\text\\]", .parallelogramAlt),
            ("A[/text\\]", .trapezoid), ("A[\\text/]", .trapezoidAlt), ("A(((text)))", .doubleCircle),
        ]
        for (statement, shape) in cases {
            let diagram = try parse("flowchart TD\n\(statement)")
            XCTAssertEqual(diagram.nodes.count, 1, statement)
            XCTAssertEqual(diagram.nodes.first?.shape, shape, statement)
            XCTAssertEqual(diagram.nodes.first?.label, "text", statement)
        }
    }

    func testBareNodeUsesItsIDAsLabel() throws {
        let diagram = try parse("graph TD\nalpha_1")
        XCTAssertEqual(diagram.nodes.first?.label, "alpha_1")
        XCTAssertEqual(diagram.nodes.first?.shape, .rectangle)
    }

    func testLastShapeDefinitionWins() throws {
        let diagram = try parse("graph TD\nA[one] --> B\nA{two}")
        XCTAssertEqual(diagram.node("A")?.label, "two")
        XCTAssertEqual(diagram.node("A")?.shape, .diamond)
    }

    func testShapeDataSyntax() throws {
        let diagram = try parse("flowchart TD\nA@{ shape: cyl, label: \"Store\" } --> B@{ shape: diamond }")
        XCTAssertEqual(diagram.node("A")?.shape, .cylinder)
        XCTAssertEqual(diagram.node("A")?.label, "Store")
        XCTAssertEqual(diagram.node("B")?.shape, .diamond)
    }

    func testLabelsWithNestedBracketsAndPunctuation() throws {
        let diagram = try parse("graph TD\nA[call f(x) now] --> B(see (note)) --> C{a [b] c}")
        XCTAssertEqual(diagram.node("A")?.label, "call f(x) now")
        XCTAssertEqual(diagram.node("B")?.label, "see (note)")
        XCTAssertEqual(diagram.node("C")?.label, "a [b] c")
    }

    // MARK: Labels

    func testQuotedLabelsAndEntityCodes() throws {
        let diagram = try parse("graph TD\nA[\"Hello [world] (x)\"] --> B[\"say #quot;hi#quot; #amp; #35; &lt;tag&gt;\"]")
        XCTAssertEqual(diagram.node("A")?.label, "Hello [world] (x)")
        XCTAssertEqual(diagram.node("B")?.label, "say \"hi\" & # <tag>")
    }

    func testMarkdownStringLabel() throws {
        let diagram = try parse("flowchart LR\nA[\"`**Bold** move`\"]")
        XCTAssertEqual(diagram.node("A")?.label, "Bold move")
    }

    func testLineBreaksInLabels() throws {
        let diagram = try parse("graph TD\nA[one<br/>two<br>three<BR />four\\nfive]")
        XCTAssertEqual(diagram.node("A")?.label, "one\ntwo\nthree\nfour\nfive")
    }

    func testSemicolonInsideEntityDoesNotSplitStatements() throws {
        let diagram = try parse("graph TD\nA[a #59; b] --> B; B --> C")
        XCTAssertEqual(diagram.node("A")?.label, "a ; b")
        XCTAssertEqual(diagram.edges.count, 2)
    }

    // MARK: Edges

    func testEveryEdgeType() throws {
        typealias Case = (String, AgentGraphScene.Stroke, AgentGraphScene.Head, AgentGraphScene.Head)
        let cases: [Case] = [
            ("-->", .solid, .none, .arrow), ("---", .solid, .none, .none), ("-.->", .dotted, .none, .arrow),
            ("-.-", .dotted, .none, .none), ("==>", .thick, .none, .arrow), ("===", .thick, .none, .none),
            ("--o", .solid, .none, .circle), ("--x", .solid, .none, .cross), ("<-->", .solid, .arrow, .arrow),
            ("o--o", .solid, .circle, .circle), ("x--x", .solid, .cross, .cross), ("<==>", .thick, .arrow, .arrow),
            ("~~~", .invisible, .none, .none),
        ]
        for (op, stroke, start, end) in cases {
            let diagram = try parse("flowchart TD\nA \(op) B")
            XCTAssertEqual(diagram.edges.count, 1, op)
            XCTAssertEqual(diagram.edges.first?.stroke, stroke, op)
            XCTAssertEqual(diagram.edges.first?.startHead, start, op)
            XCTAssertEqual(diagram.edges.first?.endHead, end, op)
            XCTAssertEqual(diagram.nodes.map(\.id), ["A", "B"], op)
        }
    }

    func testEdgesWithoutSpaces() throws {
        let diagram = try parse("graph TD\nA-->B\nB---C\nC-.->D\nD==>E")
        XCTAssertEqual(diagram.edges.map { "\($0.from)\($0.to)" }, ["AB", "BC", "CD", "DE"])
        XCTAssertEqual(diagram.nodes.map(\.id), ["A", "B", "C", "D", "E"])
    }

    func testEdgeLabelForms() throws {
        let cases = ["A -- go on --> B", "A -->|go on| B", "A-->|go on|B", "A -. go on .-> B", "A == go on ==> B", "A -- go on --- B"]
        for source in cases {
            let diagram = try parse("flowchart TD\n\(source)")
            XCTAssertEqual(diagram.edges.count, 1, source)
            XCTAssertEqual(diagram.edges.first?.label, "go on", source)
            XCTAssertEqual(diagram.nodes.map(\.id), ["A", "B"], source)
        }
        XCTAssertEqual(try parse("graph TD\nA -. x .-> B").edges.first?.stroke, .dotted)
        XCTAssertEqual(try parse("graph TD\nA == x ==> B").edges.first?.stroke, .thick)
        XCTAssertEqual(try parse("graph TD\nA -- x --- B").edges.first?.endHead, AgentGraphScene.Head.none)
    }

    func testLongerEdgesRequestMoreRanks() throws {
        XCTAssertEqual(try parse("graph TD\nA --> B").edges.first?.length, 1)
        XCTAssertEqual(try parse("graph TD\nA ---> B").edges.first?.length, 2)
        XCTAssertEqual(try parse("graph TD\nA ----> B").edges.first?.length, 3)
        XCTAssertEqual(try parse("graph TD\nA -..-> B").edges.first?.length, 2)
        XCTAssertEqual(try parse("graph TD\nA ===> B").edges.first?.length, 2)
        XCTAssertEqual(try parse("graph TD\nA ---- B").edges.first?.length, 2)
    }

    func testChainedEdges() throws {
        let diagram = try parse("graph LR\nA --> B -- yes --> C -.-> D")
        XCTAssertEqual(diagram.edges.map { "\($0.from)\($0.to)" }, ["AB", "BC", "CD"])
        XCTAssertEqual(diagram.edges[1].label, "yes")
        XCTAssertEqual(diagram.edges[2].stroke, .dotted)
    }

    func testAmpersandGroups() throws {
        let diagram = try parse("graph TD\nA & B --> C & D")
        XCTAssertEqual(diagram.edges.map { "\($0.from)\($0.to)" }, ["AC", "AD", "BC", "BD"])
        let single = try parse("graph TD\nA --> B & C[See]")
        XCTAssertEqual(single.edges.map(\.to), ["B", "C"])
        XCTAssertEqual(single.node("C")?.label, "See")
    }

    func testIDsWithDashesAndLeadingOAndX() throws {
        let diagram = try parse("graph TD\nmy-node --> other_node\nox --> xo\nA --> oNode")
        XCTAssertEqual(diagram.nodes.map(\.id), ["my-node", "other_node", "ox", "xo", "A", "oNode"])
        XCTAssertEqual(diagram.edges.count, 3)
        XCTAssertTrue(diagram.edges.allSatisfy { $0.endHead == .arrow && $0.startHead == .none })
    }

    // MARK: Subgraphs

    func testSubgraphsNestAndClaimNodes() throws {
        let diagram = try parse("""
        flowchart TB
            c1 --> a2
            subgraph one
                a1 --> a2
                subgraph inner [Inner title]
                    i1
                end
            end
            subgraph two["Second"]
                b1 --> b2
            end
            one --> two
        """)
        XCTAssertEqual(diagram.subgraphs.map(\.id), ["one", "inner", "two"])
        XCTAssertEqual(diagram.subgraphs.map(\.title), ["one", "Inner title", "Second"])
        XCTAssertEqual(diagram.subgraphs[1].parent, 0)
        XCTAssertNil(diagram.subgraphs[0].parent)
        XCTAssertNil(diagram.node("c1")?.subgraph)
        XCTAssertEqual(diagram.node("a2")?.subgraph, 0)
        XCTAssertEqual(diagram.node("i1")?.subgraph, 1)
        XCTAssertEqual(diagram.node("b1")?.subgraph, 2)
        XCTAssertNil(diagram.node("one"), "Subgraph ids are not nodes")
        let scene = diagram.scene
        XCTAssertEqual(scene.edges.last?.from, .cluster(0))
        XCTAssertEqual(scene.edges.last?.to, .cluster(2))
    }

    func testQuotedSubgraphTitleAndDirection() throws {
        let diagram = try parse("""
        flowchart TB
        subgraph "Only a title"
            direction LR
            A --> B
        end
        """)
        XCTAssertEqual(diagram.subgraphs.first?.title, "Only a title")
        XCTAssertEqual(diagram.subgraphs.first?.direction, .leftToRight)
        XCTAssertEqual(diagram.direction, .topToBottom)
    }

    func testSubgraphErrorsReportLines() {
        assertError("graph TD\nA --> B\nend", line: 3)
        assertError("graph TD\nsubgraph one\nA --> B", line: 3)
        assertError("graph TD\nsubgraph one\ndirection sideways\nend", line: 3)
    }

    // MARK: Styles

    func testClassDefClassAndTripleColon() throws {
        let diagram = try parse("""
        graph TD
        classDef hot fill:#f96,stroke:#333,stroke-width:4px,color:#fff
        classDef cool,calm fill:rgb(0, 128, 255),stroke-dasharray: 5 5
        A:::hot --> B
        class B,C cool
        C --> D
        """)
        let a = try XCTUnwrap(diagram.node("A"))
        XCTAssertEqual(a.style.fill, AgentDiagramColor(red: 1, green: 0x99 / 255, blue: 0x66 / 255))
        XCTAssertEqual(a.style.stroke, AgentDiagramColor(red: 0x33 / 255, green: 0x33 / 255, blue: 0x33 / 255))
        XCTAssertEqual(a.style.strokeWidth, 4)
        XCTAssertEqual(a.style.text, AgentDiagramColor(red: 1, green: 1, blue: 1))
        let b = try XCTUnwrap(diagram.node("B"))
        XCTAssertEqual(b.style.fill, AgentDiagramColor(red: 0, green: 128 / 255, blue: 1))
        XCTAssertTrue(b.style.dashed)
        XCTAssertEqual(diagram.node("C")?.style.fill, b.style.fill)
        XCTAssertNil(diagram.node("D")?.style.fill)
    }

    func testStyleStatementAndDefaultClass() throws {
        let diagram = try parse("""
        graph TD
        classDef default fill:#eee
        A --> B
        style B fill:#000,stroke:nonsense,unknown-key:1
        """)
        XCTAssertEqual(diagram.node("A")?.style.fill, AgentDiagramColor(red: 0xee / 255, green: 0xee / 255, blue: 0xee / 255))
        XCTAssertEqual(diagram.node("B")?.style.fill, AgentDiagramColor(red: 0, green: 0, blue: 0))
        XCTAssertNil(diagram.node("B")?.style.stroke, "Unparseable colors are ignored")
    }

    // MARK: Comments, separators, ignored statements

    func testCommentsSemicolonsAndIgnoredStatements() throws {
        let diagram = try parse("""
        %%{init: {"theme": "dark"}}%%
        graph TD;
            %% a comment line
            A-->B;B-->C; %% trailing comment
            click A callback "Tooltip"
            click B href "https://example.com"
            linkStyle 0 stroke:#ff3,stroke-width:4px
            accTitle: Title
        """)
        XCTAssertEqual(diagram.nodes.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(diagram.edges.count, 2)
    }

    func testBadStatementsReportTheirLine() {
        assertError("graph TD\nA --> B\nA --> \n", line: 3)
        assertError("graph TD\nA --> B\nC[unclosed", line: 3)
        assertError("graph TD\n\n\nA -- text without end B", line: 4)
        assertError("graph TD\nA --> B\n???", line: 3)
        assertError("graph TD\nA --> B ]", line: 2)
    }

    func testHostileInputNeverCrashes() {
        var generator = DiagramTestRandom(seed: 42)
        let alphabet = Array("ABxo-=.>|[](){}<\"&:;/\\%#~@ \nsubgraph end")
        for _ in 0..<300 {
            let length = Int.random(in: 0..<120, using: &generator)
            let body = String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
            if let diagram = try? AgentFlowchartDiagram(source: "flowchart TD\n" + body) {
                _ = diagram.scene.geometry(style: AgentDiagramStyle())
            }
        }
        let huge = "graph TD\n" + String(repeating: "A", count: AgentFlowchartDiagram.maximumSourceLength)
        XCTAssertThrowsError(try AgentFlowchartDiagram(source: huge))
        let many = "graph TD\n" + (0...AgentFlowchartDiagram.maximumNodes).map { "n\($0)" }.joined(separator: "\n")
        XCTAssertThrowsError(try AgentFlowchartDiagram(source: many))
    }

    // MARK: Layout

    private func geometry(_ source: String) throws -> (AgentFlowchartDiagram, AgentGraphScene.Geometry) {
        let diagram = try parse(source)
        return (diagram, diagram.scene.geometry(style: AgentDiagramStyle()))
    }

    private func frame(_ diagram: AgentFlowchartDiagram, _ geometry: AgentGraphScene.Geometry, _ id: String) -> CGRect {
        guard let index = diagram.nodes.firstIndex(where: { $0.id == id }) else { return .null }
        return geometry.nodeFrames[index]
    }

    private let sample = """
    flowchart TD
        Start([Start]) --> Check{Valid?}
        Check -->|yes| Save[(Store)]
        Check -->|no| Fix[Fix input]
        Fix --> Check
        Save --> Notify[[Notify]] --> Done((Done))
        Check -.-> Log>Log it]
    """

    func testTopDownEdgesPointDownExceptBackEdges() throws {
        let (diagram, geometry) = try geometry(sample)
        for edge in diagram.edges {
            let from = frame(diagram, geometry, edge.from)
            let to = frame(diagram, geometry, edge.to)
            if edge.from == "Fix" && edge.to == "Check" {
                XCTAssertLessThan(to.maxY, from.minY, "The back edge goes up")
            } else {
                XCTAssertGreaterThan(to.minY, from.maxY, "\(edge.from) → \(edge.to)")
            }
        }
    }

    func testNodesNeverOverlap() throws {
        let source = sample + "\n" + (0..<20).map { "Done --> L\($0)[Leaf \($0)]" }.joined(separator: "\n")
        let (_, geometry) = try geometry(source)
        for i in geometry.nodeFrames.indices {
            for j in geometry.nodeFrames.indices where j > i {
                XCTAssertFalse(geometry.nodeFrames[i].insetBy(dx: 0.5, dy: 0.5).intersects(geometry.nodeFrames[j]), "\(i) overlaps \(j)")
            }
        }
    }

    func testClusterContainsItsChildren() throws {
        let (diagram, geometry) = try geometry("""
        flowchart LR
            x --> a1
            subgraph outer [Outer]
                a1 --> a2
                subgraph inner
                    direction TB
                    b1 --> b2
                end
                a2 --> b1
            end
            b2 --> y
        """)
        let outer = geometry.clusterFrames[0]
        let inner = geometry.clusterFrames[1]
        XCTAssertTrue(outer.contains(inner))
        for id in ["a1", "a2", "b1", "b2"] { XCTAssertTrue(outer.contains(frame(diagram, geometry, id)), id) }
        for id in ["b1", "b2"] { XCTAssertTrue(inner.contains(frame(diagram, geometry, id)), id) }
        for id in ["x", "y"] { XCTAssertFalse(outer.intersects(frame(diagram, geometry, id)), id) }
        XCTAssertGreaterThan(frame(diagram, geometry, "b2").minY, frame(diagram, geometry, "b1").maxY, "The inner cluster flows top-down")
        XCTAssertGreaterThan(frame(diagram, geometry, "a2").minX, frame(diagram, geometry, "a1").maxX, "The outer cluster flows left-right")
    }

    func testLeftRightMirrorsTopDown() throws {
        let body = sample.split(separator: "\n").dropFirst().joined(separator: "\n")
        let (top, topGeometry) = try geometry("flowchart TD\n" + body)
        let (left, leftGeometry) = try geometry("flowchart LR\n" + body)
        XCTAssertEqual(top.nodes.map(\.id), left.nodes.map(\.id))
        for edge in top.edges where !(edge.from == "Fix" && edge.to == "Check") {
            XCTAssertGreaterThan(frame(top, topGeometry, edge.to).midY, frame(top, topGeometry, edge.from).midY)
            XCTAssertGreaterThan(frame(left, leftGeometry, edge.to).midX, frame(left, leftGeometry, edge.from).midX)
        }
        let (bottom, bottomGeometry) = try geometry("flowchart BT\n" + body)
        let (right, rightGeometry) = try geometry("flowchart RL\n" + body)
        XCTAssertLessThan(frame(bottom, bottomGeometry, "Check").midY, frame(bottom, bottomGeometry, "Start").midY)
        XCTAssertLessThan(frame(right, rightGeometry, "Check").midX, frame(right, rightGeometry, "Start").midX)
    }

    func testRoutesConnectTheirNodesAndAreOrthogonal() throws {
        let (diagram, geometry) = try geometry(sample)
        for (index, edge) in diagram.edges.enumerated() {
            let points = geometry.routes[index].points
            XCTAssertGreaterThanOrEqual(points.count, 2)
            guard let first = points.first, let last = points.last else { continue }
            XCTAssertTrue(frame(diagram, geometry, edge.from).insetBy(dx: -1, dy: -1).contains(first), "\(edge.from) start")
            XCTAssertTrue(frame(diagram, geometry, edge.to).insetBy(dx: -1, dy: -1).contains(last), "\(edge.to) end")
            for step in 1..<points.count {
                let dx = abs(points[step].x - points[step - 1].x)
                let dy = abs(points[step].y - points[step - 1].y)
                XCTAssertTrue(dx < 0.6 || dy < 0.6, "Segment \(step) of \(edge.from)→\(edge.to) is diagonal")
            }
        }
        let labelled = try XCTUnwrap(geometry.routes[1].labelCenter)
        XCTAssertGreaterThan(labelled.y, frame(diagram, geometry, "Check").maxY)
        XCTAssertLessThan(labelled.y, frame(diagram, geometry, "Save").minY)
    }

    func testSelfLoopAndEdgeToSubgraph() throws {
        let (diagram, geometry) = try geometry("graph TD\nA --> A\nA --> S\nsubgraph S\nB\nend")
        XCTAssertEqual(geometry.routes[0].points.count, 4)
        XCTAssertGreaterThan(geometry.routes[0].points[1].x, frame(diagram, geometry, "A").maxX)
        let cluster = geometry.clusterFrames[0]
        XCTAssertGreaterThan(cluster.minY, frame(diagram, geometry, "A").maxY)
        XCTAssertEqual(geometry.routes[1].points.last?.y ?? 0, cluster.minY, accuracy: 1)
    }

    func testLayoutIsDeterministic() throws {
        let first = try geometry(sample).1
        let second = try geometry(sample).1
        XCTAssertEqual(first.nodeFrames, second.nodeFrames)
        XCTAssertEqual(first.routes.map(\.points), second.routes.map(\.points))
        XCTAssertEqual(first.size, second.size)
    }

    func testWideDiagramsKeepTheirNaturalSize() throws {
        let source = "graph LR\n" + (0..<30).map { "N\($0)[Step number \($0)] --> N\($0 + 1)" }.joined(separator: "\n")
        let layout = try parse(source).layout(maxWidth: 300, style: AgentDiagramStyle())
        XCTAssertGreaterThan(layout.size.width, 300)
    }

    // MARK: Rendering

    func testRenderingDrawsInLightAndDarkThemes() throws {
        let source = """
        flowchart TD
            classDef hot fill:#f96,color:#000
            A[Rectangle] --> B(Rounded) --> C([Stadium]) --> D[[Sub]]
            D --> E[(Cylinder)] --o F((Circle)) --x G>Flag]
            G <--> H{Diamond} == thick ==> I{{Hexagon}}
            I -.-> J[/Lean/] --- K[\\Lean\\] --> L[/Trap\\] --> M[\\Trap/] --> N(((Double))):::hot
            subgraph S [A cluster]
                N --> O[Multi<br/>line label]
            end
        """
        for dark in [false, true] {
            let layout = try parse(source).layout(maxWidth: 600, style: diagramStyle(dark: dark))
            XCTAssertGreaterThan(layout.size.width, 40)
            XCTAssertGreaterThan(layout.size.height, 40)
            let ink = renderedInkPixels(layout)
            XCTAssertGreaterThan(ink, Int(layout.size.width * layout.size.height) / 50, "dark: \(dark)")
        }
    }

    func testEmptyFlowchartLaysOutToAnEmptyDrawing() throws {
        let layout = try parse("flowchart TD").layout(maxWidth: 400, style: AgentDiagramStyle())
        XCTAssertLessThanOrEqual(layout.size.width, AgentGraphScene.margin * 2 + 1)
        _ = renderedInkPixels(layout)
    }

    // MARK: Performance

    func testLargeGraphParsesAndLaysOutQuickly() throws {
        var generator = DiagramTestRandom(seed: 7)
        var lines = ["flowchart TD"]
        for index in 0..<150 { lines.append("n\(index)[Node \(index)]") }
        for _ in 0..<300 {
            let a = Int.random(in: 0..<150, using: &generator)
            let b = Int.random(in: 0..<150, using: &generator)
            lines.append("n\(min(a, b)) --> n\(max(a, b))")
        }
        let source = lines.joined(separator: "\n")
        _ = try AgentFlowchartDiagram(source: source).layout(maxWidth: 800, style: AgentDiagramStyle())
        let start = Date()
        let diagram = try AgentFlowchartDiagram(source: source)
        let layout = diagram.layout(maxWidth: 800, style: AgentDiagramStyle())
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(diagram.nodes.count, 150)
        XCTAssertEqual(diagram.edges.count, 300)
        XCTAssertGreaterThan(layout.size.width, 0)
        XCTAssertLessThan(elapsed, 0.1, "Took \(elapsed)s")
    }
}

/// A small deterministic random generator for reproducible tests.
struct DiagramTestRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
