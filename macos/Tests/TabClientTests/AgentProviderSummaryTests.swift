import XCTest
@testable import TabClient
import TabProtocol

final class AgentProviderSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var later: Date { now.addingTimeInterval(3600) }

    private func health(_ id: String, installed: Bool = true, auth: AgentProviderHealth.Auth = .signedIn) -> AgentProviderHealth {
        AgentProviderHealth(provider: id, installed: installed, auth: auth, checkedAt: now, signInCommand: "claude /login")
    }

    private func usage(_ windows: [AgentUsageWindow], id: String? = "claude") -> AgentUsageLimits {
        AgentUsageLimits(provider: .claude, providerId: id, plan: "Max", windows: windows, checkedAt: now)
    }

    func testAProviderThatCantRunWorkIsRefusedWithWhatToDo() {
        let claude = AgentProviderConfig.builtIn(.claude)
        XCTAssertNil(AgentProviderSummary.refusal(claude, health: health("claude"), usage: nil, model: nil, now: now))
        // Nothing checked yet says nothing against it.
        XCTAssertNil(AgentProviderSummary.refusal(claude, health: nil, usage: nil, model: nil, now: now))
        var off = claude
        off.enabled = false
        XCTAssertNotNil(AgentProviderSummary.refusal(off, health: health("claude"), usage: nil, model: nil, now: now))
        XCTAssertNotNil(AgentProviderSummary.refusal(claude, health: health("claude", installed: false), usage: nil,
                                                     model: nil, now: now))
        let signedOut = AgentProviderSummary.refusal(claude, health: health("claude", auth: .signedOut), usage: nil,
                                                     model: nil, now: now)
        XCTAssertTrue(signedOut?.contains("claude /login") ?? false)
    }

    func testOnlyASpentWindowThatHasntResetStopsAModel() {
        let claude = AgentProviderConfig.builtIn(.claude)
        let spent = AgentUsageWindow(id: "five_hour", kind: .session, label: "Session", usedPercent: 100, resetsAt: later)
        let reset = AgentUsageWindow(id: "five_hour", kind: .session, label: "Session", usedPercent: 100,
                                     resetsAt: now.addingTimeInterval(-60))
        let near = AgentUsageWindow(id: "seven_day", kind: .weekly, label: "Weekly", usedPercent: 99, resetsAt: later)
        let spend = AgentUsageWindow(id: "monthly_spend", kind: .monthly, label: "Monthly spend", usedPercent: 100)
        let fable = AgentUsageWindow(id: "seven_day_fable", kind: .weekly, label: "Weekly · Fable", usedPercent: 100,
                                     resetsAt: later)

        XCTAssertNotNil(AgentProviderSummary.refusal(claude, health: health("claude"), usage: usage([spent]),
                                                     model: nil, now: now))
        for windows in [[reset], [near], [spend]] {
            XCTAssertNil(AgentProviderSummary.refusal(claude, health: health("claude"), usage: usage(windows),
                                                      model: nil, now: now), "\(windows)")
        }
        // A window for one model stops only that model.
        XCTAssertNil(AgentProviderSummary.spentWindow(usage([fable]), model: nil, now: now))
        XCTAssertNil(AgentProviderSummary.spentWindow(usage([fable]), model: "claude-opus-5-5", now: now))
        XCTAssertEqual(AgentProviderSummary.spentWindow(usage([fable]), model: "claude-fable-5-2", now: now)?.id,
                       "seven_day_fable")
        XCTAssertEqual(AgentProviderSummary(config: claude, health: health("claude"), usage: usage([spent, near]),
                                            models: nil).status(now: now).hasPrefix("limit reached until"), true)
    }

    func testProvidersSignedInToOneAccountShareItsReading() {
        let first = AgentProviderConfig(id: "claude", kind: .claude, home: "~/.claude-work")
        let second = AgentProviderConfig(id: "claude-review", kind: .claude, home: "~/.claude-work")
        let other = AgentProviderConfig(id: "claude-home", kind: .claude, home: "~/.claude-home")
        let providers = [first, second, other]
        let read = [usage([], id: "claude")]
        XCTAssertEqual(AgentProviderSummary.usage(for: second, in: read, providers: providers)?.providerId, "claude")
        XCTAssertNil(AgentProviderSummary.usage(for: other, in: read, providers: providers))
        // Servers that read one account per kind name no provider; it belongs to the built-in one.
        let legacy = [usage([], id: nil)]
        XCTAssertNotNil(AgentProviderSummary.usage(for: first, in: legacy, providers: providers))
        XCTAssertNil(AgentProviderSummary.usage(for: other, in: legacy, providers: providers))
    }

    func testTheLineKeepsTheEmailOutAndShortensLongModelLists() {
        var signedIn = health("claude")
        signedIn.account = "Claude Max subscription"
        signedIn.email = "someone@example.com"
        let models = (1 ... 10).map { AgentModelDescriptor(id: "m\($0)", title: "M\($0)", reasoningEfforts: [], isDefault: $0 == 1) }
        let summary = AgentProviderSummary(config: .builtIn(.claude), health: signedIn, usage: nil, models: models)
        XCTAssertFalse(summary.row(now: now).description.contains("someone@example.com"))
        XCTAssertTrue(summary.record(now: now).description.contains("someone@example.com"))
        XCTAssertEqual(summary.modelsText, "m1 (default), m2, m3, m4, m5, m6, m7, m8, +2 more")
        XCTAssertEqual(summary.usageText, "unknown")
        let idle = AgentUsageWindow(id: "s", kind: .session, label: "Session", usedPercent: 0,
                                    resetsAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(AgentProviderSummary(config: .builtIn(.claude), health: nil, usage: usage([idle]), models: nil)
            .usageText(now: now), "Session 0%")
        XCTAssertEqual(AgentProviderSummary(config: .builtIn(.kiro), health: nil, usage: nil, models: nil).usageText,
                       "not reported")
    }
}
