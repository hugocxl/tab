import AppKit
import XCTest
import TabProtocol
@testable import TabApp

final class EditorModelTests: XCTestCase {
    func testDiskChangesReloadCleanEditorsAndOfferToDirtyOnes() {
        XCTAssertEqual(EditorModel.diskChange(saved: "a", disk: "a", dirty: true), .ignore)
        XCTAssertEqual(EditorModel.diskChange(saved: "a", disk: "b", dirty: false), .reload)
        XCTAssertEqual(EditorModel.diskChange(saved: "a", disk: "b", dirty: true), .offer)
        XCTAssertEqual(EditorModel.diskChange(saved: nil, disk: "b", dirty: false), .reload)
    }

    func testRefusesBinaryAndLargeFiles() {
        let binary = FilesReply.content(FileContent(path: "a", content: "ab\0cd", size: 5))
        XCTAssertEqual(EditorModel.loaded(binary), .message(EditorModel.binaryMessage))
        XCTAssertEqual(EditorModel.loadFailure("a.png isn't UTF-8 text and can't be opened"), EditorModel.binaryMessage)
        XCTAssertEqual(EditorModel.loadFailure("big.log is larger than 5 MiB and can't be opened"), EditorModel.tooLargeMessage)
        XCTAssertEqual(EditorModel.loadFailure("badPath: No such file or directory"), "File not found")
        XCTAssertEqual(EditorModel.loaded(.content(FileContent(path: "a", content: "hi", size: 2))), .text("hi"))
    }

    func testIndentationFollowsTheFile() {
        XCTAssertEqual(EditorModel.indentWidth("fn a() {\n  b\n    c\n}"), 2)
        XCTAssertEqual(EditorModel.indentWidth("no indent"), 4)
        XCTAssertEqual(EditorModel.newline(after: "    if x {", indent: 4), "\n        ")
        XCTAssertEqual(EditorModel.newline(after: "\tvalue", indent: 4), "\n\t")
        XCTAssertEqual(EditorModel.tabSpaces(column: 5, indent: 4), "   ")
    }

    func testLineAndColumnOffsetsClampAndCountCharacters() {
        let text = "one\ncafé ok\nthree"
        XCTAssertEqual(EditorModel.offset(line: 1, column: 1, in: text), 0)
        XCTAssertEqual(EditorModel.offset(line: 2, column: 6, in: text), 9)
        XCTAssertEqual(EditorModel.offset(line: 2, column: 99, in: text), 11)
        XCTAssertEqual(EditorModel.offset(line: 99, column: 1, in: text), 12)
    }

    func testTitleMarksUnsavedChanges() {
        XCTAssertEqual(EditorModel.title(path: "src/a.swift", dirty: false), "a.swift")
        XCTAssertEqual(EditorModel.title(path: "src/a.swift", dirty: true), "• a.swift")
    }
}

@MainActor
final class EditorPaneTests: XCTestCase {
    private func loadedEditor(_ text: String) async -> (EditorPaneController, StubNativeHost, StubTransport) {
        let host = StubNativeHost()
        let transport = host.transport!
        transport.filesHandler = { action in
            if case .read(let path) = action { return .content(FileContent(path: path, content: text, size: UInt64(text.utf8.count))) }
            return .done
        }
        let editor = EditorPaneController(host: host, path: "src/main.swift")
        editor.loadView()
        editor.reconnected()
        await settle { !editor.text.isEmpty }
        return (editor, host, transport)
    }

    func testEditingMarksDirtyAndSavingWritesAndClears() async {
        let (editor, host, transport) = await loadedEditor("let a = 1\n")
        XCTAssertFalse(editor.isDirty)
        editor.textView.setSelectedRange(NSRange(location: 9, length: 0))
        editor.textView.insertText("2", replacementRange: editor.textView.selectedRange())
        XCTAssertTrue(editor.isDirty)
        XCTAssertEqual(host.titles.last, "• main.swift")
        editor.save()
        await settle { !editor.isDirty }
        XCTAssertTrue(transport.filesRequests.contains(.write(path: "src/main.swift", content: "let a = 12\n")))
        XCTAssertEqual(host.titles.last, "main.swift")
    }

    func testUndoingBackToTheSavedTextIsClean() async {
        let (editor, _, _) = await loadedEditor("x")
        editor.textView.insertText("y", replacementRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(editor.isDirty)
        editor.textView.insertText("", replacementRange: NSRange(location: 1, length: 1))
        XCTAssertFalse(editor.isDirty)
    }

    func testDiskChangeReloadsCleanAndOffersDirty() async {
        let (editor, _, _) = await loadedEditor("one")
        editor.diskChanged("two")
        XCTAssertEqual(editor.text, "two")
        XCTAssertFalse(editor.isDirty)
        editor.textView.insertText("!", replacementRange: NSRange(location: 3, length: 0))
        editor.diskChanged("three")
        XCTAssertEqual(editor.text, "two!")
        XCTAssertEqual(editor.diskText, "three")
        editor.resolveDiskChange(reload: false)
        XCTAssertNil(editor.diskText)
        XCTAssertEqual(editor.text, "two!")
        editor.diskChanged("four")
        editor.resolveDiskChange(reload: true)
        XCTAssertEqual(editor.text, "four")
        XCTAssertFalse(editor.isDirty)
    }

    func testReturnKeepsIndentation() async {
        let (editor, _, _) = await loadedEditor("  if x {")
        editor.textView.setSelectedRange(NSRange(location: 8, length: 0))
        editor.textView.insertNewline(nil)
        XCTAssertEqual(editor.text, "  if x {\n    ")
    }

    func testReusesTheOpenEditorForAPath() async {
        let (editor, host, _) = await loadedEditor("a")
        XCTAssertTrue(EditorPaneController.existing(project: host.nativeProject.id, path: "src/main.swift") === editor)
        XCTAssertNil(EditorPaneController.existing(project: host.nativeProject.id, path: "other.swift"))
    }
}
