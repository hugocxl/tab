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

    func testRepliesAreCachedUntilForcedAndKeepProviderOrder() async {
        let probes = Counter()
        let service = AgentUsageLimitsService(providers: { .builtIn($0) }, probe: { provider, _ in
            await probes.increment()
            if provider == .claude { try? await Task.sleep(nanoseconds: 20_000_000) }
            return AgentUsageLimits(provider: provider, failure: "x")
        })
        let first = await service.handle(.init())
        XCTAssertEqual(first.providers.map(\.provider), [.claude, .codex])
        _ = await service.handle(.init())
        let cached = await probes.value
        XCTAssertEqual(cached, 2)
        _ = await service.handle(.init(forceRefresh: true))
        let forced = await probes.value
        XCTAssertEqual(forced, 4)
    }

    func testDisabledAndMissingProvidersAreLeftOut() async {
        let service = AgentUsageLimitsService(providers: { kind in
            var config = AgentProviderConfig.builtIn(kind)
            config.enabled = kind == .codex
            return config
        }, probe: { provider, _ in nil })
        let reply = await service.handle(.init())
        XCTAssertTrue(reply.providers.isEmpty)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
