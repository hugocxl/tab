import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentAdjacentLinkTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Link: Decodable { let text: String; let href: String; let icons: Int }
        let source: String
        let links: [Link]
        let markdown: String
    }

    func testAdjacentLinkSpansAndTableExportsMatchSource() throws {
        _ = NSApplication.shared
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.oracle.utf8))
        for fixture in fixtures {
            let blocks = AgentResponseParser.parse(fixture.source)
            let references = AgentMarkdownReferences.collect(blocks, parseRawHTML: true)
            let label = fixture.source.components(separatedBy: "\n\n")[0]
            let rendered = AgentMarkdown.inline(label, theme: AppTheme(systemIsDark: false), references: references)
            var links: [(String, String, Int)] = []
            rendered.enumerateAttribute(.agentExternalLinkIdentity, in: NSRange(location: 0, length: rendered.length)) { identity, range, _ in
                guard identity != nil, let url = rendered.attribute(.link, at: range.location, effectiveRange: nil) as? URL else { return }
                var icons = 0
                rendered.enumerateAttribute(.agentExternalLinkGroup, in: range) { value, _, _ in if value != nil { icons += 1 } }
                links.append(((rendered.string as NSString).substring(with: range), url.absoluteString, icons))
            }
            XCTAssertEqual(links.count, fixture.links.count, fixture.source)
            for (actual, expected) in zip(links, fixture.links) {
                XCTAssertEqual(actual.0, expected.text)
                XCTAssertEqual(actual.1, expected.href)
                XCTAssertEqual(actual.2, expected.icons)
            }
            XCTAssertEqual(AgentExternalLinkLayout.additionalWidth(rendered), Double(fixture.links.count) * 20.3, accuracy: 0.001)
            let response = AgentResponseView(frame: .zero)
            let suffix = fixture.source.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
            response.setContent("| Link |\n| --- |\n| " + label + " |\n\n" + suffix, theme: AppTheme(systemIsDark: false))
            _ = response.height(for: 420)
            let table = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseTable }.first)
            XCTAssertEqual(table.copyText(.markdown), fixture.markdown, fixture.source)
        }
    }

    // Real ChatMarkdown DOM and table serializer at source e5909e53.
    private static let oracle = ########"""
    [
      {
        "source": "[a](https://localhost)[b](https://localhost)",
        "links": [
          {
            "text": "a",
            "href": "https://localhost",
            "icons": 1
          },
          {
            "text": "b",
            "href": "https://localhost",
            "icons": 1
          }
        ],
        "markdown": "| Link |\n| --- |\n| [a](https://localhost)[b](https://localhost) |"
      },
      {
        "source": "[**a**](https://localhost)[*b*](https://localhost)",
        "links": [
          {
            "text": "a",
            "href": "https://localhost",
            "icons": 1
          },
          {
            "text": "b",
            "href": "https://localhost",
            "icons": 1
          }
        ],
        "markdown": "| Link |\n| --- |\n| [**a**](https://localhost)[*b*](https://localhost) |"
      },
      {
        "source": "[a](https://localhost) [b](https://localhost)",
        "links": [
          {
            "text": "a",
            "href": "https://localhost",
            "icons": 1
          },
          {
            "text": "b",
            "href": "https://localhost",
            "icons": 1
          }
        ],
        "markdown": "| Link |\n| --- |\n| [a](https://localhost) [b](https://localhost) |"
      },
      {
        "source": "[a](https://localhost)[b](https://other.local)",
        "links": [
          {
            "text": "a",
            "href": "https://localhost",
            "icons": 1
          },
          {
            "text": "b",
            "href": "https://other.local",
            "icons": 1
          }
        ],
        "markdown": "| Link |\n| --- |\n| [a](https://localhost)[b](https://other.local) |"
      },
      {
        "source": "[a][r][b][r]\n\n[r]: https://localhost",
        "links": [
          {
            "text": "a",
            "href": "https://localhost",
            "icons": 1
          },
          {
            "text": "b",
            "href": "https://localhost",
            "icons": 1
          }
        ],
        "markdown": "| Link |\n| --- |\n| [a](https://localhost)[b](https://localhost) |"
      }
    ]
    """########
}
