//
//  AppModel.swift
//  CodexBar
//

import Foundation
import SwiftUI
import Combine

/// Central observable model: owns settings, cached data, refresh scheduling,
/// concurrency guards and the CLI executor. Everything UI-facing publishes
/// on the main actor; app-server I/O + structured decoding run off-main.
@MainActor
final class AppModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var status: CodexStatus?
    @Published private(set) var usage: CodexUsage?
    @Published var settings: AppSettings {
        didSet {
            cache.save(settings, file: "settings.json")
            applyAppearance()
            scheduleTimers()
            onSettingsChanged?(settings)
        }
    }
    @Published private(set) var lastError: CodexBarError?
    @Published private(set) var isRefreshingStatus = false
    @Published private(set) var isRefreshingUsage = false
    @Published private(set) var codexVersion: String?
    @Published private(set) var cliState: CLIState = .unknown

    enum CLIState: Equatable {
        case unknown
        case checking
        case ready
        case notFound
        case notSignedIn
        case failing(String)
    }

    /// Called when settings that affect the status bar item change.
    var onSettingsChanged: ((AppSettings) -> Void)?

    // MARK: - Dependencies

    private let cache: CacheStore
    private let notifications: NotificationManager

    // MARK: - Refresh guards

    private var statusRefreshTask: Task<Void, Never>?
    private var usageRefreshTask: Task<Void, Never>?
    private var statusTimerTask: Task<Void, Never>?
    private var usageTimerTask: Task<Void, Never>?

    // MARK: - Init

    init(cache: CacheStore = CacheStore()) {
        self.cache = cache
        self.notifications = NotificationManager(cache: cache)

        // 1. Load caches first so the UI shows something instantly.
        let loadedSettings = cache.load(AppSettings.self, file: "settings.json") ?? .default
        self.settings = loadedSettings
        // Re-encode the independently decoded value. This repairs missing or
        // malformed individual fields on the next launch without waiting for
        // the user to touch a setting, while retaining every valid value.
        cache.save(loadedSettings, file: "settings.json")
        self.status = cache.load(CodexStatus.self, file: "status.json")
        self.usage = cache.load(CodexUsage.self, file: "usage.json")

        applyAppearance()
    }

    /// Kicks off background refresh + timers. Called after the status item
    /// is installed.
    func start() {
        scheduleTimers()
        Task {
            await refreshStatusIfDue(maxAge: .infinity)
            await refreshUsageIfDue(maxAge: .infinity)
        }
    }

    func shutdown() {
        statusTimerTask?.cancel()
        usageTimerTask?.cancel()
        statusRefreshTask?.cancel()
        usageRefreshTask?.cancel()
    }

    // MARK: - Popover lifecycle

    /// Called when the popover opens: refresh stale data immediately.
    func popoverWillOpen() {
        Task {
            await refreshStatusIfDue(maxAge: 2 * 60)
        }
        Task {
            await refreshUsageIfDue(maxAge: 10 * 60)
        }
    }

    /// Manual refresh button: refresh both, ignoring staleness.
    func manualRefresh() {
        Task { await refreshStatusIfDue(maxAge: 0) }
        Task { await refreshUsageIfDue(maxAge: 0) }
    }

    /// Re-runs CLI detection only. Used by the settings "Detect" button so a
    /// changed path takes effect immediately instead of on the next timer tick.
    /// Deliberately lighter than `manualRefresh()` — account usage may perform
    /// a backend read and is unnecessary for a path-detection interaction.
    func recheckCLI() {
        Task { await refreshStatusIfDue(maxAge: 0) }
    }

    // MARK: - Timers

    private func scheduleTimers() {
        statusTimerTask?.cancel()
        usageTimerTask?.cancel()

        let statusInterval = max(60, settings.statusRefreshInterval)
        let usageInterval = max(300, settings.usageRefreshInterval)

        statusTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(statusInterval * 1_000_000_000))
                await self?.refreshStatusIfDue(maxAge: 0.9 * statusInterval)
            }
        }
        usageTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(usageInterval * 1_000_000_000))
                await self?.refreshUsageIfDue(maxAge: 0.9 * usageInterval)
            }
        }
    }

    // MARK: - Refresh

    private func refreshStatusIfDue(maxAge: TimeInterval) async {
        guard !isRefreshingStatus else { return }
        if let status, maxAge < .infinity,
           Date().timeIntervalSince(status.fetchedAt) < maxAge {
            return
        }
        isRefreshingStatus = true
        defer { isRefreshingStatus = false }

        cliState = .checking
        do {
            guard let codex = CodexLocator.locate(override: settings.codexPathOverride) else {
                cliState = .notFound
                throw CodexBarError.codexNotFound
            }
            codexVersion = codex.version

            let timeout = settings.cliTimeout
            let workspace = cache.cliWorkspaceURL.path
            let result = try await Task.detached(priority: .utility) {
                try await CodexAppServerCLI.fetchStatus(executablePath: codex.path,
                                                        workingDirectory: workspace,
                                                        timeout: timeout,
                                                        pathEntries: codex.pathEntries)
            }.value

            if let version = result.versionLine { codexVersion = version }
            let parsed = result.status
            if !parsed.isUnparsed {
                self.status = parsed
                cache.save(parsed, file: "status.json")
                cliState = .ready
                lastError = nil
                await notifications.evaluate(status: parsed, settings: settings)
            } else if status == nil {
                lastError = .parseFailed("account/rateLimits/read")
                cliState = .failing(String(localized: "unrecognized app-server rate limit response"))
            }
        } catch let error as CodexBarError {
            handle(error: error)
        } catch is CancellationError {
            // shutting down
        } catch {
            handle(error: .cliFailed(error.localizedDescription))
        }
    }

    private func refreshUsageIfDue(maxAge: TimeInterval) async {
        guard !isRefreshingUsage else { return }
        if let usage, maxAge < .infinity,
           Date().timeIntervalSince(usage.fetchedAt) < maxAge {
            return
        }
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }

        cliState = .checking
        do {
            guard let codex = CodexLocator.locate(override: settings.codexPathOverride) else {
                cliState = .notFound
                throw CodexBarError.codexNotFound
            }
            codexVersion = codex.version

            let timeout = settings.cliTimeout
            let workspace = cache.cliWorkspaceURL.path
            let result = try await Task.detached(priority: .utility) {
                try await CodexAppServerCLI.fetchUsage(executablePath: codex.path,
                                                       workingDirectory: workspace,
                                                       timeout: timeout,
                                                       pathEntries: codex.pathEntries)
            }.value
            if let version = result.versionLine { codexVersion = version }

            let parsed = result.usage
            if !parsed.isUnparsed {
                self.usage = parsed
                cache.save(parsed, file: "usage.json")
                cliState = .ready
                lastError = nil
            } else {
                lastError = .parseFailed("account/usage/read")
            }
        } catch let error as CodexBarError {
            handle(error: error)
        } catch is CancellationError {
        } catch {
            handle(error: .cliFailed(error.localizedDescription))
        }
    }

    private func handle(error: CodexBarError) {
        lastError = error
        switch error {
        case .codexNotFound:
            cliState = .notFound
        case .notSignedIn:
            cliState = .notSignedIn
        case .cliFailed, .timeout:
            if case .notFound = cliState {} else {
                cliState = .failing(error.errorDescription ?? String(localized: "failed"))
            }
        case .parseFailed:
            break
        }
        // Keep old cache; UI renders it together with lastError.
    }

    // MARK: - Appearance

    private func applyAppearance() {
        let appearance: NSAppearance?
        switch settings.appearance {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appearance
    }
}
