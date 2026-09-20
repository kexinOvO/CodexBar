//
//  UsageParser.swift
//  CodexBar
//

import Foundation

/// Parses the output of the `/usage daily` slash command.
///
/// Expected shape (verified against codex-cli 0.155.1):
///
/// ```
/// Token activity   last 12 months
/// Lifetime 150M · Peak 71.9M · Streak 4d · Longest task 27m
///
/// Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec
/// Su ■ ■ ■ ■ ...
/// Mo ■ ■ ■ ■ ...
/// ...
/// Less ■ ■ ■ ■ ■ More
/// daily · weekly · cumulative
/// ```
///
/// **Intensity lives in the colour, not the glyph.** The CLI paints every
/// non-empty cell with the same block (`■`, U+25A0) and only varies the SGR
/// foreground colour; empty cells are a dim `□` (U+25A1) — or, when the
/// terminal reports a light background, another `■` painted in the ramp's
/// dimmest colour. So the level of a cell is read from the colour it was
/// painted with, calibrated against the ramp the CLI itself prints on the
/// legend line (see `intensityRamp`). The older `░▒▓` ladder is still accepted
/// as a fallback for renders without colour.
///
/// The parser is deliberately tolerant: separator characters between summary
/// items may be "·", "|", "," or whitespace; intensity cells may be
/// space-separated or adjacent.
enum UsageParser {

    /// Fallback ladder for renderings that carry no colour.
    static let blockLevels: [Character: Int] = ["░": 1, "▒": 2, "▓": 3, "■": 4, "█": 4]

    /// Every glyph the CLI can use for a heatmap cell.
    private static let cellGlyphs: Set<Character> = ["■", "□", "█", "▓", "▒", "░"]

    /// Explicit empty-cell filler.
    private static let emptyFillers: Set<Character> = ["·", "-", "0"]

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
        // "Less ... More" legend or the view-mode footer. Runs on the styled
        // scan because intensity is carried by colour.
        usage.dailyActivity = parseHeatmap(lines: ANSIStyleScanner.styledLines(from: rawOutput),
                                           now: now)
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

    /// Rows look like "Su ■ ■ ■ ..." (weekday + one cell per week column).
    /// Columns run left (oldest) to right (most recent); the last column is
    /// the week containing "now".
    static func parseHeatmap(lines: [[StyledCharacter]], now: Date) -> [DailyActivity] {
        // Locate the header line ("Token activity ...").
        guard let headerIndex = lines.firstIndex(where: {
            ANSIStyleScanner.plainText(of: $0).lowercased().contains("token activity")
        }) else { return [] }

        // The CLI prints its own ramp on the legend line; use it as the scale.
        let ramp = intensityRamp(in: lines)

        var rows: [(weekday: Int, cells: [Int])] = []
        for line in lines[(headerIndex + 1)...] {
            let plain = ANSIStyleScanner.plainText(of: line)
            let lower = plain.lowercased()
            if lower.hasPrefix("less") || lower.hasPrefix("daily")
                || lower.hasPrefix("weekly") || lower.hasPrefix("cumulative") {
                break
            }
            if let weekday = weekdayIndex(of: plain) {
                if let cells = intensityCells(of: line, ramp: ramp) {
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

    /// The intensity ladder as printed on the legend line — "Less ■ ■ ■ ■ More"
    /// or the older "Less ░ ▒ ▓ ■ More". Reading the ramp back out of the same
    /// render keeps the colour → level mapping correct across themes and CLI
    /// versions instead of hard-coding RGB values.
    ///
    /// Returns `nil` when the legend is missing or its colours collapse to
    /// fewer than four distinct values. Four is the CLI's documented tier
    /// count, so a shorter ladder means the ramp never resolved — that is what
    /// happens when nothing answers the CLI's `OSC 11;?` background query, and
    /// such a ramp says nothing about intensity. Callers then fall back to the
    /// glyph ladder.
    static func intensityRamp(in lines: [[StyledCharacter]]) -> [ANSIRGB]? {
        for line in lines {
            let plain = ANSIStyleScanner.plainText(of: line)
            guard plain.contains("Less"), plain.contains("More") else { continue }
            let ramp = line.compactMap { character -> ANSIRGB? in
                guard cellGlyphs.contains(character.character) else { return nil }
                return character.color
            }
            return Set(ramp).count >= 4 ? ramp : nil
        }
        return nil
    }

    /// Extracts one intensity level per week column from a heatmap row.
    ///
    /// Whitespace is a separator, not a cell. Any glyph outside the heatmap
    /// alphabet is ignored — the CLI paints the row label too, and box borders
    /// must not be counted as columns. Rows are padded with empty cells on the
    /// right so all 7 rows align to the same column count.
    static func intensityCells(of line: [StyledCharacter], ramp: [ANSIRGB]?) -> [Int]? {
        var cells: [StyledCharacter] = []
        for character in line {
            if character.character.isWhitespace { continue }
            if cellGlyphs.contains(character.character)
                || emptyFillers.contains(character.character) {
                cells.append(character)
            }
        }
        guard !cells.isEmpty else { return nil }
        return cells.map { level(for: $0, ramp: ramp) }
    }

    /// Level 0...4 for one cell. Colour wins when the ramp is known: the CLI
    /// uses a single block glyph for every non-empty day.
    static func level(for cell: StyledCharacter, ramp: [ANSIRGB]?) -> Int {
        if let ramp, ramp.count >= 2, let color = cell.color {
            var bestIndex = 0
            var bestDistance = Int.max
            for (index, entry) in ramp.enumerated() {
                let distance = color.distanceSquared(to: entry)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            // Normalize a ramp of N swatches onto the 0...4 model.
            let span = Double(ramp.count - 1)
            return Int((Double(bestIndex) / span * 4).rounded())
        }
        // No colour to go on: the legacy glyph ladder, where anything that
        // isn't a block is an empty cell.
        return blockLevels[cell.character] ?? 0
    }
}
