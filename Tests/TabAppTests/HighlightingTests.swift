import Foundation
import XCTest
@testable import TabApp

final class HighlightingTests: XCTestCase {
    /// The text of each token of `kind`.
    private func words(_ text: String, _ language: SyntaxLanguage, _ kind: TokenKind) -> [String] {
        let utf16 = text as NSString
        return SyntaxHighlighter.highlight(text, language: language)
            .filter { $0.kind == kind }
            .map { utf16.substring(with: $0.range) }
    }

    func testDetectsLanguagesFromNames() {
        XCTAssertEqual(SyntaxLanguage.detect(fileName: "main.swift"), .swift)
        XCTAssertEqual(SyntaxLanguage.detect(fileName: "/a/b/Dockerfile"), .dockerfile)
        XCTAssertEqual(SyntaxLanguage.detect(fileName: "Dockerfile.dev"), .dockerfile)
        XCTAssertEqual(SyntaxLanguage.detect(fileName: "Makefile"), .makefile)
        XCTAssertEqual(SyntaxLanguage.detect(fileName: "App.TSX"), .tsx)
        XCTAssertEqual(SyntaxLanguage.detect(fileName: "Cargo.toml"), .toml)
        XCTAssertEqual(SyntaxLanguage.detect(fileName: "notes.txt"), .plain)
        XCTAssertEqual(SyntaxLanguage.detect(fileName: "run", firstLine: "#!/usr/bin/env python3"), .python)
    }

    func testSwift() {
        let source = """
        @MainActor
        struct Foo: View { // note
            let name = "a \\"quoted\\" word"
            func run() -> Int { return 0x1F + compute(2.5e3) }
        }
        /* outer /* nested */ still comment */ let x = nil
        """
        XCTAssertEqual(words(source, .swift, .attribute), ["@MainActor"])
        XCTAssertEqual(words(source, .swift, .keyword), ["struct", "let", "func", "return", "let"])
        XCTAssertEqual(words(source, .swift, .type), ["Foo", "View", "Int"])
        XCTAssertEqual(words(source, .swift, .string), ["\"a \\\"quoted\\\" word\""])
        XCTAssertEqual(words(source, .swift, .function), ["run", "compute"])
        XCTAssertEqual(words(source, .swift, .number), ["0x1F", "2.5e3", "nil"])
        XCTAssertEqual(words(source, .swift, .comment), ["// note", "/* outer /* nested */ still comment */"])
    }

    func testRustLifetimesMacrosAndAttributes() {
        let source = "#[derive(Debug)]\nfn get<'a>(s: &'a str) -> char { println!(\"{}\", s); 'x' }"
        XCTAssertEqual(words(source, .rust, .attribute), ["#[derive(Debug)]"])
        XCTAssertEqual(words(source, .rust, .function), ["println!"])
        XCTAssertEqual(words(source, .rust, .string), ["\"{}\"", "'x'"])
        XCTAssertTrue(words(source, .rust, .type).contains("'a"))
    }

    func testPythonTripleQuotedStringSpansLines() {
        let source = "def f():\n    \"\"\"Doc\n    more\"\"\"\n    return True  # done"
        XCTAssertEqual(words(source, .python, .string), ["\"\"\"Doc", "    more\"\"\""])
        XCTAssertEqual(words(source, .python, .keyword), ["def", "return"])
        XCTAssertEqual(words(source, .python, .number), ["True"])
        XCTAssertEqual(words(source, .python, .comment), ["# done"])
    }

    func testJSONKeysAndValues() {
        let source = "{\"name\": \"tab\", \"count\": 3, \"on\": true}"
        XCTAssertEqual(words(source, .json, .attribute), ["\"name\"", "\"count\"", "\"on\""])
        XCTAssertEqual(words(source, .json, .string), ["\"tab\""])
        XCTAssertEqual(words(source, .json, .number), ["3"])
        XCTAssertEqual(words(source, .json, .keyword), ["true"])
    }

    func testShellCommentsNeedAWordBoundary() {
        let source = "echo $HOME/a#b # comment\nif [ -n ${X} ]; then fi"
        XCTAssertEqual(words(source, .shell, .comment), ["# comment"])
        XCTAssertEqual(words(source, .shell, .attribute), ["$HOME", "${X}"])
        XCTAssertEqual(words(source, .shell, .keyword), ["if", "then", "fi"])
    }

    func testMarkupTagsAttributesAndComments() {
        let source = "<a href=\"x\">link</a><!-- open\nstill -->"
        XCTAssertEqual(words(source, .html, .keyword), ["a", "a"])
        XCTAssertEqual(words(source, .html, .attribute), ["href"])
        XCTAssertEqual(words(source, .html, .string), ["\"x\""])
        XCTAssertEqual(words(source, .html, .comment), ["<!-- open", "still -->"])
    }

    func testMarkdownFenceAndHeading() {
        let source = "# Title\nSome `code` here\n```\nlet x\n```"
        XCTAssertEqual(words(source, .markdown, .keyword), ["# Title"])
        XCTAssertEqual(words(source, .markdown, .string), ["`code`", "```", "let x", "```"])
    }

    func testSQLKeywordsIgnoreCase() {
        XCTAssertEqual(words("SELECT id FROM t -- x", .sql, .keyword), ["SELECT", "FROM"])
    }

    func testIncrementalUpdateMatchesFullHighlight() {
        let highlighter = SyntaxHighlighter(language: .swift)
        var text = "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4"
        highlighter.setText(text)

        // Opening a block comment changes every later line.
        text = "let a = 1\n/*let b = 2\nlet c = 3\nlet d = 4"
        var changed = highlighter.update(text, editedRange: NSRange(location: 10, length: 2), changeInLength: 2)
        XCTAssertEqual(highlighter.tokens, SyntaxHighlighter.highlight(text, language: .swift))
        XCTAssertEqual(NSMaxRange(changed), (text as NSString).length)

        // A change inside one line touches only that line.
        text = "let a = 1\n/*let b = 2\nlet c = 3\nlet dd = 4"
        changed = highlighter.update(text, editedRange: NSRange(location: 36, length: 1), changeInLength: 1)
        XCTAssertEqual(highlighter.tokens, SyntaxHighlighter.highlight(text, language: .swift))

        // Closing it again restores the code after it, and new lines shift the rest.
        text = "let a = 1\n/*let b = 2*/\n\nlet c = 3\nlet dd = 4"
        changed = highlighter.update(text, editedRange: NSRange(location: 21, length: 3), changeInLength: 3)
        XCTAssertEqual(highlighter.tokens, SyntaxHighlighter.highlight(text, language: .swift))
        XCTAssertEqual(changed.location, 10)

        // Removing a line in the middle keeps later tokens in place.
        text = "let a = 1\n/*let b = 2*/\nlet c = 3\nlet dd = 4"
        highlighter.update(text, editedRange: NSRange(location: 24, length: 0), changeInLength: -1)
        XCTAssertEqual(highlighter.tokens, SyntaxHighlighter.highlight(text, language: .swift))
    }

    func testEveryLanguageTokenizesWithoutTrapping() {
        let sample = "#!x\n<a b='c'>/* \"q\" */ {key: 1.5e-3} `t` $(V) @d [s] -- // # ''' \"\"\"\n\t~~~ é 😀 'z\n"
        for language in SyntaxLanguage.allCases {
            let tokens = SyntaxHighlighter.highlight(sample, language: language)
            let length = (sample as NSString).length
            for token in tokens {
                XCTAssertGreaterThan(token.range.length, 0, "\(language)")
                XCTAssertLessThanOrEqual(NSMaxRange(token.range), length, "\(language)")
            }
        }
    }
}
