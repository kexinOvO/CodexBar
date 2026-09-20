//
//  AppSettingsTests.swift
//  CodexBarTests
//
//  Covers the heatmap range setting: tolerant decoding of older
//  settings.json files, clamping, and the week window the grid renders.
//

import XCTest
@testable import CodexBar

final class AppSettingsTests: XCTestCase {

    // MARK: - Settings decoding

    /// A settings.json written before `heatmapMonths` existed must keep every
    /// other value instead of failing the decode (CacheStore deletes files it
    /// can't decode, which would silently reset all settings).
    func testLegacySettingsJSONKeepsValuesAndDefaultsNewKeys() throws {
        let legacy = """
        {
          "statusRefreshInterval": 600,
          "usageRefreshInterval": 1800,
          "menuBarDisplayMode": "weeklyPercent",
          "appearance": "dark",
          "notifyWeeklyBelow10": false,
          "notifyWeeklyBelow5": false,
          "notifyFiveHourBelow10": false,
          "launchAtLogin": true,
          "cliTimeout": 240
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.statusRefreshInterval, 600)
        XCTAssertEqual(decoded.usageRefreshInterval, 1_800)
        XCTAssertEqual(decoded.menuBarDisplayMode, .weeklyPercent)
        XCTAssertEqual(decoded.quotaDisplayMode, .full)
        XCTAssertEqual(decoded.appearance, .dark)
        XCTAssertFalse(decoded.notifyWeeklyBelow5)
        XCTAssertTrue(decoded.launchAtLogin)
        XCTAssertNil(decoded.codexPathOverride)
        XCTAssertEqual(decoded.heatmapMonths, AppSettings.defaultHeatmapMonths)
        XCTAssertEqual(decoded.heatmapMonthsClamped, 6)
    }

    /// Empty object (or any partial file) decodes to plain defaults.
    func testEmptySettingsJSONDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, AppSettings.default)
    }

    /// A single bad value must not discard unrelated preferences. This is
    /// what happens when a newer build changes an enum or a hand-edited JSON
    /// value has the wrong type.
    func testMalformedFieldFallsBackWithoutResettingOtherFields() throws {
        let json = """
        {
          "statusRefreshInterval": "not-a-number",
          "usageRefreshInterval": 900,
          "menuBarDisplayMode": "weeklyPercent",
          "quotaDisplayMode": "unknown",
          "appearance": "dark",
          "themeColorMode": "custom",
          "themeColorHex": "#FF00AA",
          "heatmapMonths": 10,
          "popoverWidth": "wide",
          "showUsageStats": false,
          "notifyWeeklyBelow10": false,
          "notifyWeeklyBelow5": true,
          "notifyFiveHourBelow10": false,
          "launchAtLogin": true
        }
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.statusRefreshInterval, AppSettings.default.statusRefreshInterval)
        XCTAssertEqual(decoded.usageRefreshInterval, 900)
        XCTAssertEqual(decoded.menuBarDisplayMode, .weeklyPercent)
        XCTAssertEqual(decoded.quotaDisplayMode, .full)
        XCTAssertEqual(decoded.appearance, .dark)
        XCTAssertEqual(decoded.themeColorMode, .custom)
        XCTAssertEqual(decoded.themeColorHex, "#FF00AA")
        XCTAssertEqual(decoded.heatmapMonths, 10)
        XCTAssertEqual(decoded.popoverWidth, AppSettings.default.popoverWidth)
        XCTAssertFalse(decoded.showUsageStats)
        XCTAssertFalse(decoded.notifyWeeklyBelow10)
        XCTAssertTrue(decoded.notifyWeeklyBelow5)
        XCTAssertFalse(decoded.notifyFiveHourBelow10)
        XCTAssertTrue(decoded.launchAtLogin)
    }

    func testHeatmapMonthsClampedIntoSupportedRange() {
        var settings = AppSettings.default
        settings.heatmapMonths = 3
        XCTAssertEqual(settings.heatmapMonthsClamped, 6)
        settings.heatmapMonths = 12
        XCTAssertEqual(settings.heatmapMonthsClamped, 10)
        settings.heatmapMonths = 8
        XCTAssertEqual(settings.heatmapMonthsClamped, 8)
    }

    // MARK: - Heatmap window

    private var fixedNow: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 19 // Saturday
        components.hour = 12
        return HeatmapView.weekCalendar.date(from: components)!
    }

    func testWindowIsWeekAlignedAndClamped() {
        let calendar = HeatmapView.weekCalendar
        let six = HeatmapView.window(months: 6, now: fixedNow)
        let ten = HeatmapView.window(months: 10, now: fixedNow)
        let beyond = HeatmapView.window(months: 99, now: fixedNow)

        // Both ends land on week boundaries (Sunday with firstWeekday = 1).
        XCTAssertEqual(calendar.component(.weekday, from: six.start), 1)
        XCTAssertEqual(calendar.component(.weekday, from: ten.start), 1)
        XCTAssertEqual(calendar.component(.weekday, from: six.end), 1)
        // Same "today" anchor, longer history for the wider range.
        XCTAssertEqual(six.end, ten.end)
        XCTAssertLessThan(ten.start, six.start)
        // Out-of-range values clamp to the 10-month window.
        XCTAssertEqual(beyond.start, ten.start)
    }

    func testColumnCountFollowsSelectedMonths() {
        let six = HeatmapView.window(months: 6, now: fixedNow)
        let ten = HeatmapView.window(months: 10, now: fixedNow)
        let sixColumns = HeatmapView.weekColumns(from: six.start, to: six.end)
        let tenColumns = HeatmapView.weekColumns(from: ten.start, to: ten.end)

        // A month averages ~4.35 weeks; the window is week-aligned so the
        // column count wobbles by up to a week in either direction.
        XCTAssertEqual(Double(sixColumns), 6 * 4.35, accuracy: 2)
        XCTAssertEqual(Double(tenColumns), 10 * 4.35, accuracy: 2)
        XCTAssertLessThanOrEqual(sixColumns, 53)
        XCTAssertLessThanOrEqual(tenColumns, 53)
        XCTAssertLessThan(sixColumns, tenColumns)

        // Fewer columns => larger cells, both fitting the popover width exactly.
        let spacing: CGFloat = 1.2
        let width = PopoverMetrics.contentWidth
        let sixCell = HeatmapView.cellSize(columns: sixColumns, spacing: spacing, width: width)
        let tenCell = HeatmapView.cellSize(columns: tenColumns, spacing: spacing, width: width)
        XCTAssertGreaterThan(sixCell, tenCell)
        XCTAssertEqual(sixCell * CGFloat(sixColumns) + spacing * CGFloat(sixColumns - 1),
                       width, accuracy: 0.001)
    }
}
