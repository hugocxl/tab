import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentFileLinkMetadataTests: XCTestCase {
    private let theme = AppTheme(systemIsDark: false)

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func utcFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    private func prose(_ source: String, services: AgentConversationLinkServices) throws -> (AgentResponseView, AgentResponseProse) {
        let view = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        view.linkServices = services
        view.setContent(source, theme: theme)
        view.frame.size.height = view.height(for: 400)
        let prose = try XCTUnwrap(view.sectionViews.first as? AgentResponseProse)
        return (view, prose)
    }

    func testTooltipTextForFilesDirectoriesAndMissingPaths() {
        let file = AgentConversationFileActions.Metadata(isDirectory: false, byteLength: 1_536, mimeType: "text/plain", modified: Date(timeIntervalSince1970: 1_793_000_000))
        let text = AgentFileLinkTooltip.text(path: "Sources/main.swift", root: "/work/tab", state: .loaded(file), dateFormatter: utcFormatter())
        XCTAssertEqual(text.components(separatedBy: "\n"), ["/work/tab/Sources/main.swift", "File · " + AgentFileLinkTooltip.size(1_536), "Modified 2026-10-26 07:33"])
        let directory = AgentConversationFileActions.Metadata(isDirectory: true, byteLength: 96, mimeType: nil)
        XCTAssertEqual(AgentFileLinkTooltip.text(path: "/work/tab/Sources", root: nil, state: .loaded(directory)), "/work/tab/Sources\nDirectory")
        XCTAssertEqual(AgentFileLinkTooltip.text(path: "gone.swift", root: "/work", state: .loaded(nil)), "/work/gone.swift\nNot found")
        XCTAssertEqual(AgentFileLinkTooltip.text(path: "a.swift", root: nil, state: nil), "a.swift\nLoading…")
        XCTAssertEqual(AgentFileLinkTooltip.text(path: "a.swift", root: nil, state: .failed("Offline")), "a.swift\nOffline")
    }

    func testFullPathResolvesAgainstTheProjectFolder() {
        XCTAssertEqual(AgentFileLinkTooltip.fullPath("./Sources/../Package.swift", root: "/work/tab"), "/work/tab/Package.swift")
        XCTAssertEqual(AgentFileLinkTooltip.fullPath("/etc/hosts", root: "/work/tab"), "/etc/hosts")
        XCTAssertEqual(AgentFileLinkTooltip.fullPath("README.md", root: nil), "README.md")
    }

    func testCompactSizes() {
        XCTAssertEqual(AgentFileLinkTooltip.size(0), ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
        XCTAssertEqual(AgentFileLinkTooltip.size(2_500_000), ByteCountFormatter.string(fromByteCount: 2_500_000, countStyle: .file))
    }

    func testFileLinksAreFoundAndMergedPerPath() {
        let rendered = AgentMarkdown.render(AgentResponseParser.parse("Edit [main](Sources/main.swift) and `Package.swift`, see https://example.com"),
                                            theme: theme, fileLinks: true)
        XCTAssertEqual(AgentFileLinkHover.fileLinks(in: rendered).map(\.path), ["Sources/main.swift", "Package.swift"])
    }

    func testTrackingAreasAndToolTipHitTestingCoverTheLinkRect() throws {
        let services = AgentConversationLinkServices()
        services.workspaceRoot = "/work"
        let (view, prose) = try prose("Open [the entry point](Sources/main.swift) now.", services: services)
        view.layoutSubtreeIfNeeded()
        let hover = try XCTUnwrap(prose.text.fileLinkHover)
        let link = try XCTUnwrap(hover.links.first)
        XCTAssertEqual(link.path, "Sources/main.swift")
        let rect = try XCTUnwrap(link.rects.first)
        XCTAssertGreaterThan(rect.width, 20)
        let storage = try XCTUnwrap(prose.text.textStorage)
        let manager = try XCTUnwrap(prose.text.layoutManager)
        let container = try XCTUnwrap(prose.text.textContainer)
        let expected = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: link.range, actualCharacterRange: nil), in: container)
        XCTAssertEqual(rect.minX, expected.minX, accuracy: 0.5)
        XCTAssertEqual((storage.string as NSString).substring(with: link.range), "the entry point")
        XCTAssertTrue(prose.text.trackingAreas.contains { $0.rect == rect && $0.owner === hover })
        XCTAssertEqual(hover.link(at: NSPoint(x: rect.midX, y: rect.midY))?.path, "Sources/main.swift")
        XCTAssertNil(hover.link(at: NSPoint(x: rect.maxX + 40, y: rect.midY)))
        let tip = hover.view(prose.text, stringForToolTip: 0, point: NSPoint(x: rect.midX, y: rect.midY), userData: nil)
        XCTAssertEqual(tip, "/work/Sources/main.swift\nThis conversation cannot load link details.")
        XCTAssertEqual(hover.view(prose.text, stringForToolTip: 0, point: NSPoint(x: rect.maxX + 40, y: rect.midY), userData: nil), "")
    }

    func testRebuildIsSkippedWhenLayoutDidNotMove() throws {
        let (_, prose) = try prose("Open [main](Sources/main.swift).", services: AgentConversationLinkServices())
        let hover = try XCTUnwrap(prose.text.fileLinkHover)
        hover.rebuild()
        let areas = hover.trackingAreas
        XCTAssertFalse(areas.isEmpty)
        hover.rebuild()
        XCTAssertTrue(zip(areas, hover.trackingAreas).allSatisfy { $0 === $1 }, "Unchanged links keep their tracking areas")
    }

    func testMetadataIsRequestedOnHoverOnceAndCached() async throws {
        let services = AgentConversationLinkServices()
        var calls: [String] = []
        services.fileMetadata.fetch = { path in
            calls.append(path)
            return AgentConversationFileActions.Metadata(isDirectory: false, byteLength: 10, mimeType: nil)
        }
        let (_, prose) = try prose("[a](Sources/a.swift), [again](Sources/a.swift) and [b](Sources/b.swift)", services: services)
        XCTAssertEqual(calls, [], "Rendering never requests metadata")
        let hover = try XCTUnwrap(prose.text.fileLinkHover)
        hover.request("Sources/a.swift")
        hover.request("Sources/a.swift")
        let other = try self.prose("[a](Sources/a.swift)", services: services).1
        other.text.fileLinkHover?.request("Sources/a.swift")
        await settle()
        XCTAssertEqual(calls, ["Sources/a.swift"])
        XCTAssertEqual(services.fileMetadata.state(for: "Sources/a.swift"), .loaded(.init(isDirectory: false, byteLength: 10, mimeType: nil)))
    }

    func testMissingPathsAreStruckThroughOnceKnown() async throws {
        let services = AgentConversationLinkServices()
        services.fileMetadata.fetch = { _ in nil }
        let (view, prose) = try prose("See [old](Sources/old.swift).", services: services)
        let hover = try XCTUnwrap(prose.text.fileLinkHover)
        let range = try XCTUnwrap(hover.links.first?.range)
        let storage = try XCTUnwrap(prose.text.textStorage)
        XCTAssertNil(storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil))
        hover.request("Sources/old.swift")
        await settle()
        XCTAssertEqual(storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, AgentMarkdownPalette(theme: theme).muted)
        view.setContent("See [old](Sources/old.swift). Done.", theme: theme)
        let rerendered = try XCTUnwrap((view.sectionViews.first as? AgentResponseProse)?.text.textStorage)
        XCTAssertNotNil(rerendered.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil), "A new render keeps the known state")
    }

    func testWithoutServicesNoTooltipsAreInstalled() throws {
        let view = AgentResponseView(frame: .zero)
        view.setContent("[a](Sources/a.swift)", theme: theme)
        _ = view.height(for: 300)
        XCTAssertNil((view.sectionViews.first as? AgentResponseProse)?.text.fileLinkHover)
    }
}
