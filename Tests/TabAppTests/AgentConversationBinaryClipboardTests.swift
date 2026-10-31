import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationBinaryClipboardTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!

    func testPNGPreservesBinaryAndTextualMIMEFlavors() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try AgentConversationClipboard.write(["binary": ["image/png": png.base64EncodedString()],
                                              "flavors": ["text/plain": "Quoted 🐈", "text/html": "<b>Quoted 🐈</b>", "web text/markdown": "**Quoted 🐈**", "web application/x-tab-context-fragment+json": "{\"version\":1}"]], to: board)
        XCTAssertEqual(board.data(forType: .png), png)
        XCTAssertEqual(board.string(forType: .string), "Quoted 🐈")
        XCTAssertEqual(board.string(forType: .html), "<b>Quoted 🐈</b>")
        XCTAssertEqual(board.string(forType: try AgentConversationClipboard.pasteboardType(forMIME: "web text/markdown")), "**Quoted 🐈**")
        XCTAssertEqual(try AgentConversationClipboard.pasteboardType(forMIME: "web text/markdown").rawValue, "net.daringfireball.markdown")
        XCTAssertEqual(board.string(forType: try AgentConversationClipboard.pasteboardType(forMIME: "web application/x-tab-context-fragment+json")), "{\"version\":1}")
    }

    func testMalformedOrOversizedBinaryDoesNotClearPriorClipboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("existing clipboard", forType: .string)
        let payloads: [[String: Any]] = [
            ["binary": ["image/png": Data("not a PNG".utf8).base64EncodedString()]],
            ["binary": ["image/jpeg": png.base64EncodedString()]],
            ["binary": ["image/png": "%%%"]],
            ["binary": ["image/png": String(repeating: "A", count: ((AgentConversationClipboard.maximumBytes + 2) / 3) * 4 + 4)]]
        ]
        for payload in payloads {
            XCTAssertThrowsError(try AgentConversationClipboard.write(payload, to: board))
            XCTAssertEqual(board.string(forType: .string), "existing clipboard")
        }
    }
    func testChunkedTransferPreservesValidPNGAboveTenMiBAndCommitsAtomically() throws {
        let bytes = try AgentConversationMediaFixtures.largePNG()
        XCTAssertGreaterThan(bytes.count, 10 * 1024 * 1024)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("prior clipboard", forType: .string)
        let transfer = AgentConversationClipboardTransfer(pasteboard: board)
        let id = try XCTUnwrap(transfer.handle(["phase": "begin", "byteLength": bytes.count, "flavors": [String: String]()]) as? String)
        for offset in stride(from: 0, to: bytes.count, by: 256 * 1024) {
            let chunk = bytes.subdata(in: offset ..< min(bytes.count, offset + 256 * 1024))
            _ = try transfer.handle(["phase": "chunk", "transferId": id, "offset": offset, "dataBase64": chunk.base64EncodedString()])
            XCTAssertEqual(board.string(forType: .string), "prior clipboard")
        }
        _ = try transfer.handle(["phase": "commit", "transferId": id])
        XCTAssertEqual(board.data(forType: .png), bytes)
    }

    func testIncompleteOutOfOrderOrCancelledTransfersPreservePasteboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("prior clipboard", forType: .string)
        let transfer = AgentConversationClipboardTransfer(pasteboard: board)
        for phase in ["commit", "out-of-order", "cancel"] {
            let id = try XCTUnwrap(transfer.handle(["phase": "begin", "byteLength": png.count, "flavors": [String: String]()]) as? String)
            if phase == "cancel" { transfer.cancel() }
            let payload: [String: Any] = phase == "out-of-order"
                ? ["phase": "chunk", "transferId": id, "offset": 1, "dataBase64": png.base64EncodedString()]
                : ["phase": "commit", "transferId": id]
            XCTAssertThrowsError(try transfer.handle(payload))
            XCTAssertEqual(board.string(forType: .string), "prior clipboard")
        }
    }

}
