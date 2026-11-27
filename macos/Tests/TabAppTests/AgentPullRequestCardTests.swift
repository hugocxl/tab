import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentPullRequestCardTests: XCTestCase {
    private let theme = AppTheme(systemIsDark: false)
    private let github: Set<String> = ["github.com"]

    private func preview(state: GitPullRequestPreview.State = .open, draft: Bool = false, created: String = "2026-10-29T10:00:00Z") -> GitPullRequestPreview {
        GitPullRequestPreview(repository: "hugocxl/tab", number: 42, title: "Native pull-request cards", url: "https://github.com/hugocxl/tab/pull/42",
                              author: .init(login: "octocat", name: "Mona Lisa", avatarURL: nil), state: state, isDraft: draft, createdAt: created)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func window(with view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        return window
    }

    // MARK: Recognition

    func testBareAutolinkAndSelfLabelledGitHubLinksAreRecognized() {
        let markdown = "See https://github.com/hugocxl/tab/pull/42. Also <https://github.com/apple/swift/pull/7> and "
            + "[https://github.com/a/b/pull/3](https://github.com/a/b/pull/3), plus https://github.com/hugocxl/tab/pull/42 again."
        XCTAssertEqual(AgentPullRequestLink.urls(in: markdown, hosts: github).map(\.absoluteString), [
            "https://github.com/hugocxl/tab/pull/42", "https://github.com/apple/swift/pull/7", "https://github.com/a/b/pull/3",
        ])
    }

    func testLabelledLinksCodeSpansAndOtherURLsAreIgnored() {
        let markdown = "[the fix](https://github.com/a/b/pull/1), `https://github.com/a/b/pull/2`, https://github.com/a/b/issues/3, "
            + "https://github.com/a/b/pull/x, http://github.com/a/b/pull/4, https://gitlab.com/a/b/pull/5"
        XCTAssertEqual(AgentPullRequestLink.urls(in: markdown, hosts: github), [])
    }

    func testEnterpriseHostNeedsMatchingOrigin() {
        let markdown = "https://git.example.com/team/app/pull/9"
        XCTAssertEqual(AgentPullRequestLink.urls(in: markdown, hosts: github), [])
        for origin in ["git@git.example.com:team/app.git", "https://git.example.com/team/app.git", "ssh://git@Git.Example.com/team/app"] {
            XCTAssertEqual(AgentPullRequestLink.originHost(origin), "git.example.com", origin)
            XCTAssertEqual(AgentPullRequestLink.urls(in: markdown, hosts: AgentPullRequestLink.hosts(origin: origin)).count, 1, origin)
        }
        XCTAssertEqual(AgentPullRequestLink.hosts(origin: nil), ["github.com"])
        XCTAssertNil(AgentPullRequestLink.originHost("/local/path/repo"))
    }

    func testCardsFollowTheirParagraphButNotTablesOrCode() {
        let source = """
        Opened https://github.com/a/b/pull/1 for review.

        | PR |
        | --- |
        | https://github.com/a/b/pull/2 |

        ```
        https://github.com/a/b/pull/3
        ```

        - Follow-up: https://github.com/a/b/pull/4
        """
        let parts = AgentResponsePart.partition(AgentResponseParser.parse(source), pullRequestHosts: github)
        XCTAssertEqual(parts.map(\.kind), [0, 8, 2, 1, 0, 8])
        XCTAssertEqual(parts[1], .pullRequest("https://github.com/a/b/pull/1"))
        XCTAssertEqual(parts[5], .pullRequest("https://github.com/a/b/pull/4"))
        XCTAssertFalse(AgentResponsePart.partition(AgentResponseParser.parse(source)).contains { $0.kind == 6 }, "No hosts, no cards")
    }

    // MARK: Card content

    func testCardContentForEveryState() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/hugocxl/tab/pull/42"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z"))
        let open = AgentPullRequestCardContent.make(url: url, state: .loaded(preview()), now: now)
        XCTAssertEqual(open.style, .loaded)
        XCTAssertEqual(open.title, "Native pull-request cards")
        XCTAssertEqual(open.status, .open)
        XCTAssertEqual(open.statusLabel, "Open")
        XCTAssertEqual(open.initials, "ML")
        XCTAssertTrue(open.detail.hasPrefix("hugocxl/tab #42 · octocat · "), open.detail)
        XCTAssertTrue(open.detail.contains("3 days ago"), open.detail)
        XCTAssertEqual(AgentPullRequestCardContent.make(url: url, state: .loaded(preview(draft: true)), now: now).status, .draft)
        XCTAssertEqual(AgentPullRequestCardContent.make(url: url, state: .loaded(preview(state: .closed, draft: true)), now: now).status, .closed)
        XCTAssertEqual(AgentPullRequestCardContent.make(url: url, state: .loaded(preview(state: .merged)), now: now).statusLabel, "Merged")
        let loading = AgentPullRequestCardContent.make(url: url, state: .loading)
        XCTAssertEqual(loading.style, .loading)
        XCTAssertEqual(loading.title, "hugocxl/tab #42")
        XCTAssertNil(loading.status)
    }

    func testStateColorsComeFromTheTheme() {
        XCTAssertEqual(AgentResponsePullRequest.color(.open, theme: theme), theme.diffAdd)
        XCTAssertEqual(AgentResponsePullRequest.color(.closed, theme: theme), theme.danger)
        XCTAssertEqual(AgentResponsePullRequest.color(.draft, theme: theme), theme.fgMuted)
        XCTAssertNotEqual(AgentResponsePullRequest.color(.merged, theme: theme), theme.diffAdd)
    }

    func testInitialsAndUnreadableDates() {
        XCTAssertEqual(AgentPullRequestCardContent.initials(login: "octocat", name: nil), "O")
        XCTAssertEqual(AgentPullRequestCardContent.initials(login: "octocat", name: "Ada"), "A")
        XCTAssertEqual(AgentPullRequestCardContent.initials(login: "", name: nil), "?")
        XCTAssertNil(AgentPullRequestCardContent.relativeDate("yesterday", now: Date()))
        XCTAssertNotNil(AgentPullRequestCardContent.relativeDate("2026-10-29T10:00:00.123Z", now: Date()))
    }

    // MARK: Lazy requests

    func testCardsRequestLazilyOncePerURLAndShareTheResult() async throws {
        let services = AgentConversationLinkServices()
        var calls: [String] = []
        services.pullRequests.fetch = { [unowned self] url in calls.append(url); return self.preview() }
        let first = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 500, height: 10))
        let second = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 500, height: 10))
        for view in [first, second] {
            view.linkServices = services
            view.setContent("Merged in https://github.com/hugocxl/tab/pull/42", theme: theme)
        }
        XCTAssertEqual(services.pullRequests.requestCount, 0, "Nothing is requested before a card is materialized in a window")
        let host = window(with: first)
        host.contentView?.addSubview(second)
        await settle()
        XCTAssertEqual(calls, ["https://github.com/hugocxl/tab/pull/42"])
        for view in [first, second] {
            let card = try XCTUnwrap(view.sectionViews.compactMap { $0 as? AgentResponsePullRequest }.first)
            XCTAssertEqual(card.content?.style, .loaded)
            XCTAssertEqual(card.content?.title, "Native pull-request cards")
        }
        let third = AgentResponseView(frame: .zero)
        third.linkServices = services
        third.setContent("https://github.com/hugocxl/tab/pull/42", theme: theme)
        host.contentView?.addSubview(third)
        XCTAssertEqual(services.pullRequests.requestCount, 1, "Cached for the conversation")
        XCTAssertEqual((third.sectionViews.last as? AgentResponsePullRequest)?.content?.style, .loaded)
        services.reset()
        XCTAssertNil(services.pullRequests.state(for: "https://github.com/hugocxl/tab/pull/42"))
    }

    func testRemovingTheLastCardCancelsItsPendingRequest() async throws {
        let services = AgentConversationLinkServices()
        var cancelled = false
        services.pullRequests.fetch = { _ in
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled = true; throw error }
            throw ModelError("unreachable")
        }
        let view = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 500, height: 10))
        view.linkServices = services
        view.setContent("https://github.com/a/b/pull/1", theme: theme)
        let host = window(with: view)
        await settle()
        XCTAssertEqual(services.pullRequests.state(for: "https://github.com/a/b/pull/1"), .loading)
        view.removeFromSuperview()
        await settle()
        XCTAssertTrue(cancelled)
        XCTAssertNil(services.pullRequests.state(for: "https://github.com/a/b/pull/1"), "A cancelled request is not cached")
        host.contentView?.addSubview(view)
        XCTAssertEqual(services.pullRequests.requestCount, 2, "Materialized again, the card requests again")
    }

    func testFailureFallsBackToAPlainLinkWithTheErrorAsTooltip() async throws {
        let services = AgentConversationLinkServices()
        services.pullRequests.fetch = { _ in throw ModelError("Update this project’s server.") }
        let view = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 500, height: 10))
        view.linkServices = services
        view.setContent("https://github.com/a/b/pull/1", theme: theme)
        let host = window(with: view)
        await settle()
        let card = try XCTUnwrap(view.sectionViews.last as? AgentResponsePullRequest)
        XCTAssertEqual(card.content?.style, .failed)
        XCTAssertEqual(card.content?.title, "https://github.com/a/b/pull/1")
        XCTAssertEqual(card.toolTip, "Update this project’s server.")
        XCTAssertEqual(card.measuredHeight(for: 500), AgentResponsePullRequest.height, "Every state keeps the card height")
        host.close()
    }

    func testClickingTheCardOpensTheLinkThroughTheActions() throws {
        let services = AgentConversationLinkServices()
        var opened: [String] = []
        services.openLink = { opened.append($0) }
        let view = AgentResponseView(frame: .zero)
        view.linkServices = services
        view.setContent("https://github.com/a/b/pull/1", theme: theme)
        let card = try XCTUnwrap(view.sectionViews.last as? AgentResponsePullRequest)
        XCTAssertTrue(card.accessibilityPerformPress())
        XCTAssertEqual(opened, ["https://github.com/a/b/pull/1"])
    }

    func testThemeChangeRepaintsACardWithUnchangedContent() throws {
        let catalog = ThemeCatalog.load(customDirectory: nil)
        let light = AppTheme(catalog: catalog, systemIsDark: false)
        let dark = AppTheme(catalog: catalog, systemIsDark: true)
        let view = AgentResponseView(frame: .zero)
        view.linkServices = AgentConversationLinkServices()
        view.setContent("Opened https://github.com/a/b/pull/1", theme: light)
        let card = try XCTUnwrap(view.sectionViews.last as? AgentResponsePullRequest)
        let before = try XCTUnwrap(card.layer?.backgroundColor)
        view.setContent("Opened https://github.com/a/b/pull/1", theme: dark)
        let after = try XCTUnwrap(card.layer?.backgroundColor)
        XCTAssertNotEqual(before, after, "A theme change repaints a card whose content did not change")
    }

    func testFailedRequestsExpireWithTheirObserversAndAfterThirtySeconds() async throws {
        let cache = AgentLazyRequestCache<Int>()
        var calls = 0
        var clock = Date(timeIntervalSince1970: 1_000)
        cache.now = { clock }
        cache.fetch = { _ in calls += 1; throw ModelError("offline") }
        let first = cache.observe("a") { _ in }
        await settle()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(cache.state(for: "a"), .failed("offline"))
        clock.addTimeInterval(10)
        let second = cache.observe("a") { _ in }
        XCTAssertEqual(calls, 1, "A recent failure is served from the cache")
        clock.addTimeInterval(25)
        let third = cache.observe("a") { _ in }
        await settle()
        XCTAssertEqual(calls, 2, "A subscription after 30 seconds retries")
        first.cancel(); second.cancel(); third.cancel()
        XCTAssertNil(cache.state(for: "a"), "The last observer leaving drops the failure")
        let fourth = cache.observe("a") { _ in }
        await settle()
        XCTAssertEqual(calls, 3)
        fourth.cancel()
    }

    // MARK: Measurement and reuse

    func testCardIsAMeasuredSectionReusedWhileStreaming() throws {
        let services = AgentConversationLinkServices()
        let view = AgentResponseView(frame: .zero)
        view.linkServices = services
        view.setContent("Opened https://github.com/a/b/pull/1", theme: theme)
        let card = try XCTUnwrap(view.sectionViews.last as? AgentResponsePullRequest)
        let height = view.height(for: 500)
        XCTAssertEqual(card.frame.height, AgentResponsePullRequest.height)
        XCTAssertGreaterThan(height, AgentResponsePullRequest.height)
        let measurements = card.measurementCount
        _ = view.height(for: 500)
        XCTAssertEqual(card.measurementCount, measurements, "Unchanged width reuses the measurement")
        view.setContent("Opened https://github.com/a/b/pull/1\n\nNow running the tests", theme: theme)
        XCTAssertTrue(view.sectionViews[1] === card, "Streaming keeps the card view")
        XCTAssertEqual(card.updateCount, 1)
    }

    func testOriginHostChangeAddsEnterpriseCards() {
        let services = AgentConversationLinkServices()
        let view = AgentResponseView(frame: .zero)
        view.linkServices = services
        view.setContent("> Quoted https://git.example.com/a/b/pull/1", theme: theme)
        let container = view.sectionViews.first as? AgentResponseContainer
        XCTAssertFalse(container?.response.sectionViews.contains { $0 is AgentResponsePullRequest } ?? true)
        services.pullRequestHosts = AgentPullRequestLink.hosts(origin: "git@git.example.com:a/b.git")
        view.setContent("> Quoted https://git.example.com/a/b/pull/1", theme: theme)
        XCTAssertTrue(container?.response.sectionViews.contains { $0 is AgentResponsePullRequest } ?? false)
    }
}
