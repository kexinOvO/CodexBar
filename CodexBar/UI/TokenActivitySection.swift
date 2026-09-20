//
//  TokenActivitySection.swift
//  CodexBar
//

import SwiftUI

/// Heatmap + overview stats for the `/usage daily` data.
struct TokenActivitySection: View {
    let usage: CodexUsage?
    /// Months the heatmap covers (6...10, from Settings).
    var months: Int = AppSettings.defaultHeatmapMonths
    /// Width available to this section inside the popover (panel width minus
    /// padding, from Settings). Defaults to the static popover geometry so
    /// previews/snapshots render at the historical size.
    var contentWidth: CGFloat = PopoverMetrics.contentWidth
    /// Custom theme accent (`nil` = default mode, system accent).
    var themeAccent: Color? = nil
    /// Whether the lifetime/peak/streak/longest-task row is shown (from Settings).
    var showsStats: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Token activity")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let usage, !usage.dailyActivity.isEmpty {
                HeatmapView(activities: usage.dailyActivity,
                            months: months,
                            contentWidth: contentWidth,
                            themeAccent: themeAccent)
            } else {
                Text("No activity data yet — the CLI didn't return usage details.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }

            if showsStats {
                StatsGridView(usage: usage)
            }
        }
    }
}

// MARK: - Heatmap

/// GitHub-style contribution heatmap over a settings-driven window
/// (6...10 months, see `AppSettings.heatmapMonths`).
/// Uses only system colors; intensity via opacity of the accent color.
/// The grid always spans the full popover content width: the cell size is
/// derived from the column count. No month label row — the grid starts right
/// at the top edge of the section.
struct HeatmapView: View {
    let activities: [DailyActivity]
    /// Months of history displayed (6...10, from Settings). Values outside
    /// the supported range are clamped.
    var months: Int = AppSettings.defaultHeatmapMonths
    /// Full heatmap row width (popover content width, from Settings).
    /// Defaults to the static popover geometry for previews/snapshots.
    var contentWidth: CGFloat = PopoverMetrics.contentWidth
    /// Custom theme accent (`nil` = default mode, system accent). In custom
    /// mode the 5-tier intensity ramp is expressed as brightness steps of the
    /// single hue instead of accent-color opacities.
    var themeAccent: Color? = nil

    @Environment(\.colorScheme) private var colorScheme

    private let spacing: CGFloat = 1.2

    /// Gregorian weeks starting Sunday — shared by the window maths and the
    /// grid layout, so a column boundary can never be off by one.
    static let weekCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        return calendar
    }()

    var body: some View {
        let window = Self.window(months: months)
        let items = activities.filter { $0.date >= window.start }
        let columns = Self.weekColumns(from: window.start, to: window.end)
        let cell = Self.cellSize(columns: columns, spacing: spacing, width: contentWidth)

        HeatmapGrid(activities: items,
                    columns: columns,
                    windowStart: window.start,
                    cellSize: cell,
                    spacing: spacing,
                    themeAccent: themeAccent,
                    dark: colorScheme == .dark)
    }

    // MARK: - Window maths

    /// Week-aligned bounds of the trailing window: `start` is the Sunday of
    /// the week containing "N months ago", `end` the Sunday of the current
    /// week. Both come from the same calendar as the grid layout.
    static func window(months: Int, now: Date = Date()) -> (start: Date, end: Date) {
        let clamped = min(max(months, Int(AppSettings.heatmapMonthRange.lowerBound)),
                          Int(AppSettings.heatmapMonthRange.upperBound))
        let end = windowEnd(now: now)
        let anchor = weekCalendar.date(byAdding: .month, value: -clamped, to: end) ?? end
        let start = weekCalendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        return (start, end)
    }

    /// Sunday that starts the week containing `now`.
    static func windowEnd(now: Date = Date()) -> Date {
        weekCalendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
    }

    /// Number of week columns between two week-aligned dates.
    static func weekColumns(from start: Date, to end: Date) -> Int {
        let weeks = weekCalendar.dateComponents([.weekOfYear], from: start, to: end).weekOfYear ?? 0
        return min(53, max(1, weeks + 1))
    }

    /// Cell edge length that makes `columns` cells fill the content width.
    static func cellSize(columns: Int, spacing: CGFloat, width: CGFloat) -> CGFloat {
        let cols = CGFloat(max(columns, 1))
        return (width - spacing * (cols - 1)) / cols
    }

    /// Default mode: intensity via accent-color opacity (historical ramp,
    /// unchanged). Custom mode: brightness steps of the custom hue.
    static func color(for level: Int) -> Color {
        switch level {
        case ...0: return Color.primary.opacity(0.08)
        case 1: return Color.accentColor.opacity(0.30)
        case 2: return Color.accentColor.opacity(0.55)
        case 3: return Color.accentColor.opacity(0.80)
        default: return Color.accentColor
        }
    }

    /// Brightness-severity of each intensity level in custom mode. Activity
    /// grows with severity; `ThemeColor.shaded` maps that to darker steps on
    /// a light background and brighter steps on a dark one.
    static func heatSeverity(for level: Int) -> Double {
        switch level {
        case 1: return 0.25
        case 2: return 0.50
        case 3: return 0.75
        default: return 1.0
        }
    }
}

/// Grid of small rounded squares, ordered by week column and weekday row.
struct HeatmapGrid: View {
    let activities: [DailyActivity]
    let columns: Int
    /// Sunday that anchors column 0.
    let windowStart: Date
    let cellSize: CGFloat
    let spacing: CGFloat
    /// Custom theme accent (`nil` = default mode, historical opacity ramp).
    var themeAccent: Color? = nil
    /// Resolved color scheme, so the brightness ladder points the right way.
    var dark: Bool = false

    var body: some View {
        let grid = buildGrid()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(0..<7, id: \.self) { weekday in
                HStack(spacing: spacing) {
                    ForEach(0..<columns, id: \.self) { col in
                        if let activity = grid[weekday][col] {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(fillColor(for: activity.intensity))
                                .frame(width: cellSize, height: cellSize)
                                .help(tooltip(for: activity, formatter: dateFormatter))
                        } else {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.primary.opacity(0.05))
                                .frame(width: cellSize, height: cellSize)
                        }
                    }
                }
            }
        }
    }

    private func fillColor(for level: Int) -> Color {
        guard let accent = themeAccent else { return HeatmapView.color(for: level) }
        guard level > 0 else { return Color.primary.opacity(0.08) }
        return ThemeColor.shaded(accent,
                                 severity: HeatmapView.heatSeverity(for: level),
                                 dark: dark)
    }

    private func buildGrid() -> [[DailyActivity?]] {
        let calendar = HeatmapView.weekCalendar
        var grid = Array(repeating: Array(repeating: DailyActivity?.none, count: columns), count: 7)
        for activity in activities {
            let dayOffset = calendar.dateComponents([.day], from: windowStart, to: activity.date).day ?? 0
            guard dayOffset >= 0 else { continue }
            let col = dayOffset / 7
            let weekday = calendar.component(.weekday, from: activity.date) - 1 // 0 = Sunday
            if weekday >= 0 && weekday < 7 && col >= 0 && col < columns {
                grid[weekday][col] = activity
            }
        }
        return grid
    }

    private func tooltip(for activity: DailyActivity, formatter: DateFormatter) -> String {
        var parts = [formatter.string(from: activity.date)]
        if let tokens = activity.tokenCount {
            parts.append(String(localized: "\(TokenFormatter.tokens(tokens)) tokens"))
        } else if activity.intensity == 0 {
            // Days with activity but no token count fall through with the date
            // alone — the square's own shade already conveys the level.
            parts.append(String(localized: "no activity"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Stats grid

struct StatsGridView: View {
    let usage: CodexUsage?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            stat("Lifetime", TokenFormatter.tokens(usage?.lifetimeTokens))
            stat("Peak", TokenFormatter.tokens(usage?.peakTokens))
            stat("Streak", TokenFormatter.streak(usage?.streakDays))
            stat("Longest task", TokenFormatter.duration(usage?.longestTaskSeconds))
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
