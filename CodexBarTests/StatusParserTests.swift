//
//  StatusParserTests.swift
//  CodexBarTests
//

import XCTest
@testable import CodexBar

final class StatusParserTests: XCTestCase {

    /// Real captured output from Codex CLI 0.155.1 (2026-09-19), with ANSI.
    private let realRawOutput = """
    \u{1B}[38;5;6;49m/status\u{1B}[39;49m
    \u{1B}[0 q
    ╭────────────────────────────────────────────────────────────────────────────────╮
    │  >_ OpenAI Codex (v0.155.1)                                                    │
    │  Model:                gpt-5.6-terra (reasoning medium, summaries auto)        │
    │  Directory:            /private/tmp/codexbar_probe                             │
    │  Account:              kexin_0@outlook.com (Plus)                              │
    │  5h limit:             \u{1B}[22m[██████████████░░░░░░] 70% left\u{1B}[2m (resets 16:11)          │
    │  Weekly limit:         \u{1B}[22m[█░░░░░░░░░░░░░░░░░░░] 7% left\u{1B}[2m (resets 01:13 on 23 Sep) │
    ╰────────────────────────────────────────────────────────────────────────────────╯
    \u{1B}[38;1H\u{1B}[0 q
    """

    func testParsesRealOutput() {
        let status = StatusParser.parse(realRawOutput)
        XCTAssertEqual(status.model, "gpt-5.6-terra (reasoning medium, summaries auto)")
        XCTAssertEqual(status.accountEmail, "kexin_0@outlook.com")
        XCTAssertEqual(status.plan, "Plus")
        XCTAssertEqual(status.fiveHourRemainingPercent ?? -1, 70, accuracy: 0.01)
        XCTAssertEqual(status.weeklyRemainingPercent ?? -1, 7, accuracy: 0.01)
        XCTAssertEqual(status.fiveHourResetText, "16:11")
        XCTAssertEqual(status.weeklyResetText, "01:13 on 23 Sep")
        XCTAssertNotNil(status.fiveHourResetAt)
        XCTAssertNotNil(status.weeklyResetAt)
    }

    func testANSICleanerRemovesDECSCUSR() {
        // \x1b[0 q used to leave a stray "q" and break line matching.
        let cleaned = ANSITextCleaner.clean("a\u{1B}[0 qb\u{1B}[38;5;6mc")
        XCTAssertEqual(cleaned, "abc")
    }

    func testANSICleanerRemovesOSCAndC0() {
        let raw = "\u{1B}]0;title\u{07}text\u{1B}[31mred\u{1B}[0m\u{07}\u{08}end"
        let cleaned = ANSITextCleaner.clean(raw)
        XCTAssertFalse(cleaned.contains("title"))
        XCTAssertFalse(cleaned.contains("\u{1B}"))
        XCTAssertTrue(cleaned.contains("red"))
        XCTAssertTrue(cleaned.contains("end"))
    }

    func testBarFallbackPercent() {
        // No explicit percent number: derive from the bar (5 filled of 20).
        let bar = "█████" + String(repeating: "░", count: 15)
        let text = "5h limit: [\(bar)] (resets 18:00)"
        let pct = StatusParser.parseLimitPercent(in: text, label: "5h")
        XCTAssertEqual(pct ?? -1, 25, accuracy: 0.01)
    }

    func testResetsInDuration() {
        let now = Date()
        let text = "Weekly limit: [██░░] 8% left (resets in 2h 17m)"
        let result = StatusParser.parseResetText(in: text, label: "weekly", now: now)
        XCTAssertEqual(result.text, "in 2h 17m")
        let date = result.date
        XCTAssertNotNil(date)
        let seconds = date!.timeIntervalSince(now)
        XCTAssertEqual(seconds, 2 * 3600 + 17 * 60, accuracy: 5)
    }

    func testResetBareTimeIsTodayOrTomorrow() {
        let now = Date()
        let date = StatusParser.parseResetDate("16:11", now: now)
        XCTAssertNotNil(date)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date!)
        XCTAssertEqual(comps.hour, 16)
        XCTAssertEqual(comps.minute, 11)
    }

    func testResetDayMonthTime() {
        let now = Date()
        let date = StatusParser.parseResetDate("01:13 on 23 Sep", now: now)
        XCTAssertNotNil(date)
        let comps = Calendar.current.dateComponents([.day, .month, .hour, .minute], from: date!)
        XCTAssertEqual(comps.day, 23)
        XCTAssertEqual(comps.month, 9)
        XCTAssertEqual(comps.hour, 1)
        XCTAssertEqual(comps.minute, 13)
    }

    func testBannerAndWarningDoNotWinOverCard() {
        // Startup output contains a banner "model: ... /model to change" line
        // and a "weekly limit left" warning BEFORE the /status card. The card
        // (last occurrence) must win.
        let raw = """
        \u{1B}[0 q⚠ Heads up, you have less than 10% of your weekly limit left. Run /status for a breakdown.
        ╭──────────────────────────────────╮
        │ model:     gpt-5.6-luna low   /model to change │
        │ directory: /private/tmp/probe    │
        ╰──────────────────────────────────╯
        \u{1B}[0 q
        ╭──────────────────────────────────╮
        │  Model:                gpt-5.6-terra (reasoning medium, summaries auto)  │
        │  Account:              kexin_0@outlook.com (Plus)  │
        │  5h limit:             [██████████████░░░░░░] 70% left (resets 16:11)  │
        │  Weekly limit:         [█░░░░░░░░░░░░░░░░░░░] 7% left (resets 01:13 on 23 Sep) │
        ╰──────────────────────────────────╯
        """
        let status = StatusParser.parse(raw)
        XCTAssertEqual(status.model, "gpt-5.6-terra (reasoning medium, summaries auto)")
        XCTAssertEqual(status.weeklyRemainingPercent ?? -1, 7, accuracy: 0.01)
        XCTAssertEqual(status.fiveHourRemainingPercent ?? -1, 70, accuracy: 0.01)
        XCTAssertEqual(status.weeklyResetText, "01:13 on 23 Sep")
    }

    func testParseFailureReturnsEmptyStatusNotCrash() {
        let status = StatusParser.parse("complete garbage \u{1B}[31m@#$%")
        XCTAssertNil(status.fiveHourRemainingPercent)
        XCTAssertNil(status.weeklyRemainingPercent)
        XCTAssertNil(status.model)
    }

    func testLowercaseAndExtraSpacesTolerated() {
        let text = "  weekly   limit : [██░░░░] 8% left  ( resets 01:13 on 23 Sep )"
        let pct = StatusParser.parseLimitPercent(in: text, label: "weekly")
        XCTAssertEqual(pct ?? -1, 8, accuracy: 0.01)
    }
}
