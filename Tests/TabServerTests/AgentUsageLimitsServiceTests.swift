import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class AgentUsageLimitsServiceTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_795_000_000)

    /// Trimmed from Claude Code 2.1's `get_usage` reply for a team plan.
    func testClaudeUsageBecomesSessionWeeklyAndModelWindows() throws {
        let json = """
        {"subscription_type":"team","rate_limits_available":true,"rate_limits":{
          "five_hour":{"utilization":7,"resets_at":"2026-11-23T19:20:00.842272+00:00"},
          "seven_day":{"utilization":54,"resets_at":"2026-11-28T13:00:00.842295+00:00"},
          "seven_day_opus":null,
          "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null},
          "spend":{"used":{"amount_minor":0,"currency":"USD","exponent":2},"limit":null,"enabled":false},
          "model_scoped":[{"display_name":"Fable","utilization":32,"resets_at":"2026-11-28T12:59:59.842452+00:00"}]
        }}
        """
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let limits = AgentUsageLimitsService.claudeLimits(response, checkedAt: checkedAt)
        XCTAssertNil(limits.failure)
        XCTAssertEqual(limits.windows.map(\.id), ["five_hour", "seven_day", "seven_day_fable"])
        XCTAssertEqual(limits.windows.map(\.label), ["Session", "Weekly", "Weekly · Fable"])
        XCTAssertEqual(limits.windows.map(\.usedPercent), [7, 54, 32])
        XCTAssertEqual(limits.windows.map(\.windowDurationMinutes), [300, 10_080, 10_080])
        XCTAssertEqual(limits.windows[0].resetsAt?.timeIntervalSince1970 ?? 0, 1_795_461_600.84, accuracy: 0.01)
        XCTAssertNoThrow(try AgentUsageLimitsReply(providers: [limits]).validate())
    }

    func testClaudeWithoutSubscriptionExplainsSignIn() {
        let limits = AgentUsageLimitsService.claudeLimits(["rate_limits_available": false, "rate_limits": NSNull()], checkedAt: checkedAt)
        XCTAssertTrue(limits.windows.isEmpty)
        XCTAssertNotNil(limits.failure)
    }

    func testClaudeEnabledSpendAddsMonthlyWindow() {
        let limits = AgentUsageLimitsService.claudeLimits(["rate_limits_available": true, "rate_limits": [
            "spend": ["enabled": true, "used": ["amount_minor": 2500, "currency": "USD", "exponent": 2],
                      "limit": ["amount_minor": 10_000, "currency": "USD", "exponent": 2]],
        ]], checkedAt: checkedAt)
        XCTAssertEqual(limits.windows.map(\.id), ["monthly_spend"])
        XCTAssertEqual(limits.windows.first?.usedPercent, 25)
    }

    func testCodexRateLimitsPreferTheCodexBucket() {
        let result: [String: Any] = [
            "rateLimits": ["limitId": "other", "primary": ["usedPercent": 90]],
            "rateLimitsByLimitId": ["codex": [
                "limitId": "codex", "planType": "pro",
                "primary": ["usedPercent": 61, "windowDurationMins": 300, "resetsAt": 1_777_429_830],
                "secondary": ["usedPercent": 23, "windowDurationMins": 10_080, "resetsAt": 1_777_959_590],
            ]],
        ]
        let limits = AgentUsageLimitsService.codexLimits(result, checkedAt: checkedAt)
        XCTAssertEqual(limits.windows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(limits.windows.map(\.usedPercent), [61, 23])
        XCTAssertEqual(limits.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_777_429_830))
    }

    func testCodexFreePlanPrimaryIsMonthly() {
        let limits = AgentUsageLimitsService.codexLimits(["rateLimits": ["planType": "free", "primary": ["usedPercent": 10]]],
                                                         checkedAt: checkedAt)
        XCTAssertEqual(limits.windows.first?.kind, .monthly)
        XCTAssertEqual(limits.windows.first?.label, "Monthly")
    }

    /// Codex 0.13x answers an expired login with a JSON-RPC error naming the 401.
    func testCodexExpiredTokenAsksToSignIn() {
        let message = "failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized; body={\"code\":\"token_expired\"}"
        XCTAssertEqual(AgentUsageLimitsService.codexFailure(message),
                       "Codex CLI is not authenticated. Run `codex login` and try again.")
    }

    /// Trimmed from Antigravity CLI 1.5.16's `agy -p /usage --output-format json`.
    func testAntigravityGroupsBecomeSessionAndWeeklyWindows() throws {
        let json = """
        {"status":"SUCCESS","response":"","command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","buckets":[
            {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.75,"reset_time":"2026-12-01T10:04:38Z"},
            {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.8,"reset_time":"2026-11-24T15:04:38Z"}]},
          {"name":"Claude and GPT models","buckets":[
            {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-12-01T10:53:02Z"},
            {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","reset_time":"2026-11-24T15:53:02Z"}]}]}}}
        """
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let limits = AgentUsageLimitsService.antigravityLimits(output, checkedAt: checkedAt)
        XCTAssertNil(limits.failure)
        XCTAssertEqual(limits.windows.map(\.id), ["gemini-5h", "gemini-weekly", "3p-weekly"])
        XCTAssertEqual(limits.windows.map(\.label), ["Session · Gemini Models", "Weekly · Gemini Models", "Weekly · Claude and GPT models"])
        XCTAssertEqual(limits.windows.map(\.usedPercent).map { $0.rounded() }, [20, 25, 0])
        XCTAssertEqual(limits.windows.map(\.windowDurationMinutes), [300, 10_080, 10_080])
        XCTAssertEqual(limits.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-11-24T15:04:38Z"))
        XCTAssertNoThrow(try AgentUsageLimitsReply(providers: [limits]).validate())
    }

    func testOpenCodeGoWindowsAndBudgets() {
        let output: [String: Any] = ["data": [
            "workspace": ["id": "wrk_1"],
            "go": ["rolling": ["percent": 40, "limited": false, "resetsAt": 1_795_000_000_000],
                   "weekly": ["percent": 12, "limited": true, "resetsAt": 1_795_100_000_000]],
            "budgets": [["id": "rule_1", "limit": 50, "spent": 10, "per": "month", "resetsAt": 1_796_000_000_000]],
        ]]
        let limits = AgentUsageLimitsService.openCodeLimits(output, checkedAt: checkedAt)
        XCTAssertEqual(limits?.windows.map(\.id), ["rolling", "weekly", "budget_rule_1"])
        XCTAssertEqual(limits?.windows.map(\.usedPercent), [40, 100, 20])
        XCTAssertEqual(limits?.windows.last?.kind, .monthly)
        XCTAssertEqual(limits?.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_795_000_000))
    }

    /// Without an OpenCode Console sign-in, `experimental.usage.limits` answers `data: null`.
    func testOpenCodeWithoutConsoleIsLeftOut() {
        XCTAssertNil(AgentUsageLimitsService.openCodeLimits(["data": NSNull()], checkedAt: checkedAt))
    }

    /// The fixture values from grok-build's own `x.ai/billing` tests.
    func testGrokCreditsBecomeWeeklyAndOnDemandWindows() {
        let result: [String: Any] = [
            "config": ["creditUsagePercent": 42.5,
                       "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2025-04-01T00:00:00Z",
                                         "end": "2025-04-08T00:00:00Z"],
                       "onDemandCap": ["val": 500], "onDemandUsed": ["val": 125], "prepaidBalance": ["val": 100]],
            "on_demand_enabled": true, "subscription_tier": "SuperGrok",
        ]
        let limits = AgentUsageLimitsService.grokLimits(result, checkedAt: checkedAt)
        XCTAssertEqual(limits.windows.map(\.id), ["credits", "on_demand"])
        XCTAssertEqual(limits.windows.map(\.kind), [.weekly, .monthly])
        XCTAssertEqual(limits.windows.map(\.usedPercent), [42.5, 25])
        XCTAssertEqual(limits.windows.first?.windowDurationMinutes, 10_080)
        XCTAssertEqual(limits.windows.first?.resetsAt, ISO8601DateFormatter().date(from: "2025-04-08T00:00:00Z"))
    }

    func testRepliesAreCachedUntilForcedAndKeepProviderOrder() async {
        let probes = Counter()
        let configured = AgentUsageLimitsService.providers.map(AgentProviderConfig.builtIn)
        let service = AgentUsageLimitsService(providers: { configured }, probe: { config in
            await probes.increment()
            if config.kind == .claude { try? await Task.sleep(nanoseconds: 20_000_000) }
            return AgentUsageLimits(provider: config.kind, failure: "x")
        })
        let first = await service.handle(.init())
        let order = AgentUsageLimitsService.providers.filter { AgentProviderConfig.builtIn($0).enabled }
        XCTAssertEqual(first.providers.map(\.provider), order)
        XCTAssertEqual(first.providers.map(\.providerId), order.map(\.rawValue))
        _ = await service.handle(.init())
        let cached = await probes.value
        XCTAssertEqual(cached, order.count)
        _ = await service.handle(.init(forceRefresh: true))
        let forced = await probes.value
        XCTAssertEqual(forced, order.count * 2)
    }

    func testDisabledAndMissingProvidersAreLeftOut() async {
        let probes = Counter()
        let empty = AgentUsageLimitsService(providers: { [] }, probe: { _ in
            await probes.increment()
            return nil
        })
        let emptyReply = await empty.handle(.init())
        XCTAssertTrue(emptyReply.providers.isEmpty)
        let emptyProbes = await probes.value
        XCTAssertEqual(emptyProbes, 0)

        let configured = AgentUsageLimitsService.providers.map { kind -> AgentProviderConfig in
            var config = AgentProviderConfig.builtIn(kind)
            config.enabled = kind == .codex
            return config
        }
        let service = AgentUsageLimitsService(providers: { configured }, probe: { _ in nil })
        let reply = await service.handle(.init())
        XCTAssertTrue(reply.providers.isEmpty)
    }

    /// An added provider whose CLI this computer lacks, such as a remote server without
    /// Claude Code, shows in AI usage as not installed rather than not at all.
    func testAProviderWithoutItsCLIIsReportedNotLeftOut() async {
        let missing = AgentProviderConfig(id: "claude-work", kind: .claude, executable: "/nonexistent/tab-test/claude")
        let limits = await AgentUsageLimitsProbe.read(missing)
        XCTAssertEqual(limits?.provider, .claude)
        XCTAssertEqual(limits?.failure, "Claude Code isn't installed on this computer.")
        XCTAssertEqual(limits?.windows, [])
    }

    /// A second Claude signed in through its own folder is a second account; a second
    /// Antigravity shares the keychain sign-in, so it is the same one.
    func testEachSignedInAccountIsReadOnce() {
        let configs = [
            AgentProviderConfig.builtIn(.claude),
            AgentProviderConfig(id: "claude-work", kind: .claude, name: "Work", home: "~/.claude-work"),
            AgentProviderConfig(id: "claude-same", kind: .claude, name: "Same folder"),
            AgentProviderConfig.builtIn(.antigravity),
            AgentProviderConfig(id: "antigravity-2", kind: .antigravity, name: "Again"),
            AgentProviderConfig(id: "codex-off", kind: .codex, enabled: false, home: "~/.codex-off"),
            AgentProviderConfig.builtIn(.kiro),
        ]
        XCTAssertEqual(AgentUsageLimitsService.accounts(configs).map(\.id), ["claude", "claude-work", "antigravity"])
    }

    func testAccountNamesAndPlans() {
        XCTAssertEqual(AgentUsageLimitsService.planName("Claude Team"), "Team")
        XCTAssertEqual(AgentUsageLimitsService.planName("plus"), "Plus")
        XCTAssertEqual(AgentUsageLimitsService.planName("SuperGrok Heavy"), "SuperGrok Heavy")
        XCTAssertNil(AgentUsageLimitsService.planName(""))
        let codex = AgentUsageLimitsService.codexLimits(["rateLimits": ["planType": "pro", "primary": ["usedPercent": 1]]],
                                                        checkedAt: checkedAt)
        XCTAssertEqual(codex.plan, "Pro")
    }

    /// Replies from servers before accounts decode, and the new fields survive a round trip.
    func testAccountFieldsAreOptionalOnTheWire() throws {
        let old = try JSONDecoder().decode(AgentUsageLimits.self, from: Data(#"{"provider":"claude","windows":[]}"#.utf8))
        XCTAssertNil(old.providerId)
        XCTAssertNil(old.account)
        let new = AgentUsageLimits(provider: .codex, providerId: "codex-2", providerName: "Work", plan: "Plus",
                                   account: "me@example.com", checkedAt: checkedAt)
        XCTAssertEqual(try JSONDecoder().decode(AgentUsageLimits.self, from: JSONEncoder().encode(new)), new)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
