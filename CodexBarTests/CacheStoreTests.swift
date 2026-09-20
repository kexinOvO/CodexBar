//
//  CacheStoreTests.swift
//  CodexBarTests
//

import XCTest
@testable import CodexBar

final class CacheStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> CacheStore {
        CacheStore(directory: tempDir.appendingPathComponent("store", isDirectory: true))
    }

    func testStatusRoundTrip() throws {
        let store = makeStore()
        let original = CodexStatus(
            model: "gpt-5.6-terra (reasoning medium, summaries auto)",
            reasoningEffort: "medium",
            accountEmail: "kexin_0@outlook.com",
            plan: "Plus",
            fiveHourRemainingPercent: 70,
            fiveHourResetAt: Date(timeIntervalSince1970: 1_789_800_000),
            fiveHourResetText: "16:11",
            weeklyRemainingPercent: 7,
            weeklyResetAt: Date(timeIntervalSince1970: 1_789_900_000),
            weeklyResetText: "01:13 on 23 Sep",
            fetchedAt: Date())
        store.save(original, file: "status.json")
        let loaded = store.load(CodexStatus.self, file: "status.json")
        XCTAssertEqual(loaded, original)
    }

    func testUsageRoundTrip() throws {
        let store = makeStore()
        let original = CodexUsage(
            lifetimeTokens: 150_000_000,
            peakTokens: 71_900_000,
            streakDays: 4,
            longestTaskSeconds: 1_620,
            dailyActivity: [
                DailyActivity(date: Date(timeIntervalSince1970: 1_789_000_000),
                              tokenCount: 1_234,
                              intensity: 3),
                DailyActivity(date: Date(timeIntervalSince1970: 1_789_100_000),
                              tokenCount: nil,
                              intensity: 0),
            ],
            fetchedAt: Date())
        store.save(original, file: "usage.json")
        let loaded = store.load(CodexUsage.self, file: "usage.json")
        XCTAssertEqual(loaded, original)
    }

    func testSettingsRoundTrip() throws {
        let store = makeStore()
        var settings = AppSettings.default
        settings.menuBarDisplayMode = .weeklyPercent
        settings.appearance = .dark
        settings.notifyWeeklyBelow5 = false
        settings.heatmapMonths = 9
        store.save(settings, file: "settings.json")
        let loaded = store.load(AppSettings.self, file: "settings.json")
        XCTAssertEqual(loaded, settings)
    }

    func testMalformedSettingsFieldIsRecoveredInPlace() throws {
        let store = makeStore()
        let url = store.directory.appendingPathComponent("settings.json")
        let json = """
        {
          "statusRefreshInterval": "bad",
          "usageRefreshInterval": 900,
          "menuBarDisplayMode": "weeklyPercent",
          "appearance": "dark"
        }
        """
        try Data(json.utf8).write(to: url)

        let loaded = store.load(AppSettings.self, file: "settings.json")

        XCTAssertEqual(loaded?.statusRefreshInterval, AppSettings.default.statusRefreshInterval)
        XCTAssertEqual(loaded?.usageRefreshInterval, 900)
        XCTAssertEqual(loaded?.menuBarDisplayMode, .weeklyPercent)
        XCTAssertEqual(loaded?.appearance, .dark)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptedCacheIsIgnoredAndRemoved() throws {
        let store = makeStore()
        store.save(AppSettings.default, file: "settings.json")
        let url = store.directory.appendingPathComponent("settings.json")
        try Data("{ not valid json !!".utf8).write(to: url)

        let loaded = store.load(AppSettings.self, file: "settings.json")
        XCTAssertNil(loaded)
        // File removed so the next load/fetch starts clean.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMissingFileReturnsNil() {
        let store = makeStore()
        XCTAssertNil(store.load(CodexStatus.self, file: "nope.json"))
    }

    func testAtomicWriteProducesReadableFile() throws {
        let store = makeStore()
        store.save(AppSettings.default, file: "atomic.json")
        let url = store.directory.appendingPathComponent("atomic.json")
        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.isEmpty)
    }
}
