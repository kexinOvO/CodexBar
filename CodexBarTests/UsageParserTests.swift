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

    // MARK: - Colour-driven intensity

    /// The ramp codex-cli 0.155.1 prints once the terminal answers its
    /// `OSC 10;?` / `OSC 11;?` colour queries. Measured from a real render.
    private let liveRamp = ["209;209;209", "247;230;205", "241;207;160",
                            "233;178;101", "223;142;29"]

    private let weekdayLabels = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    /// One row per weekday, five week columns.
    private let tierGrid: [[Int]] = [
        [0, 1, 2, 3, 4],
        [4, 3, 2, 1, 0],
        [0, 0, 0, 0, 0],
        [1, 1, 1, 1, 1],
        [2, 2, 2, 2, 2],
        [3, 3, 3, 3, 3],
        [4, 4, 4, 4, 4],
    ]

    /// Renders a heatmap the way the CLI does: one `■` per cell, level carried
    /// by the 24-bit foreground colour, empty cells painted with the ramp's
    /// dimmest step, ramp echoed on the legend line.
    private func heatmapFixture(ramp: [String], grid: [[Int]]) -> String {
        func painted(_ level: Int) -> String {
            "\u{1B}[1m\u{1B}[38;2;\(ramp[level]);49m■\u{1B}[22m\u{1B}[39;49m"
        }
        let label = "\u{1B}[38;2;147;153;178;49m"

        var out = "\u{1B}[1m Token activity\u{1B}[22m\(label)   last 12 months\u{1B}[39;49m\r\n"
        out += " Lifetime 151M · Peak 71.9M · Streak 4d · Longest task 27m\r\n"
        out += "\r\n"
        out += "\(label)    Oct     Nov       Dec     Jan     Feb\u{1B}[39;49m\r\n"
        for (index, row) in grid.enumerated() {
            out += "\(label) \(weekdayLabels[index]) "
            out += row.map(painted).joined(separator: " ")
            out += "\r\n"
        }
        out += "\(label)   Less "
        out += ramp.indices.map(painted).joined(separator: " ")
        out += "\(label) More\r\n"
        out += "\(label)   daily \u{1B}[39;49m· weekly · cumulative\r\n"
        return out
    }

    /// The ramp is read back out of the legend line rather than hard-coded, so
    /// the colour → level mapping survives theme and CLI version changes.
    func testIntensityRampComesFromLegend() {
        let lines = ANSIStyleScanner.styledLines(from: heatmapFixture(ramp: liveRamp,
                                                                     grid: tierGrid))
        let ramp = UsageParser.intensityRamp(in: lines)
        XCTAssertEqual(ramp?.count, 5)
        XCTAssertEqual(ramp?.first, ANSIRGB(red: 209, green: 209, blue: 209))
        XCTAssertEqual(ramp?.last, ANSIRGB(red: 223, green: 142, blue: 29))
    }

    /// Regression: every non-empty day used to collapse to level 4 because the
    /// parser read the glyph (always `■`) instead of the colour, so a
    /// high-usage day and a barely-used one rendered identically.
    func testColourCarriesIntensity() {
        let usage = UsageParser.parse(heatmapFixture(ramp: liveRamp, grid: tierGrid))

        let nonzero = Set(usage.dailyActivity.map(\.intensity)).subtracting([0])
        XCTAssertEqual(nonzero, [1, 2, 3, 4], "every tier must survive parsing")

        let sundays = usage.dailyActivity
            .filter { Calendar.current.component(.weekday, from: $0.date) == 1 }
            .sorted { $0.date < $1.date }
        XCTAssertEqual(sundays.map(\.intensity), [0, 1, 2, 3, 4])

        let saturdays = usage.dailyActivity
            .filter { Calendar.current.component(.weekday, from: $0.date) == 7 }
            .sorted { $0.date < $1.date }
        XCTAssertFalse(saturdays.isEmpty)
        XCTAssertTrue(saturdays.allSatisfy { $0.intensity == 4 })
    }

    /// When nothing answers the CLI's background query the legend collapses to
    /// one colour. That carries no information, so the parser must fall back to
    /// the glyph ladder instead of inventing a distribution.
    func testCollapsedRampFallsBackToGlyphLadder() {
        let collapsed = ["209;209;209", "249;226;175", "249;226;175",
                         "249;226;175", "249;226;175"]
        let lines = ANSIStyleScanner.styledLines(from: heatmapFixture(ramp: collapsed,
                                                                     grid: tierGrid))
        XCTAssertNil(UsageParser.intensityRamp(in: lines))

        let usage = UsageParser.parse(heatmapFixture(ramp: collapsed, grid: tierGrid))
        XCTAssertFalse(usage.dailyActivity.isEmpty)
        XCTAssertTrue(usage.dailyActivity.allSatisfy { $0.intensity == 4 })
    }

    /// A ramp with more swatches than the 0...4 model is scaled onto it.
    func testLevelNormalizesRampOntoFourTiers() {
        let ramp = (0...5).map { ANSIRGB(red: $0 * 50, green: $0 * 50, blue: $0 * 50) }
        let levels = ramp.map {
            UsageParser.level(for: StyledCharacter(character: "■", color: $0), ramp: ramp)
        }
        XCTAssertEqual(levels, [0, 1, 2, 2, 3, 4])
    }

    /// Without a ramp there is nothing to calibrate against, so the glyph
    /// decides — including for the dim `□` the CLI uses for empty cells.
    func testLevelFallsBackToGlyphWithoutRamp() {
        let hollow = StyledCharacter(character: "□",
                                     color: ANSIRGB(red: 1, green: 2, blue: 3))
        let block = StyledCharacter(character: "■", color: nil)
        XCTAssertEqual(UsageParser.level(for: hollow, ramp: nil), 0)
        XCTAssertEqual(UsageParser.level(for: block, ramp: nil), 4)
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
