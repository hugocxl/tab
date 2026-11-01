import AppKit
import XCTest
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class AgentMarkdownMediaTests: XCTestCase {
    private let theme = AppTheme(systemIsDark: false)

    private func png(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func dataURI(width: Int = 4, height: Int = 4) throws -> String {
        "data:image/png;base64," + (try png(width: width, height: height)).base64EncodedString()
    }

    /// Link services with a loader whose remote fetch is stubbed; `fetched` records each URL.
    private func services(_ respond: @escaping @Sendable (URL) async throws -> Data) -> (AgentConversationLinkServices, AgentMediaLoader) {
        let services = AgentConversationLinkServices()
        let loader = AgentMediaLoader()
        loader.fetchRemote = { url, _ in (try await respond(url), "image/png") }
        services.mediaLoader = loader
        return (services, loader)
    }

    private func window(with view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        return window
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for media state")
    }

    private func response(_ markdown: String, services: AgentConversationLinkServices?, width: CGFloat = 600) -> AgentResponseView {
        let view = AgentResponseView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.linkServices = services
        view.setContent(markdown, theme: theme)
        _ = view.height(for: width)
        return view
    }

    private func mediaParts(_ markdown: String) -> [AgentResponsePart] {
        AgentResponsePart.partition(AgentResponseParser.parse(markdown), media: true)
    }

    // MARK: Parsing

    func testImageOnlyParagraphBecomesOneMediaPart() {
        let parts = mediaParts("Here it is:\n\n![A red square](images/red.png \"Red\")\n\nDone.")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[1], .media([AgentMarkdownMedia(source: "images/red.png", alt: "A red square", kind: .image)]))
        XCTAssertEqual(parts[1].kind, 10)
    }

    func testSeveralImagesSeparatedByWhitespaceShareOneCollage() {
        let parts = mediaParts("![one](https://example.com/1.png) ![two](<shots/two words.jpg>)\n![](data:image/gif;base64,R0lGOD)")
        guard case .media(let items)? = parts.first else { return XCTFail("Expected a media part, got \(parts)") }
        XCTAssertEqual(items.map(\.source), ["https://example.com/1.png", "shots/two words.jpg", "data:image/gif;base64,R0lGOD"])
        XCTAssertEqual(items.map(\.alt), ["one", "two", ""])
        XCTAssertEqual(items[1].name, "two")
        XCTAssertEqual(items[2].name, "Image")
    }

    func testBareMediaURLsAndPathsBecomeMediaWithTheirKind() {
        XCTAssertEqual(mediaParts("https://cdn.example.com/clip.mp4?v=2"), [.media([AgentMarkdownMedia(source: "https://cdn.example.com/clip.mp4?v=2", kind: .video)])])
        XCTAssertEqual(mediaParts("<https://example.com/song.mp3>"), [.media([AgentMarkdownMedia(source: "https://example.com/song.mp3", kind: .audio)])])
        XCTAssertEqual(mediaParts("docs/screenshots/after.webp"), [.media([AgentMarkdownMedia(source: "docs/screenshots/after.webp", kind: .image)])])
        XCTAssertEqual(mediaParts("/tmp/project/out.gif"), [.media([AgentMarkdownMedia(source: "/tmp/project/out.gif", kind: .image)])])
        XCTAssertEqual(AgentMarkdownMedia.bare("docs/screenshots/after.webp")?.name, "after.webp")
    }

    func testNonMediaLinksAndSentencesStayProse() {
        for markdown in ["https://example.com/page", "See docs/shot.png for details.", "`docs/shot.png`", "mailto:a@example.com",
                         "![x](javascript:alert(1))", "![x](mailto:a@example.com)", ".png", "**docs/a.png**",
                         "![chart](https://example.com/a.png) is attached"] {
            XCTAssertTrue(mediaParts(markdown).allSatisfy { $0.kind == 0 }, markdown)
        }
    }

    func testPartiallyTypedImageStaysTextUntilClosed() {
        XCTAssertEqual(mediaParts("![alt](ur").map(\.kind), [0])
        XCTAssertEqual(mediaParts("![alt](https://example.com/a.png \"title").map(\.kind), [0])
        XCTAssertEqual(mediaParts("![alt](https://example.com/a.png)").map(\.kind), [10])
        let rendered = AgentMarkdown.inline("![alt](ur", theme: theme)
        XCTAssertEqual(rendered.string, "![alt](ur")
    }

    func testMediaPartsNeedTheAssistantLoader() {
        let markdown = "![shot](a.png)"
        XCTAssertEqual(AgentResponsePart.partition(AgentResponseParser.parse(markdown)).map(\.kind), [0], "User messages keep images as text")
        XCTAssertTrue(response(markdown, services: nil).sectionViews.allSatisfy { $0 is AgentResponseProse })
        XCTAssertTrue(response(markdown, services: AgentConversationLinkServices()).sectionViews.allSatisfy { $0 is AgentResponseProse })
    }

    func testSourcesClassifySchemesAndDecodePaths() {
        XCTAssertEqual(AgentMediaSource("https://example.com/a.png"), .remote(URL(string: "https://example.com/a.png")!))
        XCTAssertEqual(AgentMediaSource("file:///Users/me/p/a.png"), .file("/Users/me/p/a.png"))
        XCTAssertEqual(AgentMediaSource("my%20shot.png"), .file("my shot.png"))
        XCTAssertNil(AgentMediaSource("data:text/html;base64,PGI+"), "Only image, video and audio payloads are media")
        XCTAssertNil(AgentMediaSource("ftp://example.com/a.png"))
        XCTAssertEqual(AgentMarkdownMedia(source: "data:video/mp4;base64,AAAA", kind: .video).mimeType, "video/mp4")
        XCTAssertNil(AgentMarkdownMedia(source: "data:image/png;base64,AAAA", kind: .image).link)
    }

    // MARK: Loader

    func testDataURIDecodesAndRefusesPayloadsOverTheBound() throws {
        let bytes = try png(width: 3, height: 2)
        let decoded = try AgentMediaLoader.decodeDataURI("data:image/png;base64," + bytes.base64EncodedString())
        XCTAssertEqual(decoded.data, bytes)
        XCTAssertEqual(decoded.mimeType, "image/png")
        XCTAssertEqual(try AgentMediaLoader.decodeDataURI("data:image/svg+xml,%3Csvg%2F%3E").data, Data("<svg/>".utf8))
        let oversized = "data:image/png;base64," + String(repeating: "A", count: (AgentMediaLoader.maximumDataURIBytes / 3 + 2) * 4 + 8192)
        XCTAssertThrowsError(try AgentMediaLoader.decodeDataURI(oversized))
        XCTAssertThrowsError(try AgentMediaLoader.decodeDataURI("data:image/png;base64,"))
    }

    func testObserversShareOneRequestAndCachedResultsAreReused() async throws {
        let bytes = try png(width: 40, height: 20)
        let counter = Counter()
        let (_, loader) = services { _ in await counter.increment(); return bytes }
        let media = AgentMarkdownMedia(source: "https://example.com/a.png", kind: .image)
        var states: [String] = []
        let first = loader.observe(media) { states.append($0.isLoading ? "loading" : "first") }
        let second = loader.observe(media) { _ in }
        try await wait { loader.state(for: media.source)?.entry != nil }
        XCTAssertEqual(loader.requestCount, 1)
        let fetches = await counter.value
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(states, ["loading", "first"])
        XCTAssertEqual(loader.state(for: media.source)?.entry?.pixelSize, CGSize(width: 40, height: 20))
        first.cancel(); second.cancel()
        let entry = try await loader.entry(for: media)
        XCTAssertEqual(entry.data, bytes)
        XCTAssertEqual(loader.requestCount, 1, "A loaded source is cached for the conversation")
        loader.reset()
        XCTAssertNil(loader.state(for: media.source))
    }

    func testReleasingTheLastObserverCancelsTheRequest() async throws {
        let cancelled = Flag()
        let (_, loader) = services { _ in
            do { try await Task.sleep(for: .seconds(30)) } catch { await cancelled.set(); throw error }
            return Data()
        }
        let media = AgentMarkdownMedia(source: "https://example.com/slow.png", kind: .image)
        let first = loader.observe(media) { _ in }
        let second = loader.observe(media) { _ in }
        first.cancel()
        XCTAssertTrue(loader.state(for: media.source)?.isLoading == true, "Another tile still waits")
        second.cancel()
        XCTAssertNil(loader.state(for: media.source))
        try await wait { cancelled.isSet }
    }

    func testFailuresAreForgottenAndRetriedOnTheNextAppearance() async throws {
        let counter = Counter()
        let bytes = try png(width: 8, height: 8)
        let (_, loader) = services { _ in
            let attempt = await counter.increment()
            if attempt == 1 { throw ModelError("offline") }
            return bytes
        }
        let media = AgentMarkdownMedia(source: "https://example.com/flaky.png", kind: .image)
        var failed = false
        let first = loader.observe(media) { if case .failed = $0 { failed = true } }
        try await wait { failed }
        first.cancel()
        XCTAssertNil(loader.state(for: media.source), "Failures are not cached once nobody observes them")
        let second = loader.observe(media) { _ in }
        try await wait { loader.state(for: media.source)?.entry != nil }
        second.cancel()
        XCTAssertEqual(loader.requestCount, 2)
    }

    func testCacheEvictsTheLeastRecentlyUsedEntryBeyondItsBound() async throws {
        let bytes = try png(width: 64, height: 64)
        let (_, loader) = services { _ in bytes }
        let sources = ["a", "b", "c"].map { AgentMarkdownMedia(source: "https://example.com/\($0).png", kind: .image) }
        _ = try await loader.entry(for: sources[0])
        let cost = loader.cachedCost
        loader.costLimit = cost * 2
        _ = try await loader.entry(for: sources[1])
        _ = loader.state(for: sources[0].source) // Touch a, so b is the oldest.
        _ = try await loader.entry(for: sources[2])
        XCTAssertNotNil(loader.state(for: sources[0].source))
        XCTAssertNil(loader.state(for: sources[1].source))
        XCTAssertNotNil(loader.state(for: sources[2].source))
        XCTAssertLessThanOrEqual(loader.cachedCost, loader.costLimit)
    }

    func testProjectPathsLoadThroughWorkspaceMedia() async throws {
        let bytes = try png(width: 12, height: 6)
        let loader = AgentMediaLoader()
        var paths: [String] = []
        loader.workspaceMedia = { path in
            paths.append(path)
            return AgentConversationFileActions.Media(path: path, sourcePath: "/project/" + path, mimeType: "image/png", revision: "r1",
                                                      resource: AgentConversationRangedResource(data: bytes, mimeType: "image/png", revision: "r1"))
        }
        loader.fetchRemote = { _, _ in XCTFail("Project files never reach the network"); return (Data(), nil) }
        let entry = try await loader.entry(for: AgentMarkdownMedia(source: "docs/my%20shot.png", kind: .image))
        XCTAssertEqual(paths, ["docs/my shot.png"])
        XCTAssertEqual(entry.data, bytes)
        XCTAssertEqual(entry.mimeType, "image/png")
        XCTAssertEqual(entry.pixelSize, CGSize(width: 12, height: 6))
    }

    func testDataURIImagesLoadWithoutAnyFetch() async throws {
        let loader = AgentMediaLoader()
        loader.fetchRemote = { _, _ in XCTFail("Inline payloads are decoded locally"); return (Data(), nil) }
        let entry = try await loader.entry(for: AgentMarkdownMedia(source: try dataURI(width: 5, height: 3), kind: .image))
        XCTAssertEqual(entry.pixelSize, CGSize(width: 5, height: 3))
        XCTAssertNotNil(entry.image)
    }

    func testRemoteSessionSendsNoCookiesOrCredentialsAndTimesOut() {
        let configuration = AgentMediaLoader.session.configuration
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 20)
    }

    // MARK: Section

    func testRequestsStartOnlyInAWindowAndStreamingReusesTheSection() async throws {
        let bytes = try png(width: 1600, height: 1200)
        let (services, loader) = services { _ in bytes }
        let view = response("Before\n\n![chart](https://example.com/chart.png)\n\nAfter", services: services)
        XCTAssertEqual(loader.requestCount, 0, "Nothing loads before the section is in a window")
        let host = window(with: view)
        defer { host.close() }
        let section = try XCTUnwrap(view.sectionViews.compactMap { $0 as? AgentResponseMedia }.first)
        try await wait { (section.tiles.first as? AgentMediaTile)?.image != nil }
        let updates = section.updateCount
        for suffix in [" more", " more text", " more text streaming"] {
            view.setContent("Before\n\n![chart](https://example.com/chart.png)\n\nAfter" + suffix, theme: theme)
        }
        XCTAssertTrue(view.sectionViews[1] === section, "The completed media section is kept while the answer grows")
        XCTAssertEqual(section.updateCount, updates)
        XCTAssertEqual(loader.requestCount, 1)
    }

    func testSingleImageIsBoundedByTheColumnAndMaximumHeightWithoutUpscaling() async throws {
        XCTAssertEqual(AgentResponseMedia.fittedSize(CGSize(width: 1600, height: 1200), width: 800), NSSize(width: 640, height: 480))
        XCTAssertEqual(AgentResponseMedia.fittedSize(CGSize(width: 1600, height: 1200), width: 300), NSSize(width: 300, height: 225))
        XCTAssertEqual(AgentResponseMedia.fittedSize(CGSize(width: 120, height: 40), width: 800), NSSize(width: 120, height: 40))
        XCTAssertEqual(AgentResponseMedia.fittedSize(nil, width: 200), NSSize(width: 200, height: 200), "Placeholder before the size is known")
        let bytes = try png(width: 1600, height: 1200)
        let (services, _) = services { _ in bytes }
        let view = response("![wide](https://example.com/wide.png)", services: services, width: 700)
        let host = window(with: view)
        defer { host.close() }
        let section = try XCTUnwrap(view.sectionViews.first as? AgentResponseMedia)
        try await wait { (section.tiles.first as? AgentMediaTile)?.image != nil }
        XCTAssertEqual(view.height(for: 700), 480)
        XCTAssertEqual(section.contentSize(for: 700), NSSize(width: 640, height: 480))
        XCTAssertEqual(view.height(for: 320), 240)
        XCTAssertEqual(section.contentSize(for: 320), NSSize(width: 320, height: 240))
    }

    func testCollagesMeasureAtTwoWidths() throws {
        let two = response("![a](a.png) ![b](b.png)", services: services { _ in Data() }.0)
        let five = response("a.png b.png c.png d.png e.png", services: services { _ in Data() }.0)
        let pair = try XCTUnwrap(two.sectionViews.first as? AgentResponseMedia)
        let grid = try XCTUnwrap(five.sectionViews.first as? AgentResponseMedia)
        XCTAssertEqual(pair.contentSize(for: 800), NSSize(width: 560, height: 240))
        XCTAssertEqual(pair.contentSize(for: 300), NSSize(width: 300, height: 240))
        XCTAssertEqual(grid.contentSize(for: 800), NSSize(width: 560, height: 3 * 160 + 4))
        XCTAssertEqual(grid.contentSize(for: 400).width, 400)
        five.frame.size.width = 400
        five.layoutSubtreeIfNeeded()
        XCTAssertEqual(grid.tiles.last?.frame.width, 400, "An odd last tile spans the collage")
        XCTAssertEqual(grid.tiles.map { $0.toolTip ?? "" }, ["a.png", "b.png", "c.png", "d.png", "e.png"])
    }

    func testFailedImageShowsTheUnavailableFrame() async throws {
        let (services, _) = services { _ in throw ModelError("404") }
        let view = response("![Build graph](https://example.com/missing.png)", services: services)
        let host = window(with: view)
        defer { host.close() }
        let tile = try XCTUnwrap((view.sectionViews.first as? AgentResponseMedia)?.tiles.first as? AgentMediaTile)
        try await wait { tile.accessibilityLabel()?.hasPrefix("Image unavailable") == true }
        XCTAssertEqual(tile.accessibilityLabel(), "Image unavailable · Build graph")
        XCTAssertNil(tile.image)
        XCTAssertFalse(tile.accessibilityPerformPress(), "A failed tile does not open an empty preview")
    }

    func testClickingATileOpensEveryImageOfTheMessageAsAGallery() async throws {
        let bytes = try png(width: 10, height: 10)
        let (services, _) = services { _ in bytes }
        var opened: ([AgentMarkdownMedia], Int)?
        services.previewMedia = { opened = ($0, $1) }
        var played: AgentMarkdownMedia?
        services.playMedia = { played = $0 }
        let web = "https://example.com/"
        let markdown = "Inline ![first](\(web)1.png) image.\n\n![second](\(web)2.png) ![third](\(web)3.png)\n\nclip.mp4\n\n> ![quoted](\(web)4.png)"
        let view = response(markdown, services: services)
        let host = window(with: view)
        defer { host.close() }
        let sections = view.sectionViews.compactMap { $0 as? AgentResponseMedia }
        XCTAssertEqual(sections.count, 2)
        let second = try XCTUnwrap(sections[0].tiles[1] as? AgentMediaTile)
        try await wait { second.image != nil }
        XCTAssertTrue(second.accessibilityPerformPress())
        XCTAssertEqual(opened?.0.map(\.alt), ["first", "second", "third", "quoted"])
        XCTAssertEqual(opened?.1, 2)
        sections[1].tiles[0].accessibilityPerformPress()
        XCTAssertEqual(played?.source, "clip.mp4")
    }

    func testContextMenusOfferImageAndLinkActions() throws {
        let (services, _) = services { _ in Data() }
        var openedLinks: [String] = []
        services.openLink = { openedLinks.append($0) }
        let view = response("![remote](https://example.com/a.png) ![inline](\(try dataURI()))\n\nhttps://example.com/b.mov", services: services)
        let tiles = view.sectionViews.compactMap { $0 as? AgentResponseMedia }.flatMap(\.tiles)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let remote = try XCTUnwrap(tiles[0].menu(for: event))
        XCTAssertEqual(remote.items.filter { !$0.isSeparatorItem }.map(\.title), ["Save image", "Copy image", "Copy link", "Open link"])
        let inline = try XCTUnwrap(tiles[1].menu(for: event))
        XCTAssertEqual(inline.items.map(\.title), ["Save image", "Copy image"], "A data: payload has no link")
        let video = try XCTUnwrap(tiles[2].menu(for: event))
        XCTAssertEqual(video.items.map(\.title), ["Copy link", "Open link"])
        let open = try XCTUnwrap(remote.items.first { $0.title == "Open link" })
        _ = (open.target as? NSObject)?.perform(open.action)
        XCTAssertEqual(openedLinks, ["https://example.com/a.png"])
    }

    func testInlineImagesBecomeClickableThumbnails() async throws {
        let bytes = try png(width: 30, height: 30)
        let (services, loader) = services { _ in bytes }
        var opened: ([AgentMarkdownMedia], Int)?
        services.previewMedia = { opened = ($0, $1) }
        let view = response("The icon ![app icon](https://example.com/icon.png) ships today.", services: services)
        let prose = try XCTUnwrap(view.sectionViews.first as? AgentResponseProse)
        let text = prose.text.attributedString()
        let index = (text.string as NSString).range(of: "\u{FFFC}").location
        XCTAssertNotEqual(index, NSNotFound)
        XCTAssertFalse(text.string.contains("app icon"), "The alternative text becomes the thumbnail's tooltip")
        XCTAssertEqual(text.attribute(.toolTip, at: index, effectiveRange: nil) as? String, "app icon")
        let cell = try XCTUnwrap(prose.inlineCells.first)
        XCTAssertLessThanOrEqual(cell.cellSize().height, 14 * 1.5)
        XCTAssertEqual(loader.requestCount, 0)
        let host = window(with: view)
        defer { host.close() }
        try await wait { cell.thumbnail != nil }
        _ = view.textView(prose.text, clickedOnLink: try XCTUnwrap(AgentInlineMedia.linkURL), at: index)
        XCTAssertEqual(opened?.0.map(\.alt), ["app icon"])
        XCTAssertEqual(opened?.1, 0)
        view.removeFromSuperview()
        XCTAssertNil(cell.thumbnail, "Thumbnails drop their pixels out of a window")
    }

    func testInlineImagesStayTextWithoutTheLoader() {
        let view = response("The icon ![app icon](https://example.com/icon.png) ships today.", services: nil)
        let prose = view.sectionViews.first as? AgentResponseProse
        XCTAssertEqual(prose?.text.string, "The icon app icon ships today.")
        XCTAssertEqual(prose?.inlineCells.count, 0)
    }
}

private actor Counter {
    private(set) var value = 0
    @discardableResult
    func increment() -> Int { value += 1; return value }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() async { lock.withLock { value = true } }
}
