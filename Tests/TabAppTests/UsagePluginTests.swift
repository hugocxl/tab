import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp
@testable import TabUsagePlugin

@MainActor
final class UsagePluginTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func window(_ id: String, used: Double, minutes: Int?, resetsIn: TimeInterval?) -> AgentUsageWindow {
        AgentUsageWindow(id: id, kind: .weekly, label: id, usedPercent: used, windowDurationMinutes: minutes,
                         resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    func testPaceComparesSpendingWithTimeGone() {
        let week = 7 * 24 * 60
        // Two days into a week: about 29% of the time is gone.
        let fiveDaysLeft: TimeInterval = 5 * 86_400
        XCTAssertEqual(UsageMath.pace(window("a", used: 53, minutes: week, resetsIn: fiveDaysLeft), now: now), .ahead)
        XCTAssertEqual(UsageMath.pace(window("b", used: 30, minutes: week, resetsIn: fiveDaysLeft), now: now), .on)
        XCTAssertEqual(UsageMath.pace(window("c", used: 5, minutes: week, resetsIn: fiveDaysLeft), now: now), .under)
        XCTAssertEqual(UsageMath.paceRemainingPercent(window("d", used: 0, minutes: week, resetsIn: fiveDaysLeft), now: now), 71)
        XCTAssertNil(UsageMath.pace(window("e", used: 10, minutes: nil, resetsIn: fiveDaysLeft), now: now))
        XCTAssertNil(UsageMath.pace(window("f", used: 10, minutes: week, resetsIn: nil), now: now))
    }

    func testCountdownsMatchT3Code() {
        XCTAssertEqual(UsageMath.duration(4 * 86_400 + 22 * 3600 + 59), "4d 22h")
        XCTAssertEqual(UsageMath.duration(4 * 3600 + 53 * 60), "4h 53m")
        XCTAssertEqual(UsageMath.duration(59), "0m")
        XCTAssertEqual(UsageMath.resetsIn(window("a", used: 0, minutes: 300, resetsIn: -5), now: now), "now")
        XCTAssertEqual(UsageMath.remainingPercent(window("b", used: 0.6, minutes: nil, resetsIn: nil)), 99)
    }

    func testActivatingAddsTheUsagePanel() throws {
        let dirs = try ModelFixtures.profile()
        addTeardownBlock { try? FileManager.default.removeItem(at: dirs.root) }
        let model = AppModel(dirs: dirs, theme: AppTheme(systemIsDark: true)) { _, _ in nil }
        model.plugins.activate(plugin: UsagePlugin())
        XCTAssertEqual(model.rightSidebarPanels.map(\.id), ["usage"])
        XCTAssertEqual(model.sidebarFooterItems.map(\.id), ["usage-summary"])
        model.selectRightPanel("usage")
        XCTAssertEqual(model.rightPanel, "usage")
        XCTAssertNotNil(model.rightPanelContent("usage"))
        model.plugins.deactivate(.usage)
        XCTAssertTrue(model.rightSidebarPanels.isEmpty)
        XCTAssertTrue(model.sidebarFooterItems.isEmpty)
        XCTAssertEqual(PluginCatalog.descriptor(for: .usage)?.panelIds, ["usage"])
    }

    func testSidebarFooterButtonTogglesFloatingCardAndCleansUpOnDeactivate() async throws {
        let dirs = try ModelFixtures.profile()
        addTeardownBlock { try? FileManager.default.removeItem(at: dirs.root) }
        let model = AppModel(dirs: dirs, theme: AppTheme(systemIsDark: true)) { _, _ in nil }
        let sidebar = SidebarViewController(model: model)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 270, height: 600)
        sidebar.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(sidebar.pluginFooterButtonIds.isEmpty)
        XCTAssertFalse(sidebar.isFooterCardOpen)

        model.plugins.activate(plugin: UsagePlugin())
        try await settle { sidebar.pluginFooterButtonIds == ["usage-summary"] }

        sidebar.toggleFooterCard("usage-summary")
        XCTAssertTrue(sidebar.isFooterCardOpen)

        sidebar.toggleFooterCard("usage-summary")
        XCTAssertFalse(sidebar.isFooterCardOpen)

        sidebar.toggleFooterCard("usage-summary")
        XCTAssertTrue(sidebar.isFooterCardOpen)

        model.plugins.deactivate(.usage)
        try await settle { sidebar.pluginFooterButtonIds.isEmpty && !sidebar.isFooterCardOpen }
    }

    func testCompactCardShowsCompressedUsageAndSharesStoreWithPanel() async throws {
        let theme = AppTheme(systemIsDark: true)
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(server: identity, home: home.id, revision: 1, projects: [home]))
        server.usageLimits = Self.sample(now: Date())
        let store = UsageStore()

        let card = UsageCompactCardController(theme: theme, store: store) { _ in (server, nil) }
        card.show(project: (ProjectId(), identity))
        try await settle { !card.rows.isEmpty }
        XCTAssertEqual(card.rows.map { $0.limits.providerId }, ["claude-side", "codex", "claude", "grok"])
        XCTAssertEqual(card.rows.first?.tone, .low)
        XCTAssertEqual(card.rows.first?.bar?.fraction, 0.86)
        XCTAssertNil(card.rows.last?.bar)
        XCTAssertGreaterThan(card.preferredHeight(forWidth: 250), 120)

        card.apply(UsageConfig(order: .provider, figure: .left))
        XCTAssertEqual(card.rows.map { $0.limits.providerId }, ["claude", "claude-side", "codex", "grok"])
        XCTAssertEqual(card.rows[1].bar?.fraction, 0.14)

        // Opening the right-sidebar panel with the same store sees the cached reading immediately.
        let panel = UsagePanelController(theme: theme, store: store) { _ in (server, nil) }
        panel.show(project: (ProjectId(), identity))
        XCTAssertEqual(panel.cards.count, 4)
    }

    func testPanelShowsOneCardPerAccountClosestToItsLimitFirst() async throws {
        let (controller, _) = makePanel(Self.sample(now: Date()))
        try await settle { !controller.cards.isEmpty }
        XCTAssertEqual(controller.cards.map { $0.limits.providerId }, ["claude-side", "codex", "claude", "grok"])
        let side = try XCTUnwrap(controller.cards.first)
        XCTAssertEqual(side.rows.map(\.usage.label), ["Weekly"])
        XCTAssertEqual(side.rows.first?.tone, .low)
        XCTAssertEqual(side.rows.first?.bar.fraction, 0.86)
        XCTAssertEqual(controller.toolbar.chipTitles, ["All", "Claude", "Codex", "Grok"])
        XCTAssertEqual(controller.cards.last?.limits.failure, "Grok is not signed in. Run `grok login` and try again.")
    }

    func testChipsSwitchesAndDetailsChangeTheCards() async throws {
        let (controller, _) = makePanel(Self.sample(now: Date()))
        try await settle { !controller.cards.isEmpty }
        controller.toolbar.onFilter?(.claude)
        XCTAssertEqual(controller.cards.map { $0.limits.providerId }, ["claude-side", "claude"])
        controller.toolbar.onOrder?(.provider)
        XCTAssertEqual(controller.cards.map { $0.limits.providerId }, ["claude", "claude-side"])
        controller.toolbar.onFigure?(.left)
        XCTAssertEqual(controller.cards.last?.rows.first?.bar.fraction, 0.14)
        controller.cards.last?.onToggle?()
        XCTAssertEqual(controller.cards.last?.rows.map(\.usage.label), ["Weekly", "Session"])
        controller.toolbar.onFilter?(nil)
        XCTAssertEqual(controller.cards.count, 4)
    }

    func testSettingsChooseTheScheduleAndDefaults() throws {
        let decoded = try JSONDecoder().decode(UsageConfig.self, from: Data(#"{"refreshMinutes":-3,"order":"sideways","lowThreshold":99}"#.utf8))
        XCTAssertEqual(decoded, UsageConfig(refreshMinutes: 0, order: .urgency, figure: .used, lowThreshold: 90))
        XCTAssertEqual(UsageConfig.refreshTitle(5), "Every 5 minutes")
        let controller = UsagePanelController(theme: AppTheme(systemIsDark: true)) { _ in nil }
        controller.apply(UsageConfig(refreshMinutes: 15, order: .provider, figure: .left))
        XCTAssertEqual(controller.order, .provider)
        XCTAssertEqual(controller.figure, .left)
    }

    func testWordingFollowsHeadroom() {
        XCTAssertEqual(UsageMath.spelledDuration(3 * 86_400 + 12 * 3600 + 59), "3 days 12 h")
        XCTAssertEqual(UsageMath.spelledDuration(4 * 3600 + 12 * 60), "4 h 12 min")
        XCTAssertEqual(UsageMath.ago(now.addingTimeInterval(-7 * 60 - 5), now: now), "7 min ago")
        XCTAssertEqual(UsageMath.tone(window("a", used: 86, minutes: nil, resetsIn: nil), lowThreshold: 30), .low)
        XCTAssertEqual(UsageMath.tone(window("b", used: 95, minutes: nil, resetsIn: nil), lowThreshold: 30), .almostOut)
        XCTAssertEqual(UsageMath.tone(window("c", used: 100, minutes: nil, resetsIn: nil), lowThreshold: 30), .over)
        XCTAssertEqual(UsageMath.tone(window("d", used: 63, minutes: nil, resetsIn: nil), lowThreshold: 30), .fine)
    }

    func testOldServerSaysItCannotReportUsage() async throws {
        let (controller, _) = makePanel(nil)
        try await settle { controller.messageText.contains("too old") }
    }

    /// Renders the panel to a PNG for visual review. Runs only with `TAB_SNAPSHOT_DIR` set.
    func testRenderUsagePanel() async throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TAB_SNAPSHOT_DIR to render snapshots")
        }
        _ = NSApplication.shared
        for (dark, width) in [(true, 300.0), (false, 300.0), (true, 480.0)] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let (controller, _) = makePanel(Self.sample(now: Date()), theme: theme)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 720), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let background = ThemedBackground(color: { $0.card })
            background.theme = theme
            window.contentView = background
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: background.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            ])
            try await settle { !controller.cards.isEmpty }
            if width > 400 { controller.cards.first?.onToggle?() }
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "\(output)/usage-panel-\(dark ? "dark" : "light")-\(Int(width)).png"))
        }
    }

    private func makePanel(_ reply: AgentUsageLimitsReply?, theme: AppTheme? = nil) -> (UsagePanelController, ModelFakeServer) {
        let theme = theme ?? AppTheme(systemIsDark: true)
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(server: identity, home: home.id, revision: 1, projects: [home]))
        server.usageLimits = reply
        let controller = UsagePanelController(theme: theme) { _ in (server, nil) }
        controller.show(project: (ProjectId(), identity))
        return (controller, server)
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }

    static func sample(now: Date) -> AgentUsageLimitsReply {
        AgentUsageLimitsReply(providers: [
            AgentUsageLimits(provider: .claude, providerId: "claude", plan: "Team", account: "leila.quist@example.net", windows: [
                .init(id: "five_hour", kind: .session, label: "Session", usedPercent: 1, windowDurationMinutes: 300,
                      resetsAt: now.addingTimeInterval(4 * 3600 + 53 * 60)),
                .init(id: "seven_day", kind: .weekly, label: "Weekly", usedPercent: 53, windowDurationMinutes: 10_080,
                      resetsAt: now.addingTimeInterval(4 * 86_400 + 22 * 3600)),
            ], checkedAt: now.addingTimeInterval(-7 * 60)),
            AgentUsageLimits(provider: .claude, providerId: "claude-side", providerName: "Side project", plan: "Pro",
                             account: "leila.quist@example.net", windows: [
                .init(id: "seven_day", kind: .weekly, label: "Weekly", usedPercent: 86, windowDurationMinutes: 10_080,
                      resetsAt: now.addingTimeInterval(3 * 86_400 + 12 * 3600)),
                .init(id: "five_hour", kind: .session, label: "Session", usedPercent: 40, windowDurationMinutes: 300,
                      resetsAt: now.addingTimeInterval(2 * 3600)),
            ], checkedAt: now.addingTimeInterval(-7 * 60)),
            AgentUsageLimits(provider: .codex, providerId: "codex", plan: "Plus", account: "leilaquist@example.com", windows: [
                .init(id: "secondary", kind: .weekly, label: "Weekly", usedPercent: 63, windowDurationMinutes: 10_080,
                      resetsAt: now.addingTimeInterval(2 * 86_400 + 4 * 3600)),
            ], checkedAt: now.addingTimeInterval(-6 * 60)),
            AgentUsageLimits(provider: .grok, providerId: "grok", failure: "Grok is not signed in. Run `grok login` and try again.",
                             checkedAt: now.addingTimeInterval(-6 * 60)),
        ])
    }
}
