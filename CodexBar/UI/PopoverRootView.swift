//
//  PopoverRootView.swift
//  CodexBar
//

import SwiftUI

/// Shared popover geometry so views can't drift out of sync.
enum PopoverMetrics {
    static let width: CGFloat = 370
    static let padding: CGFloat = 16
    /// Width available to content inside the padding.
    static var contentWidth: CGFloat { width - padding * 2 }
}

/// Popover root: quota cards, heatmap, stats, footer with refresh/settings.
struct PopoverRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let error = model.lastError {
                ErrorBanner(error: error,
                            status: model.status,
                            cliState: model.cliState)
            }

            if model.cliState == .notFound {
                NotFoundBanner()
            } else if model.cliState == .notSignedIn {
                NotSignedInBanner()
            }

            QuotaCardView(
                title: "5 hour limit",
                percent: model.status?.fiveHourRemainingPercent,
                detail: resetDetail(forFiveHour: true),
                warningLevel: warningLevel(model.status?.fiveHourRemainingPercent))

            QuotaCardView(
                title: "Weekly",
                percent: model.status?.weeklyRemainingPercent,
                detail: resetDetail(forFiveHour: false),
                warningLevel: warningLevel(model.status?.weeklyRemainingPercent))

            TokenActivitySection(usage: model.usage,
                                 months: model.settings.heatmapMonthsClamped)

            footer
        }
        .padding(PopoverMetrics.padding)
        .frame(width: PopoverMetrics.width)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text(verbatim: "CodexBar")
                .font(.headline)
            Spacer()
            if model.isRefreshingStatus || model.isRefreshingUsage {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                model.manualRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")

            Button {
                NotificationCenter.default.post(name: .openCodexBarSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    private var footer: some View {
        HStack {
            if model.cliState == .notFound {
                Text("Codex CLI not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Updated \(TokenFormatter.relative(from: model.status?.fetchedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let plan = model.status?.plan {
                Text(plan)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resetDetail(forFiveHour: Bool) -> String? {
        let status = model.status
        if forFiveHour {
            if let date = status?.fiveHourResetAt {
                let now = Date()
                // Guard the past case explicitly: "Reset in" + an "imminent"
                // placeholder composes badly in CJK.
                if date <= now { return String(localized: "Reset imminent") }
                return String(localized: "Reset in \(TokenFormatter.countdown(until: date, from: now))")
            }
            return status?.fiveHourResetText.map { String(localized: "Reset \($0)") }
        } else {
            if let date = status?.weeklyResetAt,
               let text = status?.weeklyResetText {
                // Show absolute date for weekly resets (they are days away).
                if let formatted = Self.formatter.string(for: date) {
                    return String(localized: "Reset \(formatted)")
                }
                return String(localized: "Reset \(text)")
            }
            return status?.weeklyResetText.map { String(localized: "Reset \($0)") }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        // Localized so the date reads naturally in every supported language.
        f.setLocalizedDateFormatFromTemplate("MMMd HHmm")
        return f
    }()

    private func warningLevel(_ percent: Double?) -> QuotaCardView.WarningLevel {
        guard let percent else { return .normal }
        if percent < 5 { return .critical }
        if percent < 10 { return .warning }
        return .normal
    }
}

extension Notification.Name {
    static let openCodexBarSettings = Notification.Name("openCodexBarSettings")
}

// MARK: - Banners

struct ErrorBanner: View {
    let error: CodexBarError
    let status: CodexStatus?
    let cliState: AppModel.CLIState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Unable to refresh")
                .font(.caption)
                .fontWeight(.semibold)
            Text(detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let fetchedAt = status?.fetchedAt {
                Text("Showing cached data from \(Self.timeFormatter.string(from: fetchedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var detailText: String {
        if case .failing = cliState {
            return error.errorDescription ?? String(localized: "Unknown error")
        }
        return error.errorDescription ?? String(localized: "Unknown error")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}

struct NotFoundBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Codex CLI not found", systemImage: "questionmark.folder")
                .font(.caption)
                .fontWeight(.semibold)
            Text("Install Codex CLI and sign in with:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: "codex login")
                .font(.system(.caption, design: .monospaced))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct NotSignedInBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Codex isn't signed in", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption)
                .fontWeight(.semibold)
            Text("Run:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: "codex login")
                .font(.system(.caption, design: .monospaced))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
