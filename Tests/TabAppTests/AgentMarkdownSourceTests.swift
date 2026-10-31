import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentMarkdownSourceTests: XCTestCase {
    private struct Node: Codable, Equatable { var tag: String; var text: String }
    private struct Fixture: Decodable { var source: String; var blocks: [Node] }

    func testBlockTextMatchesSourceForCRLFCRAndNulls() throws {
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.oracle.utf8))
        for fixture in fixtures {
            XCTAssertEqual(nodes(AgentResponseParser.parse(fixture.source)), fixture.blocks)
        }
    }

    func testStreamedCRBecomingCRLFDoesNotAddABlankCodeLine() throws {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: .zero)
        let theme = AppTheme(systemIsDark: false)
        for ending in ["\r", "\r\n"] {
            response.setContent("```text\r\nfirst" + ending + "second\r\n```", theme: theme)
            _ = response.height(for: 500)
            let code = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
            XCTAssertEqual(code.code, "first" + ending + "second\n")
        }
    }

    func testNestedBlocksRetainMixedSourceEndings() {
        let source = "> first\r> second\r\n> third\n\n- item\r  continuation\r\n  final"
        XCTAssertEqual(AgentResponseParser.parse(source), [
            .quote("first\rsecond\r\nthird"),
            .list("•", "item\rcontinuation\r\nfinal", 0, structure: .init(id: 4, parentID: nil, delimiter: "-", start: nil, number: nil))
        ])
    }

    private func nodes(_ blocks: [AgentMarkdown.Block]) -> [Node] {
        blocks.flatMap { block -> [Node] in
            switch block {
            case .heading(let level, let text): return [Node(tag: "H\(level)", text: text)]
            case .paragraph(let text): return [Node(tag: "P", text: text)]
            case .quote(let text): return nodes(AgentResponseParser.parse(text))
            case .list(_, let text, _, _): return [Node(tag: "LI", text: text)]
            case .table(let headers, let rows, _):
                return headers.map { Node(tag: "TH", text: $0) } + rows.flatMap { $0.map { Node(tag: "TD", text: $0) } }
            case .code(_, let text, _): return [Node(tag: "PRE", text: text)]
            default: return []
            }
        }
    }

    // Actual ChatMarkdown DOM captured from source e5909e53, including original code-node line endings.
    private static let oracle = #"""
    [
      {
        "source": "# Heading\n\nFirst line\nsecond line\n\n> Quote\n> continuation\n\n- Alpha\n- Beta\n\n| A | B |\n| --- | --- |\n| one | two |\n\n```text\nline one\nline two\n```",
        "blocks": [
          {
            "tag": "H1",
            "text": "Heading"
          },
          {
            "tag": "P",
            "text": "First line\nsecond line"
          },
          {
            "tag": "P",
            "text": "Quote\ncontinuation"
          },
          {
            "tag": "LI",
            "text": "Alpha"
          },
          {
            "tag": "LI",
            "text": "Beta"
          },
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
            "tag": "PRE",
            "text": "line one\nline two\n"
          }
        ]
      },
      {
        "source": "# Heading\r\rFirst line\rsecond line\r\r> Quote\r> continuation\r\r- Alpha\r- Beta\r\r| A | B |\r| --- | --- |\r| one | two |\r\r```text\rline one\rline two\r```",
        "blocks": [
          {
            "tag": "H1",
            "text": "Heading"
          },
          {
            "tag": "P",
            "text": "First line\rsecond line"
          },
          {
            "tag": "P",
            "text": "Quote\rcontinuation"
          },
          {
            "tag": "LI",
            "text": "Alpha"
          },
          {
            "tag": "LI",
            "text": "Beta"
          },
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
            "tag": "PRE",
            "text": "line one\rline two\n"
          }
        ]
      },
      {
        "source": "# Heading\r\n\r\nFirst line\r\nsecond line\r\n\r\n> Quote\r\n> continuation\r\n\r\n- Alpha\r\n- Beta\r\n\r\n| A | B |\r\n| --- | --- |\r\n| one | two |\r\n\r\n```text\r\nline one\r\nline two\r\n```",
        "blocks": [
          {
            "tag": "H1",
            "text": "Heading"
          },
          {
            "tag": "P",
            "text": "First line\r\nsecond line"
          },
          {
            "tag": "P",
            "text": "Quote\r\ncontinuation"
          },
          {
            "tag": "LI",
            "text": "Alpha"
          },
          {
            "tag": "LI",
            "text": "Beta"
          },
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
            "tag": "PRE",
            "text": "line one\r\nline two\n"
          }
        ]
      },
      {
        "source": "before\u0000after\n\n```text\ncode\u0000value\n```",
        "blocks": [
          {
            "tag": "P",
            "text": "before\ufffdafter"
          },
          {
            "tag": "PRE",
            "text": "code\ufffdvalue\n"
          }
        ]
      },
      {
        "source": "one\u0085two\u2028three\u2029four",
        "blocks": [
          {
            "tag": "P",
            "text": "one\u0085two\u2028three\u2029four"
          }
        ]
      }
    ]
    """#
}
