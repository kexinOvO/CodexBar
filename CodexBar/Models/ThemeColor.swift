//
//  ThemeColor.swift
//  CodexBar
//
//  Custom theme-color support: hex persistence (settings.json stores a
//  plain string, not a Codable Color) and the brightness ladder that
//  replaces the multi-hue warning palette while a custom color is active.
//

import SwiftUI
import AppKit

enum ThemeColor {

    // MARK: - Hex persistence

    /// Parses `#RRGGBB`, `RRGGBB` and `#AARRGGBB`. Returns `nil` for anything
    /// else, so a hand-edited settings.json can never crash the popover —
    /// callers fall back to the system accent.
    static func color(fromHex hex: String) -> Color? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8,
              let raw = UInt64(value, radix: 16) else { return nil }

        let r, g, b, a: Double
        if value.count == 6 {
            r = Double((raw >> 16) & 0xFF) / 255
            g = Double((raw >> 8) & 0xFF) / 255
            b = Double(raw & 0xFF) / 255
            a = 1
        } else {
            a = Double((raw >> 24) & 0xFF) / 255
            r = Double((raw >> 16) & 0xFF) / 255
            g = Double((raw >> 8) & 0xFF) / 255
            b = Double(raw & 0xFF) / 255
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// sRGB `#RRGGBB` for persisting a color picked in the settings wheel.
    static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        let r = Int(round((ns?.redComponent ?? 0) * 255))
        let g = Int(round((ns?.greenComponent ?? 0) * 255))
        let b = Int(round((ns?.blueComponent ?? 0) * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: - Brightness ladder

    /// Brightness variant of `color` at `severity` (0 = mildest, 1 =
    /// strongest). A custom theme has a single hue, so quota states and
    /// heatmap levels can no longer lean on the multi-hue palette (orange /
    /// red) — they are separated purely by brightness (明度):
    ///
    /// - Light background: stronger = **darker** (GitHub-style light ramp).
    /// - Dark background: stronger = **brighter** — the only direction that
    ///   stays readable against the dark material.
    static func shaded(_ color: Color, severity: Double, dark: Bool) -> Color {
        let clamped = min(max(severity, 0), 1)
        let brightness = dark ? 0.45 + 0.55 * clamped : 1.0 - 0.65 * clamped
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else {
            return color
        }
        // NSColor.getHue returns Void (raises on incompatible spaces), so the
        // deviceRGB conversion above is the guard, not the call itself.
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(nsColor: NSColor(hue: h, saturation: s,
                                      brightness: brightness, alpha: a))
    }
}
