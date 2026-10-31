import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentTableClipboardTests: XCTestCase {
    func testExportsMatchRenderedSourceTables() throws {
        _ = NSApplication.shared
        struct Fixture: Decodable { var source: String; var csv: String; var markdown: String }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.browserOracle.utf8))
        for fixture in fixtures {
            let response = AgentResponseView(frame: .zero)
            response.setContent(fixture.source, theme: AppTheme(systemIsDark: false))
            _ = response.height(for: 420)
            let table = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseTable }.first)
            XCTAssertEqual(table.copyText(.csv), fixture.csv, fixture.source)
            XCTAssertEqual(table.copyText(.markdown), fixture.markdown, fixture.source)
        }
    }

    // Captured from actual ChatMarkdown table DOM at source e5909e53, via markdown-clipboard.ts.
    private static let browserOracle = #"""
    [
      {
        "source": "| Name | Value |\n| --- | --- |\n| text | \"quoted\" |",
        "csv": "Name,Value\ntext,\"\"\"quoted\"\"\"",
        "markdown": "| Name | Value |\n| --- | --- |\n| text | \"quoted\" |"
      },
      {
        "source": "| Label | Detail |\n| :---: | ---: |\n| **Bold** and *soft* | `a  b` |\n| comma, here | quote \"here\" |\n| [Guide][ref] | escaped\\|pipe |\n\n[ref]: https://example.com",
        "csv": "Label,Detail\nBold and soft,a b\n\"comma, here\",\"quote \"\"here\"\"\"\nGuide,escaped|pipe",
        "markdown": "| Label | Detail |\n| :---: | ---: |\n| **Bold** and *soft* | `a  b` |\n| comma, here | quote \"here\" |\n| [Guide](https://example.com) | escaped\\|pipe |"
      },
      {
        "source": "| A | B |\n| --- | --- |\n| short |\n| first | second | invisible |",
        "csv": "A,B\nshort,\nfirst,second",
        "markdown": "| A | B |\n| --- | --- |\n| short |  |\n| first | second |"
      },
      {
        "source": "| Space | Other |\n| --- | --- |\n| a  b | xy |\n| c﻿d | \"z,z\" |",
        "csv": "Space,Other\na b,xy\nc d,\"\"\"z,z\"\"\"",
        "markdown": "| Space | Other |\n| --- | --- |\n| a  b | xy |\n| c﻿d | \"z,z\" |"
      },
      {
        "source": "| A | B |\n| --- | --- |\n| __bold__ _soft_ ~~gone~~ | &amp; &lt; \\*literal\\* |",
        "csv": "A,B\nbold soft gone,& < *literal*",
        "markdown": "| A | B |\n| --- | --- |\n| **bold** *soft* ~~gone~~ | & < *literal* |"
      },
      {
        "source": "| A | B |\n| --- | --- |\n| **outer *inner* end** | *outer **inner** end* |",
        "csv": "A,B\nouter inner end,outer inner end",
        "markdown": "| A | B |\n| --- | --- |\n| **outer *inner* end** | *outer **inner** end* |"
      },
      {
        "source": "| A | B |\n| --- | --- |\n| [**bold** and *soft*](https://example.com \"title\") | **[link](https://example.com) tail** |",
        "csv": "A,B\nbold and soft,link tail",
        "markdown": "| A | B |\n| --- | --- |\n| [**bold** and *soft*](https://example.com) | **[link](https://example.com) tail** |"
      },
      {
        "source": "| A | B |\n| --- | --- |\n| `` `tick` `` | `a\\|b` |",
        "csv": "A,B\n`tick`,a|b",
        "markdown": "| A | B |\n| --- | --- |\n| `` `tick` `` | `a\\|b` |"
      },
      {
        "source": "| A | B |\n| --- | --- |\n| <https://example.com> | [Mail](mailto:a@example.com) |",
        "csv": "A,B\nhttps://example.com,Mail",
        "markdown": "| A | B |\n| --- | --- |\n| https://example.com | Mail |"
      }
    ]
    """#
}
