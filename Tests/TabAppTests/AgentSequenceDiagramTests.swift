import AppKit
import XCTest
@testable import TabApp

final class AgentSequenceDiagramTests: XCTestCase {
    private let style = AgentDiagramStyle()

    private func parse(_ body: String) throws -> AgentSequenceDiagram {
        try AgentSequenceDiagram(source: "sequenceDiagram\n" + body)
    }

    private func parseError(_ body: String) -> AgentDiagramError? {
        do {
            _ = try parse(body)
            return nil
        } catch {
            return error as? AgentDiagramError
        }
    }

    // MARK: Grammar

    func testDeclaredParticipantsKeepOrderAliasesAndKinds() throws {
        let diagram = try parse("""
            participant B as Bob
            actor A as Alice
            participant C
            A->>B: hi
            """)
        XCTAssertEqual(diagram.participants.map(\.id), ["B", "A", "C"])
        XCTAssertEqual(diagram.participants.map(\.label), ["Bob", "Alice", "C"])
        XCTAssertEqual(diagram.participants.map(\.kind), [.participant, .actor, .participant])
    }

    func testMessagesCreateImplicitParticipantsInOrderOfAppearance() throws {
        let diagram = try parse("""
            Client->>Server: request
            Server->>Database: query
            Database-->>Server: rows
            """)
        XCTAssertEqual(diagram.participants.map(\.id), ["Client", "Server", "Database"])
        XCTAssertEqual(diagram.messages.map(\.from), [0, 1, 2])
        XCTAssertEqual(diagram.messages.map(\.to), [1, 2, 1])
        XCTAssertEqual(diagram.messages.map(\.text), ["request", "query", "rows"])
    }

    func testEveryArrowParses() throws {
        let diagram = try parse("""
            A->B: solid
            A-->B: dotted
            A->>B: arrow
            A-->>B: dotted arrow
            A-xB: cross
            A--xB: dotted cross
            A-)B: async
            A--)B: dotted async
            A<<->>B: both
            A<<-->>B: dotted both
            """)
        let messages = diagram.messages
        XCTAssertEqual(messages.count, 10)
        XCTAssertEqual(messages.map(\.head), [.none, .none, .filled, .filled, .cross, .cross, .open, .open, .filled, .filled])
        XCTAssertEqual(messages.map(\.dashed), [false, true, false, true, false, true, false, true, false, true])
        XCTAssertEqual(messages.map(\.bidirectional), [false, false, false, false, false, false, false, false, true, true])
        XCTAssertEqual(diagram.participants.map(\.id), ["A", "B"])
    }

    func testActivationSuffixesAndStatements() throws {
        let diagram = try parse("""
            A->>+B: start
            B-->>-A: done
            activate A
            deactivate A
            """)
        let messages = diagram.messages
        XCTAssertTrue(messages[0].activatesTarget)
        XCTAssertFalse(messages[0].deactivatesSource)
        XCTAssertTrue(messages[1].deactivatesSource)
        XCTAssertEqual(messages[1].from, 1)
        XCTAssertEqual(diagram.events.suffix(2), [.activate(0), .deactivate(0)])
    }

    func testNotesInEveryPlacement() throws {
        let diagram = try parse("""
            participant A
            participant B
            Note left of A: left
            note right of B : right
            Note over A: one
            Note over A,B: shared
            """)
        let notes: [AgentSequenceDiagram.Note] = diagram.events.compactMap {
            if case let .note(note) = $0 { return note }
            return nil
        }
        XCTAssertEqual(notes.map(\.placement), [.leftOf, .rightOf, .over, .over])
        XCTAssertEqual(notes.map(\.participants), [[0], [1], [0], [0, 1]])
        XCTAssertEqual(notes.map(\.text), ["left", "right", "one", "shared"])
    }

    func testFramesAndSections() throws {
        let diagram = try parse("""
            loop Every minute
              A->>B: ping
            end
            alt ok
              B->>A: yes
            else failed
              B->>A: no
            end
            opt maybe
              A->>B: extra
            end
            par first
              A->>B: one
            and second
              A->>C: two
            end
            critical connect
              A->>B: open
            option timeout
              A->>A: retry
            end
            break stop
              A->>B: abort
            end
            rect rgb(200, 220, 255)
              A->>B: tinted
            end
            """)
        let starts: [AgentSequenceDiagram.FrameKind] = diagram.events.compactMap {
            if case let .frameStart(kind, _) = $0 { return kind }
            return nil
        }
        XCTAssertEqual(starts, [.loop, .alt, .opt, .par, .critical, .breakFrame, .rect])
        let sections: [String] = diagram.events.compactMap {
            if case let .frameSection(label) = $0 { return label }
            return nil
        }
        XCTAssertEqual(sections, ["failed", "second", "timeout"])
        XCTAssertEqual(diagram.events.filter { $0 == .frameEnd }.count, 7)
        XCTAssertTrue(diagram.events.contains(.frameStart(.loop, "Every minute")))
        XCTAssertTrue(diagram.events.contains(.frameStart(.rect, "")))
    }

    func testAutonumberWithStartStepAndOff() throws {
        let diagram = try parse("""
            A->>B: unnumbered
            autonumber 10 5
            A->>B: ten
            B->>A: fifteen
            autonumber off
            A->>B: none
            autonumber
            A->>B: one
            """)
        XCTAssertEqual(diagram.messages.map(\.number), [nil, 10, 15, nil, 1])
    }

    func testCommentsTitleAndAccessibilityLinesAreSkipped() throws {
        let diagram = try AgentSequenceDiagram(source: """
            %%{init: {"theme": "dark"}}%%
            sequenceDiagram
            %% a comment
            title Checkout flow
            accTitle: Accessible
            accDescr: Description
            A->>B: pay
            """)
        XCTAssertEqual(diagram.title, "Checkout flow")
        XCTAssertEqual(diagram.messages.count, 1)
    }

    func testFrontMatterTitle() throws {
        let diagram = try AgentSequenceDiagram(source: "---\ntitle: From front matter\n---\nsequenceDiagram\nA->>B: x")
        XCTAssertEqual(diagram.title, "From front matter")
    }

    func testBoxesGroupParticipantsAndDropColors() throws {
        let diagram = try parse("""
            box Aqua Frontend
              participant W as Web
              participant M as Mobile
            end
            box rgb(10, 20, 30) Backend services
              participant API
            end
            participant Outside
            W->>API: call
            """)
        XCTAssertEqual(diagram.boxes.map(\.label), ["Frontend", "Backend services"])
        XCTAssertEqual(diagram.boxes.map(\.participants), [[0, 1], [2]])
        XCTAssertNil(diagram.participants[3].box)
        let geometry = diagram.geometry(style: style)
        XCTAssertEqual(geometry.boxRects.count, 2)
        XCTAssertTrue(geometry.boxRects[0].contains(geometry.headerRects[0]))
        XCTAssertTrue(geometry.boxRects[0].contains(geometry.headerRects[1]))
        XCTAssertFalse(geometry.boxRects[0].intersects(geometry.headerRects[3]))
    }

    func testCreateAndDestroyAreSafe() throws {
        let diagram = try parse("""
            A->>B: hello
            create participant C as Carol
            B->>C: spawn
            destroy C
            C->>B: bye
            """)
        XCTAssertEqual(diagram.participants.map(\.label), ["A", "B", "Carol"])
        XCTAssertEqual(diagram.messages.count, 3)
    }

    func testParticipantMetadataIsIgnored() throws {
        let diagram = try parse("participant DB@{ \"type\" : \"database\" } as Store\nDB->>DB: vacuum")
        XCTAssertEqual(diagram.participants.map(\.id), ["DB"])
        XCTAssertEqual(diagram.participants[0].label, "Store")
    }

    // MARK: Errors

    func testUnrecognizedStatementReportsItsLine() {
        let error = parseError("A->>B: ok\nthis is not valid\nB->>A: ok")
        XCTAssertEqual(error?.line, 3)
    }

    func testUnclosedFrameReportsTheOpeningLine() {
        let error = parseError("A->>B: ok\nloop forever\nA->>B: again")
        XCTAssertEqual(error?.line, 3)
        XCTAssertTrue(error?.message.contains("loop") == true)
    }

    func testEndWithoutBlockIsAnError() {
        XCTAssertEqual(parseError("A->>B: ok\nend")?.line, 3)
    }

    func testElseOutsideAltIsAnError() {
        XCTAssertEqual(parseError("loop x\nelse y\nend")?.line, 3)
    }

    func testMissingReceiverIsAnError() {
        XCTAssertEqual(parseError("A->>: nobody")?.line, 2)
    }

    func testUnclosedBoxIsAnError() {
        XCTAssertEqual(parseError("box Group\nparticipant A")?.line, 2)
    }

    func testWrongHeaderAndEmptySource() {
        XCTAssertThrowsError(try AgentSequenceDiagram(source: "graph TD\nA-->B"))
        XCTAssertThrowsError(try AgentSequenceDiagram(source: "   \n%% nothing\n"))
        XCTAssertThrowsError(try AgentSequenceDiagram(source: "sequenceDiagram\n"))
    }

    func testMalformedInputNeverCrashes() {
        let inputs = [
            "->>", "A-", "<<", "A<<->>", "Note", "Note over", "Note over :", "Note sideways of A: x",
            "participant", "participant  as X", "autonumber x y", "activate", "box", "A->>+", "::::",
            String(repeating: "loop x\n", count: 40), String(repeating: "-", count: 3_000),
            String(repeating: "A->>B: \u{0}\n", count: 50), "rect", "par\nand\nend\nend",
        ]
        for input in inputs {
            _ = try? AgentSequenceDiagram(source: "sequenceDiagram\n" + input)
        }
    }

    func testTooManyParticipantsIsAnError() {
        let body = (0...AgentSequenceDiagram.maxParticipants).map { "participant P\($0)" }.joined(separator: "\n")
        XCTAssertNotNil(parseError(body))
    }

    // MARK: Layout

    func testParticipantsAreOrderedLeftToRightInDeclarationOrder() throws {
        let diagram = try parse("participant Zed\nparticipant Amy\nparticipant Moe\nMoe->>Zed: x")
        let geometry = diagram.geometry(style: style)
        XCTAssertEqual(geometry.centers, geometry.centers.sorted())
        XCTAssertEqual(Set(geometry.centers).count, 3)
        for (left, right) in zip(geometry.headerRects, geometry.headerRects.dropFirst()) {
            XCTAssertLessThanOrEqual(left.maxX, right.minX)
        }
    }

    func testMessagesAreOrderedTopToBottom() throws {
        let diagram = try parse("""
            A->>B: one
            loop again
              B->>C: two
              C->>C: self
            end
            Note over A,C: note
            C-->>A: three
            """)
        let geometry = diagram.geometry(style: style)
        let ys = geometry.messages.map(\.y)
        XCTAssertEqual(ys.count, 4)
        XCTAssertEqual(ys, ys.sorted())
        XCTAssertEqual(Set(ys).count, 4)
        XCTAssertTrue(geometry.messages[2].isSelf)
        XCTAssertGreaterThan(geometry.footerRects[0].minY, ys.last ?? 0)
    }

    func testLongLabelsWidenTheGap() throws {
        let short = try parse("A->>B: hi").geometry(style: style)
        let long = try parse("A->>B: \(String(repeating: "a long message label ", count: 6))").geometry(style: style)
        XCTAssertGreaterThan(long.centers[1] - long.centers[0], short.centers[1] - short.centers[0])
        let label = long.messages[0].labelRect
        XCTAssertGreaterThanOrEqual(label.minX, long.centers[0])
        XCTAssertLessThanOrEqual(label.maxX, long.centers[1])
    }

    func testMultiLineLabelsAreTaller() throws {
        let single = try parse("A->>B: one").geometry(style: style)
        let multi = try parse("A->>B: one<br/>two<br>three").geometry(style: style)
        XCTAssertGreaterThan(multi.messages[0].labelRect.height, single.messages[0].labelRect.height * 2)
    }

    func testActivationBarsNest() throws {
        let diagram = try parse("""
            A->>+B: outer
            A->>+B: inner
            B-->>-A: inner done
            B-->>-A: outer done
            """)
        let geometry = diagram.geometry(style: style)
        XCTAssertEqual(geometry.activations.count, 2)
        let inner = try XCTUnwrap(geometry.activations.first { $0.level == 2 })
        let outer = try XCTUnwrap(geometry.activations.first { $0.level == 1 })
        XCTAssertEqual(inner.participant, 1)
        XCTAssertGreaterThan(inner.rect.minY, outer.rect.minY)
        XCTAssertLessThan(inner.rect.maxY, outer.rect.maxY)
        XCTAssertGreaterThan(inner.rect.minX, outer.rect.minX)
        // Messages end at the bar's edge, not the lifeline.
        XCTAssertEqual(geometry.messages[1].endX, inner.rect.minX, accuracy: 0.5)
    }

    func testUnbalancedActivationsCloseAtTheEnd() throws {
        let diagram = try parse("activate A\nA->>B: x\ndeactivate B\ndeactivate B")
        let geometry = diagram.geometry(style: style)
        XCTAssertEqual(geometry.activations.count, 1)
        XCTAssertLessThanOrEqual(geometry.activations[0].rect.maxY, geometry.footerRects[0].minY)
    }

    func testNestedFramesContainTheirChildren() throws {
        let diagram = try parse("""
            loop outer
              alt inner
                A->>B: x
              else other
                B->>C: y
              end
            end
            """)
        let geometry = diagram.geometry(style: style)
        let outer = try XCTUnwrap(geometry.frames.first { $0.kind == .loop })
        let inner = try XCTUnwrap(geometry.frames.first { $0.kind == .alt })
        XCTAssertEqual(outer.depth, 0)
        XCTAssertEqual(inner.depth, 1)
        XCTAssertTrue(outer.rect.contains(inner.rect))
        XCTAssertGreaterThan(inner.rect.minX, outer.rect.minX)
        XCTAssertEqual(inner.sections.map(\.label), ["other"])
        for message in geometry.messages {
            XCTAssertTrue(inner.rect.minY < message.y && message.y < inner.rect.maxY)
        }
    }

    func testNotesSitBesideTheirParticipant() throws {
        let diagram = try parse("participant A\nparticipant B\nNote left of A: left side\nNote right of B: right side")
        let geometry = diagram.geometry(style: style)
        XCTAssertLessThan(geometry.notes[0].rect.maxX, geometry.centers[0])
        XCTAssertGreaterThan(geometry.notes[1].rect.minX, geometry.centers[1])
        XCTAssertGreaterThanOrEqual(geometry.notes[0].rect.minX, 0)
        XCTAssertLessThanOrEqual(geometry.notes[1].rect.maxX, geometry.size.width)
    }

    func testLayoutIsDeterministicAndKeepsNaturalWidth() throws {
        let diagram = try parse((0..<12).map { "P\($0)->>P\($0 + 1): message \($0)" }.joined(separator: "\n"))
        let first = diagram.layout(maxWidth: 200, style: style)
        let second = diagram.layout(maxWidth: 200, style: style)
        XCTAssertEqual(first.size, second.size)
        XCTAssertGreaterThan(first.size.width, 200)
    }

    // MARK: Rendering and performance

    func testRenderingPaintsPixels() throws {
        let diagram = try parse("""
            title Demo
            box Team
              actor U as User
            end
            participant S as Service
            autonumber
            U->>+S: request
            loop retry
              S-xS: fail
            end
            Note over U,S: shared note
            rect rgb(1,2,3)
              S--)U: async
            end
            S-->>-U: response
            """)
        let painted = try AgentDiagramTextRendering.paintedPixels(diagram.layout(maxWidth: 600, style: style))
        XCTAssertGreaterThan(painted, 500)
    }

    func testSixtyMessagesParseAndLayOutQuickly() throws {
        var lines = ["sequenceDiagram", "autonumber"]
        for index in 0..<60 {
            let from = "P\(index % 6)"
            let to = "P\((index * 7 + 3) % 6)"
            if index % 10 == 0 { lines.append("loop round \(index)") }
            lines.append("\(from)->>\(to): message number \(index) with some text")
            if index % 10 == 9 { lines.append("end") }
        }
        let source = lines.joined(separator: "\n")
        _ = try AgentSequenceDiagram(source: source).geometry(style: style)
        let start = Date()
        let diagram = try AgentSequenceDiagram(source: source)
        let geometry = diagram.geometry(style: style)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(geometry.messages.count, 60)
        XCTAssertLessThan(elapsed, 0.05)
    }

    // MARK: Shared text helpers

    func testLabelLinesSplitOnBreaksAndDecodeEntities() {
        XCTAssertEqual(AgentDiagramText.lines("a<br/>b<br>c\\nd"), ["a", "b", "c", "d"])
        XCTAssertEqual(AgentDiagramText.lines("x #quot;y#quot; &lt;z&gt;"), ["x \"y\" <z>"])
        XCTAssertEqual(AgentDiagramText.lines(String(repeating: "a", count: 1_000)).first?.count, AgentDiagramText.maxLabelCharacters + 1)
    }
}
