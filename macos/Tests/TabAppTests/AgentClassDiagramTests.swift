import AppKit
import XCTest
@testable import TabApp

final class AgentClassDiagramTests: XCTestCase {
    private let style = AgentDiagramStyle()

    private func parse(_ body: String) throws -> AgentClassDiagram {
        try AgentClassDiagram(source: "classDiagram\n" + body)
    }

    private func index(_ diagram: AgentClassDiagram, _ id: String) -> Int {
        diagram.classes.firstIndex { $0.id == id } ?? -1
    }

    // MARK: Grammar

    func testClassBodiesSplitFieldsAndMethods() throws {
        let diagram = try parse("""
            class BankAccount {
                +String owner
                -BigDecimal balance
                #int id
                ~internal() bool
                +deposit(amount) bool
                +withdrawal(amount)$
            }
            """)
        let account = diagram.classes[0]
        XCTAssertEqual(account.id, "BankAccount")
        XCTAssertEqual(account.fields, ["+String owner", "-BigDecimal balance", "#int id"])
        XCTAssertEqual(account.methods, ["~internal() : bool", "+deposit(amount) : bool", "+withdrawal(amount)"])
    }

    func testMemberLinesAddToClasses() throws {
        let diagram = try parse("""
            Animal : +int age
            Animal : +String gender
            Animal: +isMammal()
            Animal: +mate()
            """)
        XCTAssertEqual(diagram.classes.count, 1)
        XCTAssertEqual(diagram.classes[0].fields, ["+int age", "+String gender"])
        XCTAssertEqual(diagram.classes[0].methods, ["+isMammal()", "+mate()"])
    }

    func testAnnotationsInBothForms() throws {
        let diagram = try parse("""
            class Shape {
                <<interface>>
                +draw()
            }
            class Color
            <<enumeration>> Color
            """)
        XCTAssertEqual(diagram.classes.map(\.annotation), ["interface", "enumeration"])
        XCTAssertEqual(diagram.classes[0].methods, ["+draw()"])
    }

    func testGenericsDisplayWithAngleBrackets() throws {
        let diagram = try parse("""
            class Square~Shape~ {
                +List~int~ ids
                +get(int index) List~T~
            }
            Square~Shape~ <|-- Child
            """)
        XCTAssertEqual(diagram.classes[0].id, "Square")
        XCTAssertEqual(diagram.classes[0].label, "Square<Shape>")
        XCTAssertEqual(diagram.classes[0].fields, ["+List<int> ids"])
        XCTAssertEqual(diagram.classes[0].methods, ["+get(int index) : List<T>"])
        XCTAssertEqual(diagram.relations.first?.from, 0)
    }

    func testEveryRelationshipKind() throws {
        let diagram = try parse("""
            classA <|-- classB
            classC *-- classD
            classE o-- classF
            classG <-- classH
            classI -- classJ
            classK <.. classL
            classM <|.. classN
            classO .. classP
            classQ --|> classR
            classS --* classT
            classU --o classV
            classW --> classX
            classY ..> classZ
            classAA ..|> classAB
            """)
        let relations = diagram.relations
        XCTAssertEqual(relations.count, 14)
        XCTAssertEqual(relations.map(\.fromEnd), [.triangle, .filledDiamond, .hollowDiamond, .arrow, .none, .arrow, .triangle, .none, .none, .none, .none, .none, .none, .none])
        XCTAssertEqual(relations.map(\.toEnd), [.none, .none, .none, .none, .none, .none, .none, .none, .triangle, .filledDiamond, .hollowDiamond, .arrow, .arrow, .triangle])
        XCTAssertEqual(relations.map(\.dashed), [false, false, false, false, false, true, true, true, false, false, false, false, true, true])
        XCTAssertEqual(diagram.classes.count, 28)
    }

    func testCardinalitiesAndLabels() throws {
        let diagram = try parse("""
            Customer "1" --> "*" Ticket : buys
            Student "1..*" o-- "1" Course
            Galaxy --> Star : contains "many"
            """)
        let relations = diagram.relations
        XCTAssertEqual(relations[0].fromCardinality, "1")
        XCTAssertEqual(relations[0].toCardinality, "*")
        XCTAssertEqual(relations[0].label, "buys")
        XCTAssertEqual(relations[1].fromCardinality, "1..*")
        XCTAssertEqual(relations[1].toCardinality, "1")
        XCTAssertEqual(relations[1].fromEnd, .hollowDiamond)
        XCTAssertEqual(relations[2].label, "contains \"many\"")
        XCTAssertEqual(diagram.classes.map(\.id), ["Customer", "Ticket", "Student", "Course", "Galaxy", "Star"])
    }

    func testNamespacesAndDirection() throws {
        let diagram = try parse("""
            direction LR
            namespace Shapes {
                class Triangle
                class Rectangle {
                    +width
                }
            }
            class Outside
            """)
        XCTAssertEqual(diagram.direction, .leftToRight)
        XCTAssertEqual(diagram.classes.map(\.namespace), ["Shapes", "Shapes", nil])
        XCTAssertEqual(diagram.classes[1].fields, ["+width"])
    }

    func testStylingAndNotesAreIgnored() throws {
        let diagram = try parse("""
            class Duck:::highlighted
            class Goose["Big goose"]
            note for Duck "can fly"
            note "general"
            classDef highlighted fill:#f9f
            cssClass "Duck" highlighted
            style Duck fill:#f9f
            click Duck href "https://example.com"
            """)
        XCTAssertEqual(diagram.classes.map(\.id), ["Duck", "Goose"])
        XCTAssertEqual(diagram.classes[1].label, "Big goose")
    }

    // MARK: Errors

    func testUnclosedClassBodyReportsItsLine() {
        XCTAssertThrowsError(try parse("class A\nclass B {\n+x")) { error in
            XCTAssertEqual((error as? AgentDiagramError)?.line, 3)
        }
    }

    func testUnclosedNamespaceAndStrayBrace() {
        XCTAssertThrowsError(try parse("namespace N {\nclass A")) { error in
            XCTAssertEqual((error as? AgentDiagramError)?.line, 2)
        }
        XCTAssertThrowsError(try parse("class A\n}")) { error in
            XCTAssertEqual((error as? AgentDiagramError)?.line, 3)
        }
    }

    func testMalformedStatementsReportTheirLines() {
        XCTAssertThrowsError(try parse("class A\nA <|-- \nclass B")) { error in
            XCTAssertEqual((error as? AgentDiagramError)?.line, 3)
        }
        XCTAssertThrowsError(try parse("class A\n!!! nonsense")) { error in
            XCTAssertEqual((error as? AgentDiagramError)?.line, 3)
        }
        XCTAssertThrowsError(try parse("direction sideways")) { error in
            XCTAssertEqual((error as? AgentDiagramError)?.line, 2)
        }
        XCTAssertThrowsError(try AgentClassDiagram(source: "classDiagram"))
    }

    func testMalformedInputNeverCrashes() {
        let inputs = ["<<", "<<>>", "class", "class {", "A : ", "\"1\" -- \"2\"", "--", "..", "o--o", "A <|--|> B",
                      "namespace {", String(repeating: "A--", count: 500), "class A~", "class `odd name`"]
        for input in inputs {
            _ = try? parse(input).geometry(style: style)
        }
    }

    // MARK: Layout

    func testParentsSitAboveChildren() throws {
        let diagram = try parse("""
            Animal <|-- Duck
            Animal <|-- Fish
            Duck <|-- Mallard
            Zoo *-- Animal
            Fish ..|> Swimmer
            """)
        let geometry = diagram.geometry(style: style)
        let box = { geometry.boxes[self.index(diagram, $0)] }
        XCTAssertLessThan(box("Animal").maxY, box("Duck").minY)
        XCTAssertLessThan(box("Animal").maxY, box("Fish").minY)
        XCTAssertLessThan(box("Duck").maxY, box("Mallard").minY)
        XCTAssertLessThan(box("Zoo").maxY, box("Animal").minY)
        XCTAssertLessThan(box("Swimmer").maxY, box("Fish").minY)
    }

    func testBoxesDoNotOverlap() throws {
        var lines: [String] = []
        for index in 0..<24 {
            lines.append("class C\(index) {\n+field\(index) : String\n+method\(index)(x) int\n}")
            if index > 0 { lines.append("C\(index / 3) <|-- C\(index)") }
        }
        lines.append("C5 --> C1")
        lines.append("C7 ..> C7")
        let diagram = try parse(lines.joined(separator: "\n"))
        let geometry = diagram.geometry(style: style)
        XCTAssertEqual(geometry.boxes.count, 24)
        for first in geometry.boxes.indices {
            for second in geometry.boxes.indices where second > first {
                XCTAssertFalse(geometry.boxes[first].intersects(geometry.boxes[second]), "C\(first) overlaps C\(second)")
            }
        }
        for box in geometry.boxes {
            XCTAssertLessThanOrEqual(box.maxX, geometry.size.width)
            XCTAssertLessThanOrEqual(box.maxY, geometry.size.height)
        }
    }

    func testCyclesStillLayOut() throws {
        let diagram = try parse("A --> B\nB --> C\nC --> A")
        let geometry = diagram.geometry(style: style)
        XCTAssertEqual(Set(geometry.layers).count, 3)
    }

    func testLeftToRightPlacesLayersInColumns() throws {
        let diagram = try parse("direction LR\nBase <|-- Derived")
        let geometry = diagram.geometry(style: style)
        XCTAssertLessThan(geometry.boxes[0].maxX, geometry.boxes[1].minX)
        let bottomUp = try parse("direction BT\nBase <|-- Derived").geometry(style: style)
        XCTAssertGreaterThan(bottomUp.boxes[0].minY, bottomUp.boxes[1].maxY)
    }

    func testCompartmentsGrowWithMembers() throws {
        let diagram = try parse("class Empty\nclass Full {\n+a\n+b\n+c()\n}")
        let geometry = diagram.geometry(style: style)
        XCTAssertGreaterThan(geometry.boxes[1].height, geometry.boxes[0].height)
    }

    func testRenderingPaintsPixels() throws {
        let diagram = try parse("""
            title Shapes
            namespace Geometry {
                class Shape {
                    <<interface>>
                    +area() double
                }
                class Circle {
                    -double radius
                }
            }
            Shape <|.. Circle
            Circle "1" *-- "many" Point : center
            Circle o-- Style
            Circle ..> Canvas
            """)
        let painted = try AgentDiagramTextRendering.paintedPixels(diagram.layout(maxWidth: 600, style: style))
        XCTAssertGreaterThan(painted, 5_000)
    }
}
