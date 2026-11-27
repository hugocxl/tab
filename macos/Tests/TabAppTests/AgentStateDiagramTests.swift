import AppKit
import XCTest
@testable import TabApp

final class AgentStateDiagramTests: XCTestCase {
    private func parse(_ source: String) throws -> AgentStateDiagram {
        try AgentStateDiagram(source: source)
    }

    private func assertError(_ source: String, line expected: Int?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try AgentStateDiagram(source: source), file: file, line: line) { error in
            guard let diagramError = error as? AgentDiagramError else {
                return XCTFail("Unexpected error \(error)", file: file, line: line)
            }
            XCTAssertFalse(diagramError.message.isEmpty, file: file, line: line)
            if let expected { XCTAssertEqual(diagramError.line, expected, diagramError.message, file: file, line: line) }
        }
    }

    private func geometry(_ diagram: AgentStateDiagram) -> AgentGraphScene.Geometry {
        diagram.scene.geometry(style: AgentDiagramStyle())
    }

    private func frame(_ diagram: AgentStateDiagram, _ geometry: AgentGraphScene.Geometry, _ id: String) -> CGRect {
        guard let index = diagram.states.firstIndex(where: { $0.id == id }) else { return .null }
        return geometry.nodeFrames[index]
    }

    private func startID(_ diagram: AgentStateDiagram, scope: Int? = nil) -> String? {
        diagram.states.first { $0.kind == .start && $0.scope == scope }?.id
    }

    // MARK: Parsing

    func testKeywordsAndHeaders() throws {
        XCTAssertEqual(AgentStateDiagram.keywords, ["statediagram", "statediagram-v2"])
        XCTAssertEqual(AgentDiagramSource.keyword(of: "stateDiagram-v2\n[*] --> A"), "statediagram-v2")
        XCTAssertEqual(try parse("stateDiagram\nA --> B").states.count, 2)
        XCTAssertEqual(try parse("stateDiagram-v2\nA --> B").states.count, 2)
        assertError("flowchart TD\nA --> B", line: 1)
        assertError("%% nothing", line: nil)
    }

    func testStateDeclarationsAndDescriptions() throws {
        let diagram = try parse("""
        stateDiagram-v2
            s1
            state "A long description" as s2
            s3 : Described
            s3 : on two lines
            state s4
            state s5 : inline text
        """)
        XCTAssertEqual(diagram.states.map(\.id), ["s1", "s2", "s3", "s4", "s5"])
        XCTAssertEqual(diagram.state("s1")?.label, "s1")
        XCTAssertEqual(diagram.state("s2")?.label, "A long description")
        XCTAssertEqual(diagram.state("s3")?.label, "Described\non two lines")
        XCTAssertEqual(diagram.state("s5")?.label, "inline text")
        XCTAssertTrue(diagram.states.allSatisfy { $0.kind == .state })
    }

    func testTransitionsWithLabels() throws {
        let diagram = try parse("""
        stateDiagram-v2
            Still --> Moving : push it
            Moving --> Still: stop
            Moving --> Crash
            Crash --> Done : a: b
        """)
        XCTAssertEqual(diagram.transitions.map { "\($0.from)>\($0.to)" }, ["Still>Moving", "Moving>Still", "Moving>Crash", "Crash>Done"])
        XCTAssertEqual(diagram.transitions.map(\.label), ["push it", "stop", nil, "a: b"])
    }

    func testStartAndEndMarkersAreScoped() throws {
        let diagram = try parse("""
        stateDiagram-v2
            [*] --> A
            A --> [*]
            state A {
                [*] --> inner
                inner --> [*]
            }
            [*] --> B
        """)
        let starts = diagram.states.filter { $0.kind == .start }
        let ends = diagram.states.filter { $0.kind == .end }
        XCTAssertEqual(starts.count, 2, "One start per scope")
        XCTAssertEqual(ends.count, 2)
        XCTAssertEqual(Set(starts.map(\.scope)), [nil, 0])
        XCTAssertEqual(diagram.transitions.filter { $0.from == starts[0].id }.count, 2, "Root [*] is shared")
    }

    func testCompositeStatesNest() throws {
        let diagram = try parse("""
        stateDiagram-v2
            [*] --> First
            state First {
                [*] --> second
                state second {
                    [*] --> third
                }
            }
            First --> Last
        """)
        XCTAssertEqual(diagram.composites.map(\.id), ["First", "second"])
        XCTAssertNil(diagram.composites[0].parent)
        XCTAssertEqual(diagram.composites[1].parent, 0)
        XCTAssertNil(diagram.state("First"), "Composite states are clusters, not nodes")
        XCTAssertEqual(diagram.state("third")?.scope, 1)
        let scene = diagram.scene
        XCTAssertTrue(scene.edges.contains { $0.to == .cluster(0) })
        XCTAssertTrue(scene.edges.contains { $0.from == .cluster(0) })
    }

    func testCompositeWithDescription() throws {
        let diagram = try parse("""
        stateDiagram-v2
            state "Working hard" as Work {
                a --> b
            }
        """)
        XCTAssertEqual(diagram.composites.first?.title, "Working hard")
    }

    func testForkJoinAndChoice() throws {
        let diagram = try parse("""
        stateDiagram-v2
            state fork_state <<fork>>
            state join_state <<join>>
            state if_state <<choice>>
            state alt [[choice]]
            [*] --> fork_state
            fork_state --> A
            fork_state --> B
            A --> join_state
            B --> join_state
            join_state --> if_state
            if_state --> C : yes
            if_state --> alt
        """)
        XCTAssertEqual(diagram.state("fork_state")?.kind, .fork)
        XCTAssertEqual(diagram.state("join_state")?.kind, .join)
        XCTAssertEqual(diagram.state("if_state")?.kind, .choice)
        XCTAssertEqual(diagram.state("alt")?.kind, .choice)
        let scene = diagram.scene
        let forkIndex = try XCTUnwrap(diagram.states.firstIndex { $0.id == "fork_state" })
        XCTAssertEqual(scene.nodes[forkIndex].shape, .forkBar)
        let forkFrame = geometry(diagram).nodeFrames[forkIndex]
        XCTAssertGreaterThan(forkFrame.width, forkFrame.height * 4)
        let sideways = try parse("stateDiagram-v2\ndirection LR\nstate f <<fork>>\n[*] --> f\nf --> A")
        let sidewaysFrame = frame(sideways, geometry(sideways), "f")
        XCTAssertGreaterThan(sidewaysFrame.height, sidewaysFrame.width * 4, "Bars run across the flow")
    }

    func testNotes() throws {
        let diagram = try parse("""
        stateDiagram-v2
            A --> B
            note right of A : Inline note
            note left of B
                First line
                Second line
            end note
            note "Floating" as N1
        """)
        let notes = diagram.states.filter { $0.kind == .note }
        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(notes[0].label, "Inline note")
        XCTAssertEqual(notes[0].noteTarget, "A")
        XCTAssertTrue(notes[0].noteOnRight)
        XCTAssertEqual(notes[1].label, "First line\nSecond line")
        XCTAssertEqual(notes[1].noteTarget, "B")
        XCTAssertFalse(notes[1].noteOnRight)
        XCTAssertEqual(notes[2].label, "Floating")
        XCTAssertNil(notes[2].noteTarget)
    }

    func testConcurrentRegions() throws {
        let diagram = try parse("""
        stateDiagram-v2
            [*] --> Active
            state Active {
                [*] --> NumOff
                NumOff --> NumOn : press
                --
                [*] --> CapsOff
                CapsOff --> CapsOn : press
                --
                [*] --> ScrollOff
            }
        """)
        let regions = diagram.composites.enumerated().filter { $0.element.isRegion }
        XCTAssertEqual(regions.count, 3)
        XCTAssertTrue(regions.allSatisfy { $0.element.parent == 0 })
        XCTAssertEqual(diagram.state("NumOff")?.scope, regions[0].offset)
        XCTAssertEqual(diagram.state("CapsOff")?.scope, regions[1].offset)
        XCTAssertEqual(diagram.state("ScrollOff")?.scope, regions[2].offset)
        XCTAssertEqual(diagram.states.filter { $0.kind == .start }.count, 4, "Each region has its own start")
    }

    func testDirectionAndComments() throws {
        let diagram = try parse("""
        %% leading comment
        stateDiagram-v2
            direction LR
            %% a comment
            A --> B %% trailing comment
            state C {
                direction TB
                c1 --> c2
            }
        """)
        XCTAssertEqual(diagram.direction, .leftToRight)
        XCTAssertEqual(diagram.composites.first?.direction, .topToBottom)
        XCTAssertEqual(diagram.transitions.count, 2)
        XCTAssertEqual(diagram.states.map(\.id), ["A", "B", "c1", "c2"])
    }

    func testClassDefinitions() throws {
        let diagram = try parse("""
        stateDiagram-v2
            classDef bad fill:#f00,color:white
            A --> B:::bad
            class A bad
            C:::bad
            hide empty description
        """)
        XCTAssertEqual(diagram.state("A")?.style.fill, AgentDiagramColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(diagram.state("B")?.style.fill, AgentDiagramColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(diagram.state("C")?.style.text, AgentDiagramColor(red: 1, green: 1, blue: 1))
    }

    func testErrorsReportLines() {
        assertError("stateDiagram-v2\nA --> B\n}", line: 3)
        assertError("stateDiagram-v2\nstate A {\nB --> C", line: 3)
        assertError("stateDiagram-v2\nnote right of A\ntext", line: 3)
        assertError("stateDiagram-v2\nA --> B\n--", line: 3)
        assertError("stateDiagram-v2\nA --> B\nthis is not valid", line: 3)
        assertError("stateDiagram-v2\n\nA --> bad state", line: 3)
        assertError("stateDiagram-v2\nnote above A : x", line: 2)
        assertError("stateDiagram-v2\ndirection diagonal", line: 2)
    }

    func testHostileInputNeverCrashes() {
        var generator = DiagramTestRandom(seed: 9)
        let alphabet = Array("AB[*]-->:{}<>\"note right of end state fork choice\n --%;")
        for _ in 0..<300 {
            let length = Int.random(in: 0..<120, using: &generator)
            let body = String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
            if let diagram = try? AgentStateDiagram(source: "stateDiagram-v2\n" + body) {
                _ = diagram.scene.geometry(style: AgentDiagramStyle())
            }
        }
    }

    // MARK: Layout

    private let sample = """
    stateDiagram-v2
        [*] --> Still
        Still --> Moving : push
        Moving --> Crash
        Crash --> [*]
        note right of Crash : Ouch
        state Moving {
            [*] --> Slow
            Slow --> Fast
        }
    """

    func testTransitionsFlowDownward() throws {
        let diagram = try parse(sample)
        let geometry = geometry(diagram)
        let start = try XCTUnwrap(startID(diagram))
        XCTAssertLessThan(frame(diagram, geometry, start).maxY, frame(diagram, geometry, "Still").minY)
        let moving = geometry.clusterFrames[0]
        XCTAssertGreaterThan(moving.minY, frame(diagram, geometry, "Still").maxY)
        XCTAssertGreaterThan(frame(diagram, geometry, "Crash").minY, moving.maxY)
        XCTAssertTrue(moving.contains(frame(diagram, geometry, "Slow")))
        XCTAssertTrue(moving.contains(frame(diagram, geometry, "Fast")))
        let end = try XCTUnwrap(diagram.states.first { $0.kind == .end }?.id)
        XCTAssertGreaterThan(frame(diagram, geometry, end).minY, frame(diagram, geometry, "Crash").maxY)
    }

    func testNoteSitsBesideItsState() throws {
        let diagram = try parse(sample)
        let geometry = geometry(diagram)
        let note = try XCTUnwrap(diagram.states.firstIndex { $0.kind == .note })
        let noteFrame = geometry.nodeFrames[note]
        let crash = frame(diagram, geometry, "Crash")
        XCTAssertGreaterThan(noteFrame.minX, crash.maxX)
        XCTAssertEqual(noteFrame.midY, crash.midY, accuracy: 1)
        let connector = try XCTUnwrap(geometry.routes.last)
        XCTAssertEqual(connector.points.count, 2)
    }

    func testRegionsSitSideBySideWithoutOverlap() throws {
        let diagram = try parse("""
        stateDiagram-v2
            direction LR
            [*] --> Active
            state Active {
                [*] --> NumOff
                NumOff --> NumOn
                --
                [*] --> CapsOff
                CapsOff --> CapsOn
            }
        """)
        let geometry = geometry(diagram)
        let regions = diagram.composites.indices.filter { diagram.composites[$0].isRegion }
        XCTAssertEqual(regions.count, 2)
        let first = geometry.clusterFrames[regions[0]]
        let second = geometry.clusterFrames[regions[1]]
        XCTAssertFalse(first.intersects(second))
        XCTAssertEqual(first.minY, second.minY, accuracy: 1, "Regions share a row")
        XCTAssertTrue(geometry.clusterFrames[0].contains(first))
        XCTAssertTrue(first.contains(frame(diagram, geometry, "NumOn")))
        XCTAssertTrue(second.contains(frame(diagram, geometry, "CapsOn")))
        XCTAssertGreaterThan(frame(diagram, geometry, "NumOn").minX, frame(diagram, geometry, "NumOff").maxX, "Regions keep the LR flow")
    }

    func testStatesNeverOverlap() throws {
        let diagram = try parse(sample + "\n" + (0..<15).map { "Still --> S\($0)" }.joined(separator: "\n"))
        let frames = geometry(diagram).nodeFrames
        for i in frames.indices {
            for j in frames.indices where j > i {
                XCTAssertFalse(frames[i].insetBy(dx: 0.5, dy: 0.5).intersects(frames[j]), "\(i) overlaps \(j)")
            }
        }
    }

    func testLayoutIsDeterministic() throws {
        let first = geometry(try parse(sample))
        let second = geometry(try parse(sample))
        XCTAssertEqual(first.nodeFrames, second.nodeFrames)
        XCTAssertEqual(first.clusterFrames, second.clusterFrames)
        XCTAssertEqual(first.routes.map(\.points), second.routes.map(\.points))
    }

    // MARK: Rendering

    func testRenderingDrawsInLightAndDarkThemes() throws {
        let source = sample + """

            state fork_state <<fork>>
            Still --> fork_state
            fork_state --> X
            state c <<choice>>
            X --> c
            c --> Still : retry
            c --> [*]
        """
        for dark in [false, true] {
            let layout = try parse(source).layout(maxWidth: 500, style: diagramStyle(dark: dark))
            XCTAssertGreaterThan(layout.size.height, 100)
            XCTAssertGreaterThan(renderedInkPixels(layout), Int(layout.size.width * layout.size.height) / 50, "dark: \(dark)")
        }
    }
}
