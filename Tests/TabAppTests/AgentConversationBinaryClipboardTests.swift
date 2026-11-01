import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationBinaryClipboardTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!

    func testPNGPreservesBinaryAndTextualMIMEFlavors() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try AgentConversationClipboard.write(flavors: ["text/plain": "Quoted 🐈", "text/html": "<b>Quoted 🐈</b>", "web text/markdown": "**Quoted 🐈**", "web application/x-tab-context-fragment+json": "{\"version\":1}"],
                                             png: png, to: board)
        XCTAssertEqual(board.data(forType: .png), png)
        XCTAssertEqual(board.string(forType: .string), "Quoted 🐈")
        XCTAssertEqual(board.string(forType: .html), "<b>Quoted 🐈</b>")
        XCTAssertEqual(board.string(forType: try AgentConversationClipboard.pasteboardType(forMIME: "web text/markdown")), "**Quoted 🐈**")
        XCTAssertEqual(try AgentConversationClipboard.pasteboardType(forMIME: "web text/markdown").rawValue, "net.daringfireball.markdown")
        XCTAssertEqual(board.string(forType: try AgentConversationClipboard.pasteboardType(forMIME: "web application/x-tab-context-fragment+json")), "{\"version\":1}")
    }

    func testMalformedContentDoesNotClearPriorClipboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("existing clipboard", forType: .string)
        let jpeg = try XCTUnwrap(NSBitmapImageRep(data: png)?.representation(using: .jpeg, properties: [:]))
        for invalid in [Data("not a PNG".utf8), jpeg, Data()] {
            XCTAssertThrowsError(try AgentConversationClipboard.write(flavors: ["text/plain": "replacement"], png: invalid, to: board))
            XCTAssertEqual(board.string(forType: .string), "existing clipboard")
        }
        XCTAssertThrowsError(try AgentConversationClipboard.write(flavors: [:], to: board))
        XCTAssertThrowsError(try AgentConversationClipboard.write(flavors: ["application/octet-stream": "binary"], to: board))
        XCTAssertThrowsError(try AgentConversationClipboard.write(flavors: ["text/plain": String(repeating: "a", count: AgentConversationClipboard.maximumBytes + 1)], to: board))
        XCTAssertEqual(board.string(forType: .string), "existing clipboard")
    }

    func testValidPNGAboveTenMiBIsCopiedWhole() throws {
        let bytes = try AgentConversationMediaFixtures.largePNG()
        XCTAssertGreaterThan(bytes.count, 10 * 1024 * 1024)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("prior clipboard", forType: .string)
        try AgentConversationClipboard.write(flavors: [:], png: bytes, to: board)
        XCTAssertEqual(board.data(forType: .png), bytes)
        XCTAssertNil(board.string(forType: .string))
    }
}
