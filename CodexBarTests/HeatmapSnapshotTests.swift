//
//  HeatmapSnapshotTests.swift
//  CodexBarTests
//
//  TEMPORARY harness: renders the token activity section offscreen at several
//  heatmap ranges and writes PNGs to /tmp so the layout can be eyeballed.
//  Delete after verification.
//

import XCTest
import SwiftUI
@testable import CodexBar

@MainActor
final class HeatmapSnapshotTests: XCTestCase {

    private static func sample() -> CodexUsage {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = calendar.startOfDay(for: Date())
        var days: [DailyActivity] = []
        for offset in stride(from: 330, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            // Deterministic pseudo-random pattern so the grid is comparable run to run.
            let wobble = (offset * 7919) % 100
            let intensity: Int
            switch wobble {
            case 0..<35: intensity = 0
            case 35..<60: intensity = 1
            case 60..<80: intensity = 2
            case 80..<93: intensity = 3
            default: intensity = 4
            }
            // Leave a data gap to prove empty cells render as the muted placeholder.
            let gap = (offset > 40 && offset < 55)
            days.append(DailyActivity(date: date,
                                      tokenCount: intensity == 0 ? nil : Int64(intensity) * 1_250_000,
                                      intensity: gap ? 0 : intensity))
        }
        return CodexUsage(lifetimeTokens: 151_000_000,
                          peakTokens: 71_900_000,
                          streakDays: 4,
                          longestTaskSeconds: 1_620,
                          dailyActivity: days,
                          fetchedAt: Date())
    }

    func testRenderTokenActivitySection() throws {
        let usage = Self.sample()
        for months in [6, 8, 10] {
            let view = TokenActivitySection(usage: usage, months: months)
                .padding(16)
                .frame(width: 370)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("render failed for \(months) months")
                continue
            }
            let url = URL(fileURLWithPath: "/tmp/codexbar-heatmap-\(months)m.png")
            try png.write(to: url)
            print("SNAPSHOT \(months)m -> \(url.path) size=\(image.size)")
        }
    }

    /// Custom theme color: heatmap must follow the picked hue via the
    /// brightness ladder, in both appearances. Temporary verification aid.
    func testRenderThemeHeatmap() throws {
        let usage = Self.sample()
        let cases: [(name: String, hex: String, dark: Bool)] = [
            ("gray-light", "#393939", false),
            ("gray-dark", "#393939", true),
            ("orange-light", "#E8590C", false),
            ("orange-dark", "#E8590C", true),
        ]
        for c in cases {
            let accent = ThemeColor.color(fromHex: c.hex)
            let view = TokenActivitySection(usage: usage, months: 6, themeAccent: accent)
                .padding(16)
                .frame(width: 370)
                .background(Color(nsColor: c.dark ? .underPageBackgroundColor : .windowBackgroundColor))
                .environment(\.colorScheme, c.dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("render failed for \(c.name)")
                continue
            }
            let url = URL(fileURLWithPath: "/tmp/codexbar-heatmap-theme-\(c.name).png")
            try png.write(to: url)
            print("SNAPSHOT theme \(c.name) -> \(url.path)")
        }
    }

    /// Settings window at the smallest / largest slider positions. Uses a real
    /// NSHostingView in an offscreen window — `Form` doesn't render through
    /// ImageRenderer alone.
    func testRenderSettingsWindow() throws {
        let model = AppModel()
        for months in [6, 8, 10] {
            model.settings.heatmapMonths = months
            let size = NSSize(width: 460, height: 1100)
            let hosting = NSHostingView(rootView: SettingsView(model: model))
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled],
                                  backing: .buffered,
                                  defer: false)
            window.contentView = hosting
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                XCTFail("no bitmap rep for settings \(months)")
                continue
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("png encode failed for settings \(months)")
                continue
            }
            let url = URL(fileURLWithPath: "/tmp/codexbar-settings-\(months)m.png")
            try png.write(to: url)
            print("SNAPSHOT settings \(months)m -> \(url.path)")
        }
    }
}
