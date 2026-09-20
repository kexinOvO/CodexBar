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
    /// Custom theme accent (`ThemeColorMode.custom`); `nil` = default mode,
    /// where every color stays exactly as it was before theming existed.
    var themeAccent: Color? = nil

    @Environment(\.colorScheme) private var colorScheme

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
                    .foregroundStyle(percentColor)
            }

            ProgressBar(fraction: percent.map { $0 / 100 },
                        tint: tintColor)

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if warningLevel == .critical {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(criticalIconColor)
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

    /// Default mode: the historical multi-hue palette (accent / orange / red),
    /// byte-for-byte identical to pre-theming behavior. Custom mode: one hue,
    /// states separated purely by brightness (see `ThemeColor.shaded`) —
    /// normal = the full custom color, warning/critical = deeper (light
    /// background) or brighter (dark background) steps of the same hue.
    private var tintColor: Color {
        guard let accent = themeAccent else {
            switch warningLevel {
            case .normal: return .accentColor
            case .warning: return .orange
            case .critical: return .red
            }
        }
        let dark = colorScheme == .dark
        switch warningLevel {
        case .normal: return accent
        case .warning: return ThemeColor.shaded(accent, severity: 0.45, dark: dark)
        case .critical: return ThemeColor.shaded(accent, severity: 1, dark: dark)
        }
    }

    /// The "remaining" percent readout. Custom mode adopts the same
    /// treatment as the popover header icons (`PopoverRootView.headerIconColor`):
    /// the raw accent sits too close to the popover material, so the normal
    /// state is pushed to the far end of the brightness ladder — much
    /// darker than the theme hue on light, much brighter on dark. Warning /
    /// critical keep their ladder steps so the severity ramp stays
    /// distinguishable in text. Default mode is untouched: the system
    /// accent / orange / red are readable as-is.
    private var percentColor: Color {
        guard let accent = themeAccent else { return tintColor }
        switch warningLevel {
        case .normal:
            return ThemeColor.shaded(accent, severity: 1, dark: colorScheme == .dark)
        case .warning, .critical:
            return tintColor
        }
    }

    /// The critical overlay icon. Default mode keeps its historical orange;
    /// custom mode follows the custom-hue critical step.
    private var criticalIconColor: Color {
        themeAccent.map { ThemeColor.shaded($0, severity: 1, dark: colorScheme == .dark) }
            ?? .orange
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
