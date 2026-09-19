//
//  UsageParserTests.swift
//  CodexBarTests
//

import XCTest
@testable import CodexBar

final class UsageParserTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The test bundle is hosted by CodexBar.app, which is localized, so
        // `Bundle.main` would resolve to the machine's system language and the
        // formatter assertions below would be locale-dependent. Pin the
        // non-localized test bundle to compare against the source language.
        TokenFormatter.localizationBundle = Bundle(for: type(of: self))
    }

    override func tearDown() {
        TokenFormatter.localizationBundle = .main
        super.tearDown()
    }

    /// Documented /usage daily output shape.
    private let sample = """
    Token activity   last 12 months
    Lifetime 150M · Peak 71.9M · Streak 4d · Longest task 27m

    Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec
    Su ■ ░ ░ ■ ░ ░ ░ ■ ░ ░ ■ ░ ░ ░ ■ ░ ░ ░ ■ ░ ░ ░ ■ ░ ░ ░ ■ ░ ░ ░ ■ ░ ░ ░ ■ ░ ░ ░ ■ ░ ░ ░ ■ ░ ░ ░ ■ ░
    Mo ░ ░ ■ ░ ░ ░ ░ ░ ░ ░ ■ ░ ░ ░ ░ ░ ░ ■ ░ ░ ░ ░ ░ ░ ░ ░ ░ ■ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ■ ░ ░ ░ ░ ░ ░ ░ ░ ░
    Tu ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░
    We ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░
    Th ░ ■ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░
    Fr ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░
    Sa ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░ ░
    Less ░ ▒ ▓ ■ More
    daily · weekly · cumulative
    """

    func testSummaryParsing() {
        let usage = UsageParser.parse(sample)
        XCTAssertEqual(usage.lifetimeTokens, 150_000_000)
        XCTAssertEqual(usage.peakTokens, 71_900_000)
        XCTAssertEqual(usage.streakDays, 4)
        XCTAssertEqual(usage.longestTaskSeconds, 27 * 60)
    }

    func testHeatmapRowLengths() {
        let usage = UsageParser.parse(sample)
        // 7 weekday rows parsed
        let byWeekday = Dictionary(grouping: usage.dailyActivity) { activity in
            Calendar.current.component(.weekday, from: activity.date)
        }
        XCTAssertEqual(byWeekday.count, 7)
        XCTAssertFalse(usage.dailyActivity.isEmpty)
    }

    func testNoFutureDates() {
        let usage = UsageParser.parse(sample)
        let today = Calendar.current.startOfDay(for: Date())
        XCTAssertTrue(usage.dailyActivity.allSatisfy { $0.date <= today })
    }

    func testIntensityAssignment() {
        // Position semantics: every character (spaces included) is one cell.
        // "Su ■ ░ ░ ■ ..." -> cells [4, 0, 1, 0, 4, ...]
        let usage = UsageParser.parse(sample)
        let sundays = usage.dailyActivity
            .filter { Calendar.current.component(.weekday, from: $0.date) == 1 }
            .sorted { $0.date < $1.date }
        XCTAssertEqual(sundays.first?.intensity, 4)
        XCTAssertEqual(sundays.dropFirst(2).first?.intensity, 1)
    }

    func testAdjacentBlocksNoSpaces() {
        let text = """
        Token activity last 12 months
        Lifetime 1.3B · Peak 900M · Streak 1 day · Longest task 1h 20m
        Su■░■▒
        Mo░░░░░
        Tu░░░░░
        We░░░░░
        Th░░░░░
        Fr░░░░░
        Sa░░░░░
        """
        let usage = UsageParser.parse(text)
        XCTAssertEqual(usage.lifetimeTokens, 1_300_000_000)
        XCTAssertEqual(usage.streakDays, 1)
        XCTAssertEqual(usage.longestTaskSeconds, 4_800)
        let sundays = usage.dailyActivity
            .filter { Calendar.current.component(.weekday, from: $0.date) == 1 }
            .sorted { $0.date < $1.date }
        XCTAssertEqual(sundays.map(\.intensity).prefix(3), [4, 1, 4])
    }

    /// Real output pasted from codex CLI 0.155.1 (Sep 2026):
    /// wide month header, 39 week columns, full-intensity blocks only.
    private let realSample = """
    Token activity   last 12 months
    Lifetime 151M · Peak 71.9M · Streak 4d · Longest task 27m
    Jan     Feb     Mar       Apr     May       Jun     Jul     Aug       Sep
    Su ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■
    Mo ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■
    Tu ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■
    We ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■
    Th ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■
    Fr ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■
    Sa ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■
    Less ■ ■ ■ ■ ■ More
    """

    func testRealOutputSummary() {
        let usage = UsageParser.parse(realSample)
        XCTAssertEqual(usage.lifetimeTokens, 151_000_000)
        XCTAssertEqual(usage.peakTokens, 71_900_000)
        XCTAssertEqual(usage.streakDays, 4)
        XCTAssertEqual(usage.longestTaskSeconds, 27 * 60)
        XCTAssertFalse(usage.isUnparsed)
    }

    func testRealOutputHeatmap() {
        let usage = UsageParser.parse(realSample)
        // 39 week columns x 7 weekdays, minus future days in the current
        // week (none when today is Saturday, the last heatmap day).
        let expectedFutureDays = 6 - (Calendar.current.component(.weekday, from: Date()) - 1)
        XCTAssertEqual(usage.dailyActivity.count, 39 * 7 - expectedFutureDays)
        XCTAssertTrue(usage.dailyActivity.allSatisfy { $0.intensity == 4 })
        XCTAssertTrue(usage.dailyActivity.allSatisfy { $0.tokenCount == nil })
    }

    /// Real CLI output uses □ (U+25A1) for empty cells and spaces as
    /// separators; active cells are full blocks.
    func testWhiteSquareEmptyCells() {
        let text = """
        Token activity   last 12 months
        Lifetime 151M · Peak 71.9M · Streak 4d · Longest task 27m
        Su ■ □ □ ■
        Mo □ □ □ □
        Tu □ □ □ □
        We □ □ □ □
        Th □ □ □ □
        Fr □ □ ■ □
        Sa □ □ □ □
        """
        let usage = UsageParser.parse(text)
        let sunday = usage.dailyActivity
            .filter { Calendar.current.component(.weekday, from: $0.date) == 1 }
            .sorted { $0.date < $1.date }
        XCTAssertEqual(sunday.map(\.intensity), [4, 0, 0, 4])
        let friday = usage.dailyActivity
            .filter { Calendar.current.component(.weekday, from: $0.date) == 6 }
            .sorted { $0.date < $1.date }
        XCTAssertEqual(friday.map(\.intensity), [0, 0, 4, 0])
    }

    func testEmptyOrGarbageDoesNotCrash() {
        let usage = UsageParser.parse("@#$% \u{1B}[31m nothing useful")
        XCTAssertTrue(usage.isUnparsed)
        XCTAssertTrue(usage.dailyActivity.isEmpty)
    }

    func testUnitParsing() {
        XCTAssertEqual(QuantityParser.tokens("150M"), 150_000_000)
        XCTAssertEqual(QuantityParser.tokens("150.0M"), 150_000_000)
        XCTAssertEqual(QuantityParser.tokens("1.3B"), 1_300_000_000)
        XCTAssertEqual(QuantityParser.tokens("71.9M"), 71_900_000)
        XCTAssertEqual(QuantityParser.tokens("850"), 850)
        XCTAssertEqual(QuantityParser.tokens("12,500"), 12_500)
        XCTAssertEqual(QuantityParser.tokens("1K"), 1_000)
        XCTAssertNil(QuantityParser.tokens("n/a"))
    }

    func testDurationParsing() {
        XCTAssertEqual(QuantityParser.durationSeconds("27m"), 1_620)
        XCTAssertEqual(QuantityParser.durationSeconds("27 min"), 1_620)
        XCTAssertEqual(QuantityParser.durationSeconds("1h 20m"), 4_800)
        XCTAssertEqual(QuantityParser.durationSeconds("90s"), 90)
        XCTAssertEqual(QuantityParser.durationSeconds("2 hours"), 7_200)
        XCTAssertEqual(QuantityParser.durationSeconds("4d"), 4 * 86_400)
        XCTAssertNil(QuantityParser.durationSeconds("none"))
    }

    func testDaysParsing() {
        XCTAssertEqual(QuantityParser.days("4d"), 4)
        XCTAssertEqual(QuantityParser.days("4 days"), 4)
        XCTAssertEqual(QuantityParser.days("1 day"), 1)
    }

    func testFormatRoundTrip() {
        XCTAssertEqual(TokenFormatter.tokens(1_000), "1K")
        XCTAssertEqual(TokenFormatter.tokens(1_000_000), "1M")
        XCTAssertEqual(TokenFormatter.tokens(71_900_000), "71.9M")
        XCTAssertEqual(TokenFormatter.tokens(150_000_000), "150M")
        XCTAssertEqual(TokenFormatter.duration(1_620), "27 min")
        XCTAssertEqual(TokenFormatter.duration(4_800), "1h 20m")
        XCTAssertEqual(TokenFormatter.duration(45), "45 sec")
        XCTAssertEqual(TokenFormatter.streak(4), "4 days")
        XCTAssertEqual(TokenFormatter.streak(1), "1 day")
    }
}
