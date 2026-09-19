//
//  TokenFormatter.swift
//  CodexBar
//

import Foundation

/// Human-readable formatting of quantities. Unit-bearing strings are resolved
/// through the String Catalog. Forms that inflect (day / minute) use a separate
/// singular key chosen here in code rather than a plural variation: the
/// catalog's source language produces no `.lproj`, so plural rules for English
/// would never reach the built bundle.
enum TokenFormatter {

    /// Bundle used to resolve localized units. Injectable so the unit tests can
    /// pin the source language: the test bundle runs inside CodexBar.app, so
    /// `Bundle.main` would otherwise return the host machine's system language.
    nonisolated(unsafe) static var localizationBundle: Bundle = .main

    /// 999 -> "999", 1000 -> "1K", 1_000_000 -> "1M", 71_900_000 -> "71.9M", 1_300_000_000 -> "1.3B"
    /// Unit prefixes are international (K/M/B) and stay untranslated.
    static func tokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return compact(value)
    }

    static func compact(_ value: Int64) -> String {
        let absValue = Double(abs(value))
        let sign = value < 0 ? "-" : ""
        func fmt(_ v: Double, _ suffix: String) -> String {
            let rounded = (v * 10).rounded() / 10
            if rounded == rounded.rounded() && abs(rounded) >= 10 {
                return "\(sign)\(Int(rounded))\(suffix)"
            }
            let s = String(format: "%.1f", rounded)
            let trimmed = s.hasSuffix(".0") ? String(s.dropLast(2)) : s
            return "\(sign)\(trimmed)\(suffix)"
        }
        switch absValue {
        case ..<1_000:
            return "\(value)"
        case ..<1_000_000:
            return fmt(absValue / 1_000, "K")
        case ..<1_000_000_000:
            return fmt(absValue / 1_000_000, "M")
        default:
            return fmt(absValue / 1_000_000_000, "B")
        }
    }

    /// 45 -> "45 sec", 1_620 -> "27 min", 4_800 -> "1h 20m"
    static func duration(_ seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return "—" }
        if seconds < 60 {
            return String(localized: "\(seconds) sec", bundle: localizationBundle)
        }
        if seconds < 3_600 {
            let minutes = Int((Double(seconds) / 60.0).rounded())
            return String(localized: "\(minutes) min", bundle: localizationBundle)
        }
        let h = seconds / 3_600
        let m = (seconds % 3_600) / 60
        if m == 0 { return String(localized: "\(h)h", bundle: localizationBundle) }
        return String(localized: "\(h)h \(m)m", bundle: localizationBundle)
    }

    /// 1 -> "1 day", 4 -> "4 days"
    static func streak(_ days: Int?) -> String {
        guard let days else { return "—" }
        // Singular is its own key rather than a plural variation: the catalog's
        // source language (en) produces no `.lproj`, so its plural rules would
        // never reach the built bundle and English would render "1 days".
        return days == 1
            ? String(localized: "1 day", bundle: localizationBundle)
            : String(localized: "\(days) days", bundle: localizationBundle)
    }

    /// "2 min ago", "just now", "3h ago"
    static func relative(from date: Date?, to now: Date = Date()) -> String {
        guard let date else { return String(localized: "never", bundle: localizationBundle) }
        let interval = max(0, now.timeIntervalSince(date))
        switch interval {
        case ..<45: return String(localized: "just now", bundle: localizationBundle)
        case ..<90:
            return String(localized: "1 min ago", bundle: localizationBundle)
        case ..<3_600:
            // Rounds to 2...60, so the singular key is never needed here.
            return String(localized: "\(Int((interval / 60).rounded())) min ago", bundle: localizationBundle)
        case ..<86_400:
            let h = Int((interval / 3_600).rounded())
            return String(localized: "\(h)h ago", bundle: localizationBundle)
        default:
            let d = Int((interval / 86_400).rounded())
            return d == 1
                ? String(localized: "1 day ago", bundle: localizationBundle)
                : String(localized: "\(d) days ago", bundle: localizationBundle)
        }
    }

    /// "2h 17m" style countdown.
    static func countdown(until date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "—" }
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return String(localized: "soon", bundle: localizationBundle) }
        let totalMinutes = Int((interval / 60).rounded())
        if totalMinutes < 60 { return String(localized: "\(totalMinutes)m", bundle: localizationBundle) }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h < 24 {
            return m == 0 ? String(localized: "\(h)h", bundle: localizationBundle) : String(localized: "\(h)h \(m)m", bundle: localizationBundle)
        }
        let d = h / 24
        let remH = h % 24
        return remH == 0
            ? String(localized: "\(d)d", bundle: localizationBundle)
            : String(localized: "\(d)d \(remH)h", bundle: localizationBundle)
    }
}

/// Parses loose human quantities found in CLI output.
enum QuantityParser {

    /// "150M" -> 150_000_000, "1.3B" -> 1.3e9, "12,500" -> 12_500, "850" -> 850
    static func tokens(_ text: String) -> Int64? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        let regex = try! NSRegularExpression(pattern: "^([0-9]*\\.?[0-9]+)\\s*([KkMmBb]?)$")
        guard let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let numRange = Range(match.range(at: 1), in: cleaned),
              let value = Double(cleaned[numRange]) else { return nil }
        let suffixRange = Range(match.range(at: 2), in: cleaned)
        let suffix = suffixRange.map { String(cleaned[$0]).lowercased() } ?? ""
        let multiplier: Double
        switch suffix {
        case "k": multiplier = 1_000
        case "m": multiplier = 1_000_000
        case "b": multiplier = 1_000_000_000
        default: multiplier = 1
        }
        return Int64((value * multiplier).rounded())
    }

    /// "4d", "4 days", "1 day" -> days
    static func days(_ text: String) -> Int? {
        let regex = try! NSRegularExpression(pattern: "([0-9]+)\\s*(?:d|day|days)\\b",
                                             options: .caseInsensitive)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    /// "27m", "27 min", "1h 20m", "90s", "2 hours" -> seconds
    static func durationSeconds(_ text: String) -> Int? {
        let regex = try! NSRegularExpression(
            pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*(days?|d\\b|hours?|hrs?|h\\b|minutes?|mins?|m\\b|seconds?|secs?|s\\b)",
            options: .caseInsensitive)
        var total: Double = 0
        var found = false
        let ns = text as NSString
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match,
                  let numRange = Range(match.range(at: 1), in: text),
                  let value = Double(text[numRange]),
                  let unitRange = Range(match.range(at: 2), in: text) else { return }
            let unit = String(text[unitRange]).lowercased()
            found = true
            switch unit {
            case "d", "day", "days":
                total += value * 86_400
            case "h", "hr", "hrs", "hour", "hours":
                total += value * 3_600
            case "m", "min", "mins", "minute", "minutes":
                total += value * 60
            default:
                total += value
            }
        }
        return found ? Int(total.rounded()) : nil
    }
}
