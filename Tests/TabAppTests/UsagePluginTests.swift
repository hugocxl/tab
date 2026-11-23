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
        model.selectRightPanel("usage")
        XCTAssertEqual(model.rightPanel, "usage")
        XCTAssertNotNil(model.rightPanelContent("usage"))
        model.plugins.deactivate(.usage)
        XCTAssertTrue(model.rightSidebarPanels.isEmpty)
        XCTAssertEqual(PluginCatalog.descriptor(for: .usage)?.panelIds, ["usage"])
    }

    func testPanelShowsCardsAndWarnings() async throws {
        let (controller, _) = makePanel(Self.sample(now: Date()))
        try await settle { !controller.cards.isEmpty }
        XCTAssertEqual(controller.cards.map(\.usage.label), ["Session", "Weekly", "Weekly · Fable"])
        XCTAssertEqual(controller.warnings, ["Codex: Codex CLI is not authenticated. Run `codex login` and try again."])
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560), styleMask: [.borderless],
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
            AgentUsageLimits(provider: .claude, windows: [
                .init(id: "five_hour", kind: .session, label: "Session", usedPercent: 1, windowDurationMinutes: 300,
                      resetsAt: now.addingTimeInterval(4 * 3600 + 53 * 60)),
                .init(id: "seven_day", kind: .weekly, label: "Weekly", usedPercent: 53, windowDurationMinutes: 10_080,
                      resetsAt: now.addingTimeInterval(4 * 86_400 + 22 * 3600)),
                .init(id: "seven_day_fable", kind: .weekly, label: "Weekly · Fable", usedPercent: 32,
                      windowDurationMinutes: 10_080, resetsAt: now.addingTimeInterval(4 * 86_400 + 22 * 3600)),
            ]),
            AgentUsageLimits(provider: .codex, failure: "Codex CLI is not authenticated. Run `codex login` and try again."),
        ])
    }
}
