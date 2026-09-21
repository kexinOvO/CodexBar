//
//  CodexModels.swift
//  CodexBar
//
//  Parsed data models persisted to local cache. Contains no credentials.
//

import Foundation

// MARK: - Status

/// Parsed result of the `/status` slash command in Codex CLI.
struct CodexStatus: Codable, Equatable {
    var model: String?
    var reasoningEffort: String?
    var accountEmail: String?
    var plan: String?
    var fiveHourRemainingPercent: Double?
    var fiveHourResetAt: Date?
    var fiveHourResetText: String?
    var weeklyRemainingPercent: Double?
    var weeklyResetAt: Date?
    var weeklyResetText: String?
    var fetchedAt: Date

    /// True when both quota percentages failed to parse.
    var isUnparsed: Bool {
        fiveHourRemainingPercent == nil && weeklyRemainingPercent == nil
    }
}

// MARK: - Usage

/// One day of token activity. If the CLI only provides heatmap intensity
/// (no exact token count), `tokenCount` is nil and `intensity` carries the
/// bucketed level 0...4 (0 = no activity).
struct DailyActivity: Codable, Equatable, Identifiable {
    var date: Date
    var tokenCount: Int64?
    var intensity: Int
    var id: Date { date }
}

/// Parsed result of the `/usage daily` slash command.
struct CodexUsage: Codable, Equatable {
    var lifetimeTokens: Int64?
    var peakTokens: Int64?
    var streakDays: Int?
    var longestTaskSeconds: Int?
    var dailyActivity: [DailyActivity]
    var fetchedAt: Date

    /// True when nothing useful could be extracted.
    var isUnparsed: Bool {
        lifetimeTokens == nil && peakTokens == nil && streakDays == nil
            && longestTaskSeconds == nil && dailyActivity.isEmpty
    }
}

// MARK: - Settings

/// Which information the menu bar item displays.
enum MenuBarDisplayMode: String, Codable, CaseIterable, Identifiable {
    case iconOnly
    case weeklyPercent
    case fiveHourAndWeekly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iconOnly: return String(localized: "Icon only")
        case .weeklyPercent: return String(localized: "Weekly remaining %")
        case .fiveHourAndWeekly: return String(localized: "5h + Weekly %")
        }
    }
}

/// How much detail the quota blocks in the popover show.
enum QuotaDisplayMode: String, Codable, CaseIterable, Identifiable {
    /// Percentage + bar only — hides when each quota resets.
    case simple
    /// Percentage + bar + reset info.
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .simple: return String(localized: "Simple")
        case .full: return String(localized: "Full")
        }
    }
}

/// Where the app's accent color comes from: the system accent (default,
/// identical to the historical behaviour) or a user-picked custom color.
enum ThemeColorMode: String, Codable, CaseIterable, Identifiable {
    case `default`
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: return String(localized: "Default")
        case .custom: return String(localized: "Custom")
        }
    }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }
}

/// User settings, persisted as settings.json. Contains no secrets.
struct AppSettings: Codable, Equatable {
    var statusRefreshInterval: TimeInterval = 5 * 60
    var usageRefreshInterval: TimeInterval = 30 * 60
    var menuBarDisplayMode: MenuBarDisplayMode = .iconOnly

    /// Detail level of the quota blocks inside the popover.
    var quotaDisplayMode: QuotaDisplayMode = .full

    var appearance: AppearanceMode = .system

    /// Accent source for the whole app (quota tints, heatmap, controls).
    /// `.default` keeps every historical color untouched.
    var themeColorMode: ThemeColorMode = .default

    /// Custom accent as `#RRGGBB`; only meaningful when
    /// `themeColorMode == .custom`.
    var themeColorHex: String?

    /// How many months of history the token activity heatmap covers.
    /// Clamped to `heatmapMonthRange` on read so hand-edited settings.json
    /// can't push the grid outside the supported window.
    var heatmapMonths: Int = AppSettings.defaultHeatmapMonths

    /// Width of the popover panel in points. Clamped to `popoverWidthRange`
    /// on read so hand-edited settings.json can't produce an unusable panel.
    var popoverWidth: Double = AppSettings.defaultPopoverWidth

    /// Whether the lifetime/peak/streak/longest-task stats row under the
    /// heatmap is shown in the popover.
    var showUsageStats: Bool = true

    /// Slider bounds for `heatmapMonths`.
    static let heatmapMonthRange: ClosedRange<Double> = 6...10
    static let defaultHeatmapMonths = 6

    /// `heatmapMonths` clamped into the supported range.
    var heatmapMonthsClamped: Int {
        let lower = Int(Self.heatmapMonthRange.lowerBound)
        let upper = Int(Self.heatmapMonthRange.upperBound)
        return min(max(heatmapMonths, lower), upper)
    }

    /// Slider bounds + step for `popoverWidth` (rounded to 10 pt for a
    /// calmer slider: 200, 210, … 480).
    static let popoverWidthRange: ClosedRange<Double> = 200...480
    static let defaultPopoverWidth = 370.0

    /// `popoverWidth` clamped into the supported range.
    var popoverWidthClamped: Double {
        min(max(popoverWidth, Self.popoverWidthRange.lowerBound),
            Self.popoverWidthRange.upperBound)
    }

    var notifyWeeklyBelow10: Bool = true
    var notifyWeeklyBelow5: Bool = true
    var notifyFiveHourBelow10: Bool = true

    var codexPathOverride: String?

    var launchAtLogin: Bool = false

    /// Hard cap for a single CLI session, seconds.
    var cliTimeout: TimeInterval = 240

    static let `default` = AppSettings()
}

extension AppSettings {
    /// Key names for the tolerant decoder below. Kept separate from the
    /// synthesized `CodingKeys` (used for writing) so this extension stays
    /// valid without touching the memberwise initializer.
    private enum Keys: String, CodingKey {
        case statusRefreshInterval
        case usageRefreshInterval
        case menuBarDisplayMode
        case quotaDisplayMode
        case appearance
        case themeColorMode
        case themeColorHex
        case heatmapMonths
        case popoverWidth
        case showUsageStats
        case notifyWeeklyBelow10
        case notifyWeeklyBelow5
        case notifyFiveHourBelow10
        case codexPathOverride
        case launchAtLogin
        case cliTimeout
    }

    /// Tolerant decoding: every key is decoded independently. A missing or
    /// malformed value falls back to that field's default instead of failing
    /// the whole decode (CacheStore treats a failed decode as a corrupt file
    /// and removes it, which would otherwise reset every setting at once).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let fallback = AppSettings()

        func decodeOrDefault<T: Decodable>(_ type: T.Type,
                                            forKey key: Keys,
                                            default value: T) -> T {
            do {
                return try container.decodeIfPresent(type, forKey: key) ?? value
            } catch {
                return value
            }
        }

        func decodeOptional<T: Decodable>(_ type: T.Type, forKey key: Keys) -> T? {
            do {
                return try container.decodeIfPresent(type, forKey: key)
            } catch {
                return nil
            }
        }

        func decodeBoundedTimeInterval(forKey key: Keys,
                                       default value: TimeInterval,
                                       range: ClosedRange<TimeInterval>) -> TimeInterval {
            let decoded = decodeOrDefault(TimeInterval.self, forKey: key, default: value)
            guard decoded.isFinite else { return value }
            return min(max(decoded, range.lowerBound), range.upperBound)
        }

        statusRefreshInterval = decodeBoundedTimeInterval(
            forKey: .statusRefreshInterval,
            default: fallback.statusRefreshInterval,
            range: 60...3_600
        )
        usageRefreshInterval = decodeBoundedTimeInterval(
            forKey: .usageRefreshInterval,
            default: fallback.usageRefreshInterval,
            range: 300...86_400
        )
        menuBarDisplayMode = decodeOrDefault(MenuBarDisplayMode.self,
                                             forKey: .menuBarDisplayMode,
                                             default: fallback.menuBarDisplayMode)
        quotaDisplayMode = decodeOrDefault(QuotaDisplayMode.self,
                                           forKey: .quotaDisplayMode,
                                           default: fallback.quotaDisplayMode)
        appearance = decodeOrDefault(AppearanceMode.self,
                                     forKey: .appearance,
                                     default: fallback.appearance)
        themeColorMode = decodeOrDefault(ThemeColorMode.self,
                                         forKey: .themeColorMode,
                                         default: fallback.themeColorMode)
        themeColorHex = decodeOptional(String.self, forKey: .themeColorHex)
        heatmapMonths = decodeOrDefault(Int.self,
                                        forKey: .heatmapMonths,
                                        default: fallback.heatmapMonths)
        popoverWidth = decodeOrDefault(Double.self,
                                       forKey: .popoverWidth,
                                       default: fallback.popoverWidth)
        showUsageStats = decodeOrDefault(Bool.self,
                                         forKey: .showUsageStats,
                                         default: fallback.showUsageStats)
        notifyWeeklyBelow10 = decodeOrDefault(Bool.self,
                                              forKey: .notifyWeeklyBelow10,
                                              default: fallback.notifyWeeklyBelow10)
        notifyWeeklyBelow5 = decodeOrDefault(Bool.self,
                                             forKey: .notifyWeeklyBelow5,
                                             default: fallback.notifyWeeklyBelow5)
        notifyFiveHourBelow10 = decodeOrDefault(Bool.self,
                                                 forKey: .notifyFiveHourBelow10,
                                                 default: fallback.notifyFiveHourBelow10)
        codexPathOverride = decodeOptional(String.self, forKey: .codexPathOverride)
        launchAtLogin = decodeOrDefault(Bool.self,
                                        forKey: .launchAtLogin,
                                        default: fallback.launchAtLogin)
        cliTimeout = decodeBoundedTimeInterval(
            forKey: .cliTimeout,
            default: fallback.cliTimeout,
            range: 5...600
        )
    }
}

// MARK: - Notification bookkeeping (not user-facing settings)

/// Tracks which thresholds already fired within the current quota cycle.
struct NotificationBookkeeping: Codable, Equatable {
    var weeklyNotifiedBelow10CycleKey: String?
    var weeklyNotifiedBelow5CycleKey: String?
    var fiveHourNotifiedBelow10CycleKey: String?
}

// MARK: - Errors

enum CodexBarError: LocalizedError {
    case codexNotFound
    case notSignedIn
    case cliFailed(String)
    case timeout
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return String(localized: "Codex CLI not found")
        case .notSignedIn:
            return String(localized: "Codex isn't signed in. Run:\ncodex login")
        case .cliFailed(let detail):
            return String(localized: "Codex CLI failed: \(detail)")
        case .timeout:
            return String(localized: "Codex CLI timed out")
        case .parseFailed(let what):
            return String(localized: "Could not parse \(what) output")
        }
    }
}
