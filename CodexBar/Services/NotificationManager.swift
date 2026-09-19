//
//  NotificationManager.swift
//  CodexBar
//

import Foundation
import UserNotifications

/// Low-quota notifications. Each threshold fires at most once per quota
/// cycle; recovery above the threshold re-arms it.
final class NotificationManager: @unchecked Sendable {

    private let cache: CacheStore
    private let lock = NSLock()
    private var bookkeeping: NotificationBookkeeping

    init(cache: CacheStore) {
        self.cache = cache
        self.bookkeeping = cache.load(NotificationBookkeeping.self, file: "notifications.json")
            ?? NotificationBookkeeping()
    }

    // MARK: - Permission

    /// Requests authorization lazily, right before the first notification.
    func ensureAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    // MARK: - Evaluation

    /// Called after every successful /status refresh.
    func evaluate(status: CodexStatus, settings: AppSettings) async {
        var fired: [(title: String, body: String)] = []

        let weeklyCycleKey = cycleKey(resetText: status.weeklyResetText, resetAt: status.weeklyResetAt)
        if let weekly = status.weeklyRemainingPercent {
            if settings.notifyWeeklyBelow5, weekly < 5,
               consume(&bookkeeping.weeklyNotifiedBelow5CycleKey, cycleKey: weeklyCycleKey, value: weekly, threshold: 5) {
                fired.append((title: String(localized: "Codex weekly usage is low"),
                              body: lowQuotaBody(percent: weekly, resetText: status.weeklyResetText)))
            } else if settings.notifyWeeklyBelow10, weekly < 10, weekly >= 5,
                      consume(&bookkeeping.weeklyNotifiedBelow10CycleKey, cycleKey: weeklyCycleKey, value: weekly, threshold: 10) {
                fired.append((title: String(localized: "Codex weekly usage is low"),
                              body: lowQuotaBody(percent: weekly, resetText: status.weeklyResetText)))
            }
            // Recovery re-arms the latches.
            if weekly >= 10 {
                set(\.weeklyNotifiedBelow10CycleKey, nil)
                set(\.weeklyNotifiedBelow5CycleKey, nil)
            } else if weekly >= 5 {
                set(\.weeklyNotifiedBelow5CycleKey, nil)
            }
        }

        let fiveHourCycleKey = cycleKey(resetText: status.fiveHourResetText, resetAt: status.fiveHourResetAt)
        if let fiveHour = status.fiveHourRemainingPercent {
            if settings.notifyFiveHourBelow10, fiveHour < 10,
               consume(&bookkeeping.fiveHourNotifiedBelow10CycleKey, cycleKey: fiveHourCycleKey, value: fiveHour, threshold: 10) {
                fired.append((title: String(localized: "Codex 5h usage is low"),
                              body: lowQuotaBody(percent: fiveHour, resetText: status.fiveHourResetText)))
            }
            if fiveHour >= 10 {
                set(\.fiveHourNotifiedBelow10CycleKey, nil)
            }
        }

        guard !fired.isEmpty else { return }
        persist()
        await ensureAuthorization()
        for notification in fired {
            post(title: notification.title, body: notification.body)
        }
    }

    // MARK: - Bookkeeping

    /// Shared body for low-quota alerts: "58% remaining · resets 16:11".
    private func lowQuotaBody(percent: Double, resetText: String?) -> String {
        let value = "\(Int(percent.rounded()))%"
        let reset = resetText ?? String(localized: "soon")
        return String(localized: "\(value) remaining · resets \(reset)")
    }

    private func cycleKey(resetText: String?, resetAt: Date?) -> String {
        resetText ?? resetAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
    }

    /// True only the first time a threshold is crossed within the current
    /// cycle. `slot` is updated under lock; persistence happens in caller.
    private func consume(_ slot: inout String?, cycleKey: String, value: Double, threshold: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if slot == cycleKey { return false }
        slot = cycleKey
        return true
    }

    private func set(_ keyPath: WritableKeyPath<NotificationBookkeeping, String?>, _ value: String?) {
        lock.lock()
        bookkeeping[keyPath: keyPath] = value
        lock.unlock()
    }

    private func persist() {
        lock.lock()
        let snapshot = bookkeeping
        lock.unlock()
        cache.save(snapshot, file: "notifications.json")
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
