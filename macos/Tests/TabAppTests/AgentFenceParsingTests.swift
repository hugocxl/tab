import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentFenceParsingTests: XCTestCase {
    private struct Node: Codable, Equatable { var tag: String; var text: String }
    private struct Fixture: Decodable { var source: String; var blocks: [Node] }

    func testImagesInsideFencesAndIndentedCodeStayCode() {
        for markdown in ["```markdown\n![shot](a.png)\n```", "```\nhttps://example.com/a.png\n", "    ![shot](a.png)"] {
            let parts = AgentResponsePart.partition(AgentResponseParser.parse(markdown), media: true)
            XCTAssertEqual(parts.map(\.kind), [1], markdown)
        }
    }

    func testFenceBodiesMatchSourceIncludingStreamingAndTabs() throws {
        _ = NSApplication.shared
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.oracle.utf8))
        let theme = AppTheme(systemIsDark: false)
        for fixture in fixtures {
            let actual = AgentResponseParser.parse(fixture.source).compactMap { block -> Node? in
                switch block {
                case .code(_, let code, _): return Node(tag: "PRE", text: code)
                case .paragraph(let text): return Node(tag: "P", text: AgentMarkdown.inline(text, theme: theme).string)
                default: return nil
                }
            }
            XCTAssertEqual(actual, fixture.blocks, fixture.source)
        }
    }

    func testIndentedFalseCloserDoesNotMarkShellCodeComplete() {
        XCTAssertEqual(AgentResponseParser.parse("```sh\necho safe\n    ```"),
                       [.code("sh", "echo safe\n    ```\n", closed: false)])
        XCTAssertEqual(AgentResponseParser.parse("```sh\necho safe\n    ```\n```"),
                       [.code("sh", "echo safe\n    ```\n", closed: true)])
    }

    func testFenceKindsForMathAndDiagrams() {
        XCTAssertEqual(AgentResponseParser.parse("```math\na^2\n```"), [.math("a^2")])
        XCTAssertEqual(AgentResponseParser.parse("```latex title=x\nb\n```"), [.math("b")])
        XCTAssertEqual(AgentResponseParser.parse("```mermaid\npie\n```"), [.diagram("pie\n")])
        XCTAssertEqual(AgentResponseParser.parse("```math\n\n```"), [.code("math", "", closed: true)],
                       "An empty math fence has nothing to typeset")
        XCTAssertEqual(AgentResponseParser.parse("```mermaidx\npie\n```"), [.code("mermaidx", "pie\n", closed: true)])
        XCTAssertEqual(AgentResponseParser.parse("    ```math\n    a\n    ```"), [.code("", "```math\na\n```\n", closed: true)],
                       "Indented code is never math")
    }

    // Real ChatMarkdown DOM at source e5909e53, including code-node trailing newlines.
    private static let oracle = ########"""
    [
      {
        "source": "  ```text\n  alpha\n beta\ngamma\n  ```",
        "blocks": [
          {
            "tag": "PRE",
            "text": "alpha\nbeta\ngamma\n"
          }
        ]
      },
      {
        "source": "```text\none\n    ```\ntwo\n```",
        "blocks": [
          {
            "tag": "PRE",
            "text": "one\n    ```\ntwo\n"
          }
        ]
      },
      {
        "source": "```bad`info\none\n```",
        "blocks": [
          {
            "tag": "P",
            "text": "```bad`info one"
          },
          {
            "tag": "PRE",
            "text": ""
          }
        ]
      },
      {
        "source": "~~~a`b\none\n~~~",
        "blocks": [
          {
            "tag": "PRE",
            "text": "one\n"
          }
        ]
      },
      {
        "source": "```\none\n````",
        "blocks": [
          {
            "tag": "PRE",
            "text": "one\n"
          }
        ]
      },
      {
        "source": "````\none\n```\ntwo\n````",
        "blocks": [
          {
            "tag": "PRE",
            "text": "one\n```\ntwo\n"
          }
        ]
      },
      {
        "source": "```\none\n``` trailing\ntwo\n```",
        "blocks": [
          {
            "tag": "PRE",
            "text": "one\n``` trailing\ntwo\n"
          }
        ]
      },
      {
        "source": "```\n\n```",
        "blocks": [
          {
            "tag": "PRE",
            "text": ""
          }
        ]
      },
      {
        "source": "  ```\n\talpha\n  ```",
        "blocks": [
          {
            "tag": "PRE",
            "text": "  alpha\n"
          }
        ]
      },
      {
        "source": "~~~\none\n```\ntwo\n~~~",
        "blocks": [
          {
            "tag": "PRE",
            "text": "one\n```\ntwo\n"
          }
        ]
      },
      {
        "source": "```\nhello",
        "blocks": [
          {
            "tag": "PRE",
            "text": "hello\n"
          }
        ]
      },
      {
        "source": "```\nhello\n",
        "blocks": [
          {
            "tag": "PRE",
            "text": "hello\n"
          }
        ]
      },
      {
        "source": "```\nhello\r",
        "blocks": [
          {
            "tag": "PRE",
            "text": "hello\n"
          }
        ]
      },
      {
        "source": "```\n\n\n```",
        "blocks": [
          {
            "tag": "PRE",
            "text": "\n\n"
          }
        ]
      },
      {
        "source": " ```\n \talpha\n ```",
        "blocks": [
          {
            "tag": "PRE",
            "text": "\talpha\n"
          }
        ]
      }
    ]
    """########
}
