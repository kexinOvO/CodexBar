//
//  CodexAppServerTests.swift
//  CodexBarTests
//

import XCTest
@testable import CodexBar

final class CodexAppServerTests: XCTestCase {

    func testRequestEnvelopeMatchesCodexWireProtocol() {
        let envelope = CodexAppServerSession.requestEnvelope(
            id: 7,
            method: "account/usage/read",
            params: [:]
        )

        XCTAssertEqual(envelope["id"] as? Int, 7)
        XCTAssertEqual(envelope["method"] as? String, "account/usage/read")
        XCTAssertNotNil(envelope["params"])

        // Codex app-server intentionally does not use the JSON-RPC 2.0
        // `jsonrpc` field, despite otherwise using request/response semantics.
        XCTAssertNil(envelope["jsonrpc"])
    }

    func testRateLimitsAreMappedByWindowDurationNotPosition() {
        let fiveHours = AppServerRateLimitWindow(
            usedPercent: 30,
            windowDurationMins: 300,
            resetsAt: 1_800_000_000
        )
        let weekly = AppServerRateLimitWindow(
            usedPercent: 93,
            windowDurationMins: 10_080,
            resetsAt: 1_800_500_000
        )

        // Deliberately reverse primary/secondary to prove the mapping is based
        // on duration rather than the field's position.
        let snapshot = AppServerRateLimitSnapshot(
            limitId: "codex",
            limitName: "Codex",
            normalModelSlug: "gpt-5.6-sol",
            primary: weekly,
            secondary: fiveHours,
            planType: "pro"
        )
        let limits = AppServerRateLimitsResponse(
            ordinaryUsageAllowed: true,
            rateLimits: snapshot,
            rateLimitsByLimitId: ["codex": snapshot],
            accountId: "test"
        )
        let account = AppServerAccountResponse(
            account: AppServerAccount(
                type: "chatgpt",
                email: "user@example.com",
                planType: "plus",
                usesCodexManagedCredentials: nil
            ),
            requiresOpenaiAuth: true
        )

        let status = CodexAppServerCLI.makeStatus(account: account,
                                                  limits: limits,
                                                  now: Date(timeIntervalSince1970: 1_790_000_000))

        XCTAssertEqual(status.fiveHourRemainingPercent, 70)
        XCTAssertEqual(status.weeklyRemainingPercent, 7)
        XCTAssertEqual(status.fiveHourResetAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(status.weeklyResetAt, Date(timeIntervalSince1970: 1_800_500_000))
        XCTAssertEqual(status.model, "gpt-5.6-sol")
        XCTAssertEqual(status.accountEmail, "user@example.com")
        XCTAssertEqual(status.plan, "Plus") // account/read wins over snapshot fallback
    }

    func testUsageSummaryMapsWithoutTerminalParsing() {
        let response = AppServerTokenUsageResponse(
            summary: AppServerTokenUsageSummary(
                lifetimeTokens: 150_000_000,
                peakDailyTokens: 71_900_000,
                longestRunningTurnSec: 1_620,
                currentStreakDays: 4,
                longestStreakDays: 9
            ),
            dailyUsageBuckets: nil
        )

        let usage = CodexAppServerCLI.makeUsage(
            response,
            now: Date(timeIntervalSince1970: 1_790_000_000)
        )

        XCTAssertEqual(usage.lifetimeTokens, 150_000_000)
        XCTAssertEqual(usage.peakTokens, 71_900_000)
        XCTAssertEqual(usage.streakDays, 4)
        XCTAssertEqual(usage.longestTaskSeconds, 1_620)
        XCTAssertTrue(usage.dailyActivity.isEmpty)
    }

    func testHeatmapIntensityMatchesCodexThresholds() {
        let peak: Int64 = 100

        XCTAssertEqual(CodexAppServerCLI.intensity(tokens: 0, peak: peak), 0)
        XCTAssertEqual(CodexAppServerCLI.intensity(tokens: 25, peak: peak), 1)
        XCTAssertEqual(CodexAppServerCLI.intensity(tokens: 26, peak: peak), 2)
        XCTAssertEqual(CodexAppServerCLI.intensity(tokens: 50, peak: peak), 2)
        XCTAssertEqual(CodexAppServerCLI.intensity(tokens: 51, peak: peak), 3)
        XCTAssertEqual(CodexAppServerCLI.intensity(tokens: 75, peak: peak), 3)
        XCTAssertEqual(CodexAppServerCLI.intensity(tokens: 76, peak: peak), 4)
        XCTAssertEqual(CodexAppServerCLI.intensity(tokens: 100, peak: peak), 4)
    }

    func testPlanDisplayMapping() {
        XCTAssertEqual(CodexAppServerCLI.displayPlan("plus"), "Plus")
        XCTAssertEqual(CodexAppServerCLI.displayPlan("self_serve_business_usage_based"), "Business")
        XCTAssertEqual(CodexAppServerCLI.displayPlan("enterprise_cbp_usage_based"), "Enterprise")
        XCTAssertEqual(CodexAppServerCLI.displayPlan("edu_pro"), "Edu Pro")
        XCTAssertNil(CodexAppServerCLI.displayPlan("unknown"))
    }

    func testAppServerEnvironmentDoesNotForwardUnrelatedSecrets() {
        let environment = CodexAppServerCLI.childEnvironment()

        XCTAssertNil(environment["GITHUB_TOKEN"])
        XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(environment["NPM_TOKEN"])
        XCTAssertFalse((environment["PATH"] ?? "").isEmpty)
    }
}
