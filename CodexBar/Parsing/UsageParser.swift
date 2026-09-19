//
//  UsageParser.swift
//  CodexBar
//

import Foundation

/// Parses the output of the `/usage daily` slash command.
///
/// Expected shape (from documented CLI behavior):
///
/// ```
/// Token activity   last 12 months
/// Lifetime 150M · Peak 71.9M · Streak 4d · Longest task 27m
///
/// Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec
/// Su ■ ■ ■ ░ ...
/// Mo ▒ ░ ■ ...
/// ...
/// Less ░ ▒ ▓ ■ More
/// daily · weekly · cumulative
/// ```
///
/// The parser is deliberately tolerant: separator characters between summary
/// items may be "·", "|", "," or whitespace; intensity cells may be
/// space-separated or adjacent.
enum UsageParser {

    static let blockLevels: [Character: Int] = ["░": 1, "▒": 2, "▓": 3, "■": 4, "█": 4]

    static func parse(_ rawOutput: String, now: Date = Date()) -> CodexUsage {
        let cleaned = ANSITextCleaner.clean(rawOutput)
        let lines = cleaned
            .components(separatedBy: "\n")
            .flatMap { ANSITextCleaner.unwrapBoxes($0) }

        var usage = CodexUsage(dailyActivity: [], fetchedAt: now)
        let text = lines.joined(separator: "\n")

        usage.lifetimeTokens = summaryToken(in: text, label: "lifetime")
        usage.peakTokens = summaryToken(in: text, label: "peak")
        usage.streakDays = summaryStreak(in: text)
        usage.longestTaskSeconds = summaryLongestTask(in: text)

        // Heatmap section: from the "Token activity" marker line to the
        // "Less ... More" legend or the view-mode footer.
        usage.dailyActivity = parseHeatmap(lines: lines, now: now)
        return usage
    }

    // MARK: - Summary

    /// "Lifetime 150M" / "Lifetime: 150M" / "Lifetime 150M ·"
    static func summaryToken(in text: String, label: String) -> Int64? {
        guard let raw = StatusParser.firstMatch(
            in: text,
            pattern: "(?i)\(label)\\s*:?\\s*([0-9][0-9,.]*\\s*[KkMmBb]?)"
        ) else { return nil }
        return QuantityParser.tokens(raw)
    }

    static func summaryStreak(in text: String) -> Int? {
        guard let raw = StatusParser.firstMatch(
            in: text,
            pattern: #"(?i)streak\s*:?\s*([0-9]+\s*(?:d|days?))"#
        ) else { return nil }
        return QuantityParser.days(raw)
    }

    static func summaryLongestTask(in text: String) -> Int? {
        guard let raw = StatusParser.firstMatch(
            in: text,
            pattern: #"(?i)longest\s*task\s*:?\s*([0-9]+\s*(?:h|hr|hrs|hours?|m|min|mins|minutes?|s|sec|secs|seconds?)(?:\s*[0-9]+\s*(?:h|m|s|min|sec)\b)*)"#
        ) else { return nil }
        return QuantityParser.durationSeconds(raw)
    }

    // MARK: - Heatmap

    /// Rows look like "Su ■ ■ ░ ..." (weekday + one cell per week column).
    /// Columns run left (oldest) to right (most recent); the last column is
    /// the week containing "now".
    static func parseHeatmap(lines: [String], now: Date) -> [DailyActivity] {
        // Locate the header line ("Token activity ...").
        guard let headerIndex = lines.firstIndex(where: {
            $0.lowercased().contains("token activity")
        }) else { return [] }

        var rows: [(weekday: Int, cells: [Int])] = []
        for line in lines[(headerIndex + 1)...] {
            let lower = line.lowercased()
            if lower.hasPrefix("less") || lower.hasPrefix("daily")
                || lower.hasPrefix("weekly") || lower.hasPrefix("cumulative") {
                break
            }
            if let weekday = weekdayIndex(of: line) {
                if let cells = intensityCells(of: line) {
                    rows.append((weekday, cells))
                }
            }
            // Stop after we already collected a full week set.
            if rows.count >= 7 { break }
        }
        guard rows.count == 7 else { return [] }

        let columnCount = rows.map(\.cells.count).max() ?? 0
        guard columnCount > 0 else { return [] }

        // Anchor: last column = current week. Week starts on Sunday.
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        let today = calendar.startOfDay(for: now)
        guard let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start else {
            return []
        }

        var activities: [DailyActivity] = []
        for row in rows {
            let cells = row.cells + Array(repeating: 0, count: columnCount - row.cells.count)
            for (col, level) in cells.enumerated() {
                let weekOffset = col - (columnCount - 1) // <= 0
                guard let date = calendar.date(byAdding: .day,
                                               value: weekOffset * 7 + row.weekday,
                                               to: currentWeekStart) else { continue }
                // Skip future dates (right side of the current week is empty).
                if date > today { continue }
                activities.append(DailyActivity(date: date, tokenCount: nil, intensity: level))
            }
        }
        return activities
    }

    /// "Su", "Mo", "Tue", "Sunday" prefix -> 0 (Sun) ... 6 (Sat)
    static func weekdayIndex(of line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let names = ["su", "mo", "tu", "we", "th", "fr", "sa"]
        for (index, name) in names.enumerated() {
            if trimmed.lowercased().hasPrefix(name) {
                // Make sure what follows isn't just more letters (e.g. "Sun" is
                // fine, "Sunday" fine, but a month word should not match).
                return index
            }
        }
        return nil
    }

    /// Extracts one intensity level per week column from a heatmap row.
    /// Whitespace is a separator, not a cell; an explicit light filler
    /// ("·", "-", "0") marks an empty cell. Rows are padded with empty
    /// cells on the right so all 7 rows align to the same column count.
    static func intensityCells(of line: String) -> [Int]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Drop the weekday prefix (first 1–2 letters) and the separator gap
        // between the label and the first cell.
        guard let first = trimmed.first, first.isLetter else { return nil }
        let body = String(trimmed.drop { $0.isLetter }.drop { $0 == " " })
        // A valid row contains either an active cell or an explicit empty
        // filler ("□", "·", "-"); plain text lines have neither.
        let hasCell = body.contains {
            blockLevels[$0] != nil || (!$0.isWhitespace && !$0.isLetter && !$0.isNumber)
        }
        guard hasCell else { return nil }

        var cells: [Int] = []
        for ch in body {
            if ch.isWhitespace { continue }
            if let level = blockLevels[ch] {
                cells.append(level)
            } else if !ch.isLetter && !ch.isNumber {
                // Explicit empty-cell filler ("·", "-", "0").
                cells.append(0)
            }
        }
        return cells.isEmpty ? nil : cells
    }
}
