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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Token activity")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let usage, !usage.dailyActivity.isEmpty {
                HeatmapView(activities: usage.dailyActivity, months: months)
            } else {
                Text("No activity data yet — the CLI didn't return usage details.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }

            StatsGridView(usage: usage)
        }
    }
}

// MARK: - Heatmap

/// GitHub-style contribution heatmap over a settings-driven window
/// (6...10 months, see `AppSettings.heatmapMonths`).
/// Uses only system colors; intensity via opacity of the accent color.
/// The grid always spans the full popover content width: the cell size is
/// derived from the column count, and month labels sit at exact column
/// offsets so they never drift out of alignment.
struct HeatmapView: View {
    let activities: [DailyActivity]
    /// Months of history displayed (6...10, from Settings). Values outside
    /// the supported range are clamped.
    var months: Int = AppSettings.defaultHeatmapMonths

    /// Full heatmap row width, from the shared popover metrics.
    private static let contentWidth: CGFloat = PopoverMetrics.contentWidth
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
        let cell = Self.cellSize(columns: columns, spacing: spacing, width: Self.contentWidth)

        VStack(alignment: .leading, spacing: 4) {
            monthLabels(windowStart: window.start, months: months, columns: columns,
                        cellSize: cell)
            HeatmapGrid(activities: items,
                        columns: columns,
                        windowStart: window.start,
                        cellSize: cell,
                        spacing: spacing)
        }
    }

    /// Month names positioned at their week-column x offsets. Ticks come from
    /// the calendar window (not from the data) so every month in range is
    /// labelled even when it had no activity.
    private func monthLabels(windowStart: Date, months: Int, columns: Int,
                             cellSize: CGFloat) -> some View {
        let ticks = Self.monthTicks(windowStart: windowStart, months: months)
        let pitch = cellSize + spacing
        let labelWidth = cellSize * 4
        return ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.column) { tick in
                Text(tick.name)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .leading)
                    .offset(x: min(CGFloat(tick.column) * pitch,
                                   Self.contentWidth - labelWidth))
            }
        }
        .frame(height: 10)
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

    /// One label per calendar month inside the window, at the column where the
    /// month becomes visible.
    static func monthTicks(windowStart: Date,
                           months: Int,
                           now: Date = Date()) -> [(column: Int, name: String)] {
        let calendar = weekCalendar
        let end = windowEnd(now: now)
        let formatter = DateFormatter()
        // Localized month abbreviation (e.g. "Sep", "9月", "Sept.").
        formatter.setLocalizedDateFormatFromTemplate("MMM")

        var ticks: [(column: Int, name: String)] = []
        var lastColumn = -99
        var cursor = calendar.dateInterval(of: .month, for: windowStart)?.start ?? windowStart
        while cursor <= end, ticks.count <= months {
            let firstVisible = max(cursor, windowStart)
            let week = calendar.dateComponents([.weekOfYear],
                                               from: windowStart,
                                               to: firstVisible).weekOfYear ?? 0
            // Skip when the previous month only owned this same column (e.g. a
            // window starting on the 30th).
            if week != lastColumn {
                lastColumn = week
                ticks.append((week, formatter.string(from: firstVisible)))
            }
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return Array(ticks.prefix(53))
    }

    /// Cell edge length that makes `columns` cells fill the content width.
    static func cellSize(columns: Int, spacing: CGFloat, width: CGFloat) -> CGFloat {
        let cols = CGFloat(max(columns, 1))
        return (width - spacing * (cols - 1)) / cols
    }

    static func color(for level: Int) -> Color {
        switch level {
        case ...0: return Color.primary.opacity(0.08)
        case 1: return Color.accentColor.opacity(0.30)
        case 2: return Color.accentColor.opacity(0.55)
        case 3: return Color.accentColor.opacity(0.80)
        default: return Color.accentColor
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
                                .fill(HeatmapView.color(for: activity.intensity))
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
        } else if activity.intensity > 0 {
            parts.append(String(localized: "activity level \(activity.intensity)"))
        } else {
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
