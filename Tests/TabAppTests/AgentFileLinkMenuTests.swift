import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentFileLinkMenuTests: XCTestCase {
    private let theme = AppTheme(systemIsDark: false)

    private func file(_ target: String) throws -> AgentLinkMenu.Target {
        .file(try XCTUnwrap(AgentConversationFileTarget.parse(target)))
    }

    /// Records every call `perform` makes.
    private final class Recorder {
        var calls: [String] = []
        var actions: AgentLinkMenu.Actions {
            AgentLinkMenu.Actions(
                openEditor: { target, reveal in self.calls.append((reveal ? "reveal " : "editor ") + target) },
                previewFile: { path in self.calls.append("preview " + path) },
                openFileInBrowser: { path in self.calls.append("browser " + path) },
                openPreview: { url in self.calls.append("tab-browser " + url.absoluteString) },
                copy: { text in self.calls.append("copy " + text) })
        }
    }

    private func renderedLinkURL(_ markdown: String) throws -> URL {
        let rendered = AgentMarkdown.render(AgentResponseParser.parse(markdown), theme: theme, fileLinks: true)
        var found: URL?
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, stop in
            if let url = value as? URL { found = url; stop.pointee = true }
        }
        return try XCTUnwrap(found)
    }

    // MARK: Items

    func testRemoteFileWithoutPositionOffersEditorPreviewAndCopies() throws {
        XCTAssertEqual(AgentLinkMenu.items(for: try file("Sources/App.swift"), isLocal: false),
                       [.openInEditor, .preview, .copyPath, .copyRelativePath])
    }

    func testLocalFileWithPositionAddsOpenAtLineAndFinder() throws {
        XCTAssertEqual(AgentLinkMenu.items(for: try file("Sources/App.swift:12:4"), isLocal: true),
                       [.openInEditor, .openAtPosition(line: 12, column: 4), .preview, .revealInFinder, .copyPath, .copyRelativePath])
    }

    func testHtmlFilesOpenInBrowserOnlyForLocalProjects() throws {
        XCTAssertTrue(AgentLinkMenu.items(for: try file("site/index.html"), isLocal: true).contains(.openInBrowser))
        XCTAssertTrue(AgentLinkMenu.items(for: try file("site/page.HTM"), isLocal: true).contains(.openInBrowser))
        XCTAssertFalse(AgentLinkMenu.items(for: try file("site/index.html"), isLocal: false).contains(.openInBrowser))
        XCTAssertFalse(AgentLinkMenu.items(for: try file("site/index.css"), isLocal: true).contains(.openInBrowser))
    }

    func testWebLinksOpenInTabBrowserOrCopy() throws {
        let target = try XCTUnwrap(AgentLinkMenu.Target(link: URL(string: "https://example.com/a")))
        XCTAssertEqual(AgentLinkMenu.items(for: target, isLocal: true), [.openInBrowser, .copyLink])
        XCTAssertNil(AgentLinkMenu.Target(link: URL(string: "mailto:someone@example.com")))
        XCTAssertNil(AgentLinkMenu.Target(link: nil))
    }

    func testItemTitles() {
        XCTAssertEqual(AgentLinkMenu.Item.openAtPosition(line: 10, column: nil).title, "Open at Line 10")
        XCTAssertEqual(AgentLinkMenu.Item.openAtPosition(line: 10, column: 5).title, "Open at Line 10, Column 5")
        XCTAssertEqual(AgentLinkMenu.Item.revealInFinder.title, "Reveal in Finder")
        XCTAssertEqual(AgentLinkMenu.Item.copyRelativePath.title, "Copy Relative Path")
    }

    // MARK: Positions

    func testPositionSuffixesParseIntoLineAndColumn() throws {
        XCTAssertEqual(AgentConversationFileTarget.parse("a/b.swift:10:5"), .init(path: "a/b.swift", line: 10, column: 5))
        XCTAssertEqual(AgentConversationFileTarget.parse("a/b.swift:10"), .init(path: "a/b.swift", line: 10))
        XCTAssertEqual(AgentConversationFileTarget.parse("a/b.swift#L10"), .init(path: "a/b.swift", line: 10))
        XCTAssertEqual(AgentConversationFileTarget.parse("a/b.swift#L10C3"), .init(path: "a/b.swift", line: 10, column: 3))
        XCTAssertEqual(AgentConversationFileTarget(path: "a.swift", line: 3, column: 7).editorTarget, "a.swift:3:7")
        XCTAssertEqual(AgentConversationFileTarget(path: "a.swift").editorTarget, "a.swift")
    }

    func testRenderedFileLinksKeepTheirLineAndColumn() throws {
        let colon = try XCTUnwrap(AgentConversationFileTarget(linkURL: try renderedLinkURL("See [main](Sources/main.swift:42:7).")))
        XCTAssertEqual(colon, .init(path: "Sources/main.swift", line: 42, column: 7))
        let fragment = try XCTUnwrap(AgentConversationFileTarget(linkURL: try renderedLinkURL("See [main](Sources/main.swift#L8).")))
        XCTAssertEqual(fragment, .init(path: "Sources/main.swift", line: 8))
        XCTAssertNil(AgentConversationFileTarget(linkURL: try XCTUnwrap(URL(string: "https://example.com"))))
    }

    func testClickingAFileLinkOpensItsExactPositionThroughTheServices() throws {
        let services = AgentConversationLinkServices()
        var opened: AgentConversationFileTarget?
        services.openFile = { opened = $0 }
        let view = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        view.linkServices = services
        view.setContent("Fix [this](Sources/main.swift:42:7)", theme: theme)
        let url = try renderedLinkURL("Fix [this](Sources/main.swift:42:7)")
        XCTAssertTrue(view.textView(NSTextView(), clickedOnLink: url, at: 0))
        XCTAssertEqual(opened, .init(path: "Sources/main.swift", line: 42, column: 7))
    }

    // MARK: Actions

    func testEveryFileItemCallsItsAction() async throws {
        let recorder = Recorder()
        let target = try file("Sources/App.swift:12:4")
        for item in AgentLinkMenu.items(for: target, isLocal: true) {
            try await AgentLinkMenu.perform(item, target: target, root: "/work/tab", actions: recorder.actions)
        }
        let html = try file("site/index.html")
        try await AgentLinkMenu.perform(.openInBrowser, target: html, root: "/work/tab", actions: recorder.actions)
        XCTAssertEqual(recorder.calls, [
            "editor Sources/App.swift", "editor Sources/App.swift:12:4", "preview Sources/App.swift",
            "reveal Sources/App.swift", "copy /work/tab/Sources/App.swift", "copy Sources/App.swift", "browser site/index.html",
        ])
    }

    func testWebItemsCallTabBrowserAndCopy() async throws {
        let recorder = Recorder()
        let target = AgentLinkMenu.Target.web(try XCTUnwrap(URL(string: "https://example.com/x")))
        try await AgentLinkMenu.perform(.openInBrowser, target: target, root: nil, actions: recorder.actions)
        try await AgentLinkMenu.perform(.copyLink, target: target, root: nil, actions: recorder.actions)
        XCTAssertEqual(recorder.calls, ["tab-browser https://example.com/x", "copy https://example.com/x"])
        do {
            try await AgentLinkMenu.perform(.revealInFinder, target: target, root: nil, actions: recorder.actions)
            XCTFail("Finder does not apply to web links")
        } catch {}
    }

    func testRelativePathsAgainstTheProjectFolder() {
        XCTAssertEqual(AgentLinkMenu.relativePath("/work/tab/Sources/A.swift", root: "/work/tab"), "Sources/A.swift")
        XCTAssertEqual(AgentLinkMenu.relativePath("./Sources/../README.md", root: "/work/tab"), "README.md")
        XCTAssertEqual(AgentLinkMenu.relativePath("/etc/hosts", root: "/work/tab"), "/etc/hosts")
        XCTAssertEqual(AgentLinkMenu.relativePath("./a.swift", root: nil), "a.swift")
    }

    func testCopyPathAndRelativePathWriteThePasteboard() async throws {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("tab-file-link-menu-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        surface.actions.pasteboard = pasteboard
        let target = try file("/work/tab/Sources/A.swift:3")
        try await AgentLinkMenu.perform(.copyPath, target: target, root: "/work/tab", actions: surface.actions.linkMenuActions)
        XCTAssertEqual(pasteboard.string(forType: .string), "/work/tab/Sources/A.swift")
        try await AgentLinkMenu.perform(.copyRelativePath, target: target, root: "/work/tab", actions: surface.actions.linkMenuActions)
        XCTAssertEqual(pasteboard.string(forType: .string), "Sources/A.swift")
    }

    // MARK: Menu

    func testMenuItemsRunThroughTheServices() throws {
        let services = AgentConversationLinkServices()
        services.isLocalProject = { true }
        var performed: [(AgentLinkMenu.Item, AgentLinkMenu.Target)] = []
        services.performLinkAction = { performed.append(($0, $1)) }
        let target = try file("a.swift:2")
        let items = AgentLinkMenu.menuItems(for: target, services: services)
        XCTAssertEqual(items.map(\.title), ["Open in Editor", "Open at Line 2", "Preview", "Reveal in Finder", "Copy Path", "Copy Relative Path"])
        let finder = try XCTUnwrap(items.first { $0.title == "Reveal in Finder" })
        _ = (finder.target as AnyObject?)?.perform(finder.action, with: finder)
        XCTAssertEqual(performed.first?.0, .revealInFinder)
        XCTAssertEqual(performed.first?.1, target)
        services.performLinkAction = nil
        XCTAssertTrue(AgentLinkMenu.menuItems(for: target, services: services).isEmpty)
    }

    func testRightClickOnARenderedFileLinkOffersItsActions() throws {
        let services = AgentConversationLinkServices()
        services.performLinkAction = { _, _ in }
        let view = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        view.linkServices = services
        view.setContent("Open [main](Sources/main.swift:9) now", theme: theme)
        view.frame.size.height = view.height(for: 400)
        view.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap((view.sectionViews.first as? AgentResponseProse)?.text)
        let range = (text.string as NSString).range(of: "main")
        let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        let point = NSPoint(x: rect.midX + text.textContainerOrigin.x, y: rect.midY + text.textContainerOrigin.y)
        XCTAssertEqual(text.linkMenuItems(at: point).map(\.title).prefix(2), ["Open in Editor", "Open at Line 9"])
        let plain = (text.string as NSString).range(of: "now")
        let plainRect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: plain, actualCharacterRange: nil), in: container)
        XCTAssertTrue(text.linkMenuItems(at: NSPoint(x: plainRect.midX, y: plainRect.midY)).isEmpty)
    }

    // MARK: Failures

    func testFailedMenuActionsReachTheComposerError() async throws {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        var errors: [String] = []
        surface.onActionError = { errors.append($0) }
        surface.performLinkAction(.preview, target: try file("Sources/A.swift"))
        let deadline = Date().addingTimeInterval(2)
        while errors.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(errors, ["The project server is offline."])
        XCTAssertFalse(surface.linkServices.isLocalProject(), "An unbound conversation has no local project")
    }

    func testFailedLinkTemplateAndFileOpensReachTheComposerError() async throws {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        var errors: [String] = []
        surface.onActionError = { errors.append($0) }
        surface.linkServices.openLink?("javascript:alert(1)")
        let deadline = Date().addingTimeInterval(2)
        while errors.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(errors, ["This link cannot be opened."])
        surface.linkServices.openFile?(.init(path: "a.swift", line: 1))
        XCTAssertEqual(errors.last, "The project server is offline.")
        surface.composer.isEditable = false
        let template = try XCTUnwrap(AgentArtifactTemplate.parse(#"::artifact-template{artifact_kind="document" display_name="Memo" skill_directory="/skills/doc" skill_name="artifact-template-doc"}"#))
        surface.linkServices.useTemplate?(template)
        XCTAssertEqual(errors.count, 3)
        XCTAssertEqual(errors.last, "The composer is busy; try again once it is ready.")
    }
}
