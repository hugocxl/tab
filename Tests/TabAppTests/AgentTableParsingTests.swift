import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentTableParsingTests: XCTestCase {
    private struct Node: Codable, Equatable { var tag: String; var text: String }
    private struct Fixture: Decodable { var source: String; var blocks: [Node] }

    func testTableCellsAndBoundariesMatchSourceDOM() throws {
        _ = NSApplication.shared
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.oracle.utf8))
        for fixture in fixtures {
            XCTAssertEqual(nodes(AgentResponseParser.parse(fixture.source)), fixture.blocks, fixture.source)
        }
    }

    private func nodes(_ blocks: [AgentMarkdown.Block]) -> [Node] {
        let theme = AppTheme(systemIsDark: false)
        func inline(_ source: String) -> String { AgentMarkdown.inline(source, theme: theme).string }
        return blocks.flatMap { block -> [Node] in
            switch block {
            case .heading(let level, let text): return [Node(tag: "H\(level)", text: inline(text))]
            case .paragraph(let text): return [Node(tag: "P", text: inline(text))]
            case .quote(let text): return nodes(AgentResponseParser.parse(text))
            case .list(_, let text, _, _): return [Node(tag: "LI", text: inline(text))]
            case .table(let headers, let rows, _):
                return headers.map { Node(tag: "TH", text: inline($0)) } + rows.flatMap { $0.map { Node(tag: "TD", text: inline($0)) } }
            case .code(_, let text, _): return [Node(tag: "PRE", text: text)]
            case .divider: return [Node(tag: "HR", text: "")]
            default: return []
            }
        }
    }

    // Real ChatMarkdown DOM at source e5909e53, including list precedence and escaped code pipes.
    private static let oracle = ########"""
    [
      {
        "source": "A | B\n- | -\none | two",
        "blocks": [
          {
            "tag": "P",
            "text": "A | B"
          },
          {
            "tag": "LI",
            "text": "| - one | two"
          }
        ]
      },
      {
        "source": "| A | B |\n| :- | -: |\n| one | two |",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TH",
            "text": "B"
          },
          {
            "tag": "TD",
            "text": "one"
          },
          {
            "tag": "TD",
            "text": "two"
          }
        ]
      },
      {
        "source": "| A | B |\n| --- | --- |\nplain row\nnext row",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TH",
            "text": "B"
          },
          {
            "tag": "TD",
            "text": "plain row"
          },
          {
            "tag": "TD",
            "text": ""
          },
          {
            "tag": "TD",
            "text": "next row"
          },
          {
            "tag": "TD",
            "text": ""
          }
        ]
      },
      {
        "source": "| A | B |\n| --- | --- |\n# heading | text",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TH",
            "text": "B"
          },
          {
            "tag": "H1",
            "text": "heading | text"
          }
        ]
      },
      {
        "source": "| A | B |\n| --- | --- |\n> quote | text",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TH",
            "text": "B"
          },
          {
            "tag": "P",
            "text": "quote | text"
          }
        ]
      },
      {
        "source": "| A | B |\n| --- | --- |\n- item | text",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TH",
            "text": "B"
          },
          {
            "tag": "LI",
            "text": "item | text"
          }
        ]
      },
      {
        "source": "| A | B |\n| --- | --- |\n```text\ncode | here\n```",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TH",
            "text": "B"
          },
          {
            "tag": "PRE",
            "text": "code | here\n"
          }
        ]
      },
      {
        "source": "| A | B |\n| --- | --- |\n| `a|b` | c |",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TH",
            "text": "B"
          },
          {
            "tag": "TD",
            "text": "`a"
          },
          {
            "tag": "TD",
            "text": "b`"
          }
        ]
      },
      {
        "source": "| A | B |\n| --- | --- |\n| `a\\|b` | c |",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TH",
            "text": "B"
          },
          {
            "tag": "TD",
            "text": "a|b"
          },
          {
            "tag": "TD",
            "text": "c"
          }
        ]
      },
      {
        "source": "| A | B |\n| --- | --- |\n| one | two |\n\nparagraph",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TH",
            "text": "B"
          },
          {
            "tag": "TD",
            "text": "one"
          },
          {
            "tag": "TD",
            "text": "two"
          },
          {
            "tag": "P",
            "text": "paragraph"
          }
        ]
      },
      {
        "source": "A\n-\nbody",
        "blocks": [
          {
            "tag": "H2",
            "text": "A"
          },
          {
            "tag": "P",
            "text": "body"
          }
        ]
      },
      {
        "source": "| A |\n| - |\nbody",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TD",
            "text": "body"
          }
        ]
      },
      {
        "source": "A | B\n-|-\none | two",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TH",
            "text": "B"
          },
          {
            "tag": "TD",
            "text": "one"
          },
          {
            "tag": "TD",
            "text": "two"
          }
        ]
      },
      {
        "source": "| A | B |\n| --- | --- |\n2. item | text",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TH",
            "text": "B"
          },
          {
            "tag": "LI",
            "text": "item | text"
          }
        ]
      },
      {
        "source": "| A | B |\n| --- | --- |\n    indented | value",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TH",
            "text": "B"
          },
          {
            "tag": "PRE",
            "text": "indented | value\n"
          }
        ]
      },
      {
        "source": "| A | B |\n| --- | --- |\n---",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TH",
            "text": "B"
          },
          {
            "tag": "HR",
            "text": ""
          }
        ]
      },
      {
        "source": "| A | B |\n| --- | --- |\n| left\\\\| right |",
        "blocks": [
          {
            "tag": "TH",
            "text": "A"
          },
          {
            "tag": "TH",
            "text": "B"
          },
          {
            "tag": "TD",
            "text": "left\\"
          },
          {
            "tag": "TD",
            "text": "right"
          }
        ]
      }
    ]
    """########
}
