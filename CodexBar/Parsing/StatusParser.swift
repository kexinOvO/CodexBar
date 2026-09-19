//
//  StatusParser.swift
//  CodexBar
//

import Foundation

/// Parses the output of the `/status` slash command.
///
/// Designed against real Codex CLI output (v0.137–0.155) but intentionally
/// loose: it ignores casing, extra whitespace, box-drawing borders and ANSI
/// styling, so minor CLI format changes won't break it.
enum StatusParser {

    /// Verified real-world shape:
    ///
    /// ```
    /// ╭───...───╮
    /// │  >_ OpenAI Codex (v0.155.1)  │
    /// │  Model:      gpt-5.6-terra (reasoning medium, summaries auto)  │
    /// │  Account:    kexin@example.com (Plus)  │
    /// │  5h limit:   [██████████████░░░░░░] 70% left (resets 16:11)  │
    /// │  Weekly limit: [█░░...] 7% left (resets 01:13 on 23 Sep)  │
    /// ╰───...───╯
    /// ```
    static func parse(_ rawOutput: String, now: Date = Date()) -> CodexStatus {
        let cleaned = ANSITextCleaner.clean(rawOutput)
        let lines = cleaned
            .components(separatedBy: "\n")
            .flatMap { ANSITextCleaner.unwrapBoxes($0) }
        let text = lines.joined(separator: "\n")

        var status = CodexStatus(fetchedAt: now)
        status.model = lastMatch(in: text, pattern: #"(?im)^\s*Model:\s*(.+?)\s*$"#)
        if let model = status.model {
            status.reasoningEffort = firstMatch(in: model, pattern: #"(?i)reasoning\s+(\w+)"#)
        }

        if let accountLine = lastMatch(in: text, pattern: #"(?im)^\s*Account:\s*(.+?)\s*$"#) {
            let email = firstMatch(in: accountLine, pattern: #"\S+@\S+"#)
            status.accountEmail = email ?? accountLine
            let planMatch = firstMatch(in: accountLine, pattern: #"\(([^)]+)\)\s*$"#)
            status.plan = planMatch
        }

        status.fiveHourRemainingPercent = parseLimitPercent(in: text, label: "5h")
        status.weeklyRemainingPercent = parseLimitPercent(in: text, label: "weekly")

        let fiveHourReset = parseResetText(in: text, label: "5h", now: now)
        status.fiveHourResetAt = fiveHourReset.date
        status.fiveHourResetText = fiveHourReset.text

        let weeklyReset = parseResetText(in: text, label: "weekly", now: now)
        status.weeklyResetAt = weeklyReset.date
        status.weeklyResetText = weeklyReset.text

        return status
    }

    // MARK: - Quota

    /// Finds "<label> limit:" line, then extracts remaining percent from an
    /// explicit number ("70% left") or from the bar length as a fallback.
    static func parseLimitPercent(in text: String, label: String) -> Double? {
        guard let line = findLimitLine(in: text, label: label) else { return nil }

        if let explicit = firstMatch(in: line, pattern: #"([0-9]+(?:\.[0-9]+)?)\s*%"#),
           let value = Double(explicit) {
            return min(100, max(0, value))
        }
        // Fallback: count filled vs empty bar cells.
        if let bar = firstMatch(in: line, pattern: #"\[([^\]]*)\]"#) {
            let filled = bar.filter { "█▓▒░".contains($0) && $0 != "░" }.count
            let total = bar.filter { "█▓▒░ ".contains($0) }.count
            if total > 0 {
                return min(100, max(0, Double(filled) / Double(total) * 100))
            }
        }
        return nil
    }

    /// Extracts the "(resets ...)" fragment for a limit line.
    static func parseResetText(in text: String, label: String, now: Date) -> (text: String?, date: Date?) {
        guard let line = findLimitLine(in: text, label: label) else { return (nil, nil) }
        guard let resetInfo = firstMatch(in: line, pattern: #"(?i)resets?\s+([^)]*)\)?"#) else {
            return (nil, nil)
        }
        let date = parseResetDate(resetInfo, now: now)
        return (resetInfo, date)
    }

    /// Understands "16:11", "01:13 on 23 Sep", "in 2h 17m", "2h 17m", "3 days".
    static func parseResetDate(_ info: String, now: Date) -> Date? {
        let info = info.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "resets", with: "", options: [.caseInsensitive, .anchored])
            .trimmingCharacters(in: .whitespaces)

        // Relative duration: "in 2h 17m" / "2h 17m" / "45m"
        if let seconds = QuantityParser.durationSeconds(info.replacingOccurrences(of: "in ", with: "")) {
            return now.addingTimeInterval(TimeInterval(seconds))
        }
        if let days = QuantityParser.days(info) {
            return Calendar.current.startOfDay(for: now)
                .addingTimeInterval(TimeInterval(days * 86_400 + 12 * 3_600))
        }

        // "01:13 on 23 Sep" (or "23 Sep 01:13")
        if let date = parseDayMonthTime(info, now: now) { return date }

        // Bare time "16:11" -> today (or tomorrow if already past)
        if let time = parseBareTime(info), let date = Calendar.current.date(
            bySettingHour: time.hour, minute: time.minute, second: 0, of: now) {
            if date < now.addingTimeInterval(-60) {
                return date.addingTimeInterval(86_400)
            }
            return date
        }
        return nil
    }

    private static func parseDayMonthTime(_ info: String, now: Date) -> Date? {
        let pattern = #"(?i)(\d{1,2})[:.](\d{2})\s*(?:on\s*)?(\d{1,2})\s*(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)(\w*)|(\d{1,2})\s*(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)(\w*)\s+(\d{1,2})[:.](\d{2})"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = info as NSString
        guard let m = regex.firstMatch(in: info, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let monthNames = ["jan", "feb", "mar", "apr", "may", "jun",
                          "jul", "aug", "sep", "oct", "nov", "dec"]

        func dateFor(day: Int, month: Int, hour: Int, minute: Int) -> Date? {
            var comps = DateComponents()
            comps.year = Calendar.current.component(.year, from: now)
            comps.month = month
            comps.day = day
            comps.hour = hour
            comps.minute = minute
            guard let date = Calendar.current.date(from: comps) else { return nil }
            // If the date is far in the past, it likely means next year.
            if date < now.addingTimeInterval(-6 * 86_400) {
                comps.year! += 1
                return Calendar.current.date(from: comps)
            }
            return date
        }

        // Variant A: "01:13 on 23 Sep"
        if m.range(at: 1).location != NSNotFound {
            guard let hour = Int(ns.substring(with: m.range(at: 1))),
                  let minute = Int(ns.substring(with: m.range(at: 2))),
                  let day = Int(ns.substring(with: m.range(at: 3))) else { return nil }
            let monthStr = ns.substring(with: m.range(at: 4)).lowercased()
            guard let month = monthNames.firstIndex(of: monthStr).map({ $0 + 1 }) else { return nil }
            return dateFor(day: day, month: month, hour: hour, minute: minute)
        }
        // Variant B: "23 Sep 01:13"
        if m.range(at: 6).location != NSNotFound {
            guard let day = Int(ns.substring(with: m.range(at: 6))),
                  let hour = Int(ns.substring(with: m.range(at: 10))),
                  let minute = Int(ns.substring(with: m.range(at: 11))) else { return nil }
            let monthStr = ns.substring(with: m.range(at: 7)).lowercased()
            guard let month = monthNames.firstIndex(of: monthStr).map({ $0 + 1 }) else { return nil }
            return dateFor(day: day, month: month, hour: hour, minute: minute)
        }
        return nil
    }

    private static func parseBareTime(_ info: String) -> (hour: Int, minute: Int)? {
        let regex = try! NSRegularExpression(pattern: #"(\d{1,2})[:.](\d{2})"#)
        let ns = info as NSString
        guard let m = regex.firstMatch(in: info, range: NSRange(location: 0, length: ns.length)),
              let hour = Int(ns.substring(with: m.range(at: 1))),
              let minute = Int(ns.substring(with: m.range(at: 2))),
              hour < 24, minute < 60 else { return nil }
        return (hour, minute)
    }

    // MARK: - Helpers

    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(
            in: text,
            range: NSRange(location: 0, length: ns.length)),
              match.range.location != NSNotFound else { return nil }
        // Prefer capture group 1; fall back to the whole match when the
        // pattern has no groups or the group didn't participate.
        let range: NSRange
        if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
            range = match.range(at: 1)
        } else {
            range = match.range
        }
        guard range.location != NSNotFound, let value = Range(range, in: text) else { return nil }
        return String(text[value])
    }

    /// Case-insensitive line lookup that tolerates arbitrary spacing between
    /// the label words (e.g. "Weekly  limit:").
    static func findLine(in text: String, containing first: String, and second: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let lower = line.lowercased()
            if lower.contains(first.lowercased()) && lower.contains(second.lowercased()) {
                return line
            }
        }
        return nil
    }

    /// Prefers the *last* line of the form "<label> limit:" (the /status card)
    /// so startup warnings like "...weekly limit left" don't win. Falls back
    /// to any "<label>...limit" line for older CLI formats.
    static func findLimitLine(in text: String, label: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        var lastWithColon: String?
        var lastAny: String?
        for line in lines {
            let lower = line.lowercased()
            guard lower.contains(label.lowercased()) else { continue }
            let range = lower.range(of: "limit")
            guard let range else { continue }
            lastAny = line
            // "limit:" (allowing whitespace before the colon) = card line.
            if lower[range.upperBound...].trimmingCharacters(in: .whitespaces).hasPrefix(":") {
                lastWithColon = line
            }
        }
        return lastWithColon ?? lastAny
    }

    /// Returns the last capture-group match — the /status card appears after
    /// the startup banner in the buffer, so "last" is the card's value.
    static func lastMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        var result: String?
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.range.location != NSNotFound else { return }
            let range: NSRange
            if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                range = match.range(at: 1)
            } else {
                range = match.range
            }
            guard range.location != NSNotFound, let value = Range(range, in: text) else { return }
            result = String(text[value])
        }
        return result
    }
}
