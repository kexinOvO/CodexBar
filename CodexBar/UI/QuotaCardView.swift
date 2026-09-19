//
//  QuotaCardView.swift
//  CodexBar
//

import SwiftUI

/// One quota card: label, progress bar, percent + reset info.
struct QuotaCardView: View {
    enum WarningLevel {
        case normal
        case warning   // < 10%
        case critical  // < 5%
    }

    let title: LocalizedStringKey
    let percent: Double?
    let detail: String?
    let warningLevel: WarningLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(percentText)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(tintColor)
            }

            ProgressBar(fraction: percent.map { $0 / 100 },
                        tint: tintColor)

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background)
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if warningLevel == .critical {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(8)
                    .help("Remaining quota is critically low")
            }
        }
    }

    private var percentText: String {
        guard let percent else { return String(localized: "Unavailable") }
        // Build the number first: passing a `%@` substitution keeps the literal
        // `%` sign out of the format string, which would otherwise have to be
        // escaped as `%%` in every translation.
        let value = "\(Int(percent.rounded()))%"
        return String(localized: "\(value) remaining")
    }

    private var tintColor: Color {
        switch warningLevel {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

/// Thin custom progress bar with system colors only.
struct ProgressBar: View {
    let fraction: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                if let fraction {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
                        .animation(.easeOut(duration: 0.3), value: fraction)
                }
            }
        }
        .frame(height: 8)
    }
}
