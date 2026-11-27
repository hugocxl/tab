import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentHeadingParsingTests: XCTestCase {
    private struct Node: Codable, Equatable { var tag: String; var text: String }
    private struct Fixture: Decodable { var source: String; var blocks: [Node] }

    func testHeadingBoundariesMatchRenderedSourceDOM() throws {
        _ = NSApplication.shared
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.oracle.utf8))
        let theme = AppTheme(systemIsDark: false)
        for fixture in fixtures {
            let nodes = AgentResponseParser.parse(fixture.source).compactMap { block -> Node? in
                switch block {
                case .heading(let level, let text):
                    return Node(tag: "H\(level)", text: AgentMarkdown.inline(text, theme: theme).string)
                case .paragraph(let text): return Node(tag: "P", text: AgentMarkdown.inline(text, theme: theme).string)
                case .divider: return Node(tag: "HR", text: "")
                case .code(_, let text, _): return Node(tag: "PRE", text: text)
                default: return nil
                }
            }
            XCTAssertEqual(nodes, fixture.blocks, fixture.source)
        }
    }

    func testMultilineSetextRetainsSourceEndingsAndNestedListsStayLists() {
        XCTAssertEqual(AgentResponseParser.parse("first\rsecond\r\n="), [.heading(1, "first\rsecond")])
        XCTAssertEqual(AgentResponseParser.parse("- outer\n    - inner"), [.list("•", "outer", 0, structure: .init(id: 0, parentID: nil, delimiter: "-", start: nil, number: nil)), .list("◦", "inner", 1, structure: .init(id: 1, parentID: 0, delimiter: "-", start: nil, number: nil, ancestors: [false]))])
        XCTAssertEqual(AgentResponseParser.parse("    one\n\n    two\n\nafter"), [.code("", "one\n\ntwo\n", closed: true), .paragraph("after")])
    }

    // Captured from the real ChatMarkdown DOM at source e5909e53.
    private static let oracle = ########"""
    [
      {
        "source": "#",
        "blocks": [
          {
            "tag": "H1",
            "text": ""
          }
        ]
      },
      {
        "source": "##\tTabbed\t##",
        "blocks": [
          {
            "tag": "H2",
            "text": "Tabbed"
          }
        ]
      },
      {
        "source": "###     spaced     ###   ",
        "blocks": [
          {
            "tag": "H3",
            "text": "spaced"
          }
        ]
      },
      {
        "source": "#### ###",
        "blocks": [
          {
            "tag": "H4",
            "text": ""
          }
        ]
      },
      {
        "source": "## title#",
        "blocks": [
          {
            "tag": "H2",
            "text": "title#"
          }
        ]
      },
      {
        "source": "## title \\###",
        "blocks": [
          {
            "tag": "H2",
            "text": "title ###"
          }
        ]
      },
      {
        "source": "####### text",
        "blocks": [
          {
            "tag": "P",
            "text": "####### text"
          }
        ]
      },
      {
        "source": "first\nsecond\n=",
        "blocks": [
          {
            "tag": "H1",
            "text": "first second"
          }
        ]
      },
      {
        "source": "first\nsecond\n-",
        "blocks": [
          {
            "tag": "H2",
            "text": "first second"
          }
        ]
      },
      {
        "source": "Title\n=",
        "blocks": [
          {
            "tag": "H1",
            "text": "Title"
          }
        ]
      },
      {
        "source": "Title\n-",
        "blocks": [
          {
            "tag": "H2",
            "text": "Title"
          }
        ]
      },
      {
        "source": "Title\n  ==  ",
        "blocks": [
          {
            "tag": "H1",
            "text": "Title"
          }
        ]
      },
      {
        "source": "Title\n- - -",
        "blocks": [
          {
            "tag": "P",
            "text": "Title"
          },
          {
            "tag": "HR",
            "text": ""
          }
        ]
      },
      {
        "source": "   # indented",
        "blocks": [
          {
            "tag": "H1",
            "text": "indented"
          }
        ]
      },
      {
        "source": "    # code",
        "blocks": [
          {
            "tag": "PRE",
            "text": "# code\n"
          }
        ]
      },
      {
        "source": "# not a heading",
        "blocks": [
          {
            "tag": "P",
            "text": "# not a heading"
          }
        ]
      },
      {
        "source": "Title\n====\nnext",
        "blocks": [
          {
            "tag": "H1",
            "text": "Title"
          },
          {
            "tag": "P",
            "text": "next"
          }
        ]
      }
    ]
    """########
}
