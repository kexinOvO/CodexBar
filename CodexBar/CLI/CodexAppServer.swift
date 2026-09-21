//
//  CodexAppServer.swift
//  CodexBar
//

import Foundation
import Darwin

// MARK: - Wire models

/// Minimal shapes from Codex app-server's public protocol. Keeping these local
/// avoids coupling CodexBar to generated bindings while still decoding the
/// structured API instead of scraping terminal text.
struct AppServerAccountResponse: Decodable {
    var account: AppServerAccount?
    var requiresOpenaiAuth: Bool
}

struct AppServerAccount: Decodable {
    var type: String
    var email: String?
    var planType: String?
    var usesCodexManagedCredentials: Bool?
}

struct AppServerRateLimitWindow: Decodable {
    var usedPercent: Double
    var windowDurationMins: Double?
    var resetsAt: Double?
}

struct AppServerRateLimitSnapshot: Decodable {
    var limitId: String?
    var limitName: String?
    var normalModelSlug: String?
    var primary: AppServerRateLimitWindow?
    var secondary: AppServerRateLimitWindow?
    var planType: String?
}

struct AppServerRateLimitsResponse: Decodable {
    var ordinaryUsageAllowed: Bool?
    var rateLimits: AppServerRateLimitSnapshot
    var rateLimitsByLimitId: [String: AppServerRateLimitSnapshot]?
    var accountId: String?
}

struct AppServerTokenUsageSummary: Decodable {
    var lifetimeTokens: Int64?
    var peakDailyTokens: Int64?
    var longestRunningTurnSec: Int64?
    var currentStreakDays: Int64?
    var longestStreakDays: Int64?
}

struct AppServerDailyUsageBucket: Decodable {
    var startDate: String
    var tokens: Int64
}

struct AppServerTokenUsageResponse: Decodable {
    var summary: AppServerTokenUsageSummary
    var dailyUsageBuckets: [AppServerDailyUsageBucket]?
}

// MARK: - Stdio app-server session

/// One short-lived `codex app-server` child process speaking the Codex wire
/// protocol over newline-delimited JSON on stdin/stdout.
///
/// There is deliberately no PTY, terminal emulator, composer, slash command,
/// paste operation or simulated Enter key in this path.
final class CodexAppServerSession: @unchecked Sendable {

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var stdoutBuffer = Data()
    private var nextRequestID = 1
    private var started = false

    private let stderrLock = NSLock()
    private var stderrTail = Data()
    private let maxStderrBytes = 65_536
    private let maxStdoutFrameBytes = 4 * 1024 * 1024

    /// The app-server identifies itself in the initialize response. This is
    /// useful diagnostically, but CodexBar still displays the locator's
    /// `codex --version` result because that format is stable in the UI.
    private(set) var userAgent: String?

    func start(executablePath: String,
               workingDirectory: String,
               environment: [String: String],
               timeout: TimeInterval) throws {
        guard !started else { return }

        try FileManager.default.createDirectory(atPath: workingDirectory,
                                                withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: workingDirectory)

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server"]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory,
                                          isDirectory: true)
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.stderrLock.lock()
            self.stderrTail.append(data)
            if self.stderrTail.count > self.maxStderrBytes {
                self.stderrTail.removeFirst(self.stderrTail.count - self.maxStderrBytes)
            }
            self.stderrLock.unlock()
        }

        do {
            try process.run()
            started = true
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw CodexBarError.cliFailed("failed to launch codex app-server: \(error.localizedDescription)")
        }

        do {
            let initialize = try request(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "codexbar",
                        "title": "CodexBar",
                        "version": Self.clientVersion,
                    ],
                    "capabilities": [
                        "experimentalApi": false,
                        "requestAttestation": false,
                    ],
                ],
                timeout: timeout
            )
            userAgent = initialize["userAgent"] as? String
            try sendNotification(method: "initialized", params: nil)
        } catch {
            stop()
            throw error
        }
    }

    /// Codex intentionally omits the `jsonrpc: "2.0"` field. Keep envelope
    /// construction testable so a future refactor cannot accidentally add it.
    static func requestEnvelope(id: Int,
                                method: String,
                                params: [String: Any]? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "method": method,
        ]
        if let params {
            object["params"] = params
        }
        return object
    }

    func request(method: String,
                 params: [String: Any]? = nil,
                 timeout: TimeInterval) throws -> [String: Any] {
        guard started, process.isRunning else {
            throw CodexBarError.cliFailed("codex app-server is not running")
        }

        let id = nextRequestID
        nextRequestID += 1
        try writeJSON(Self.requestEnvelope(id: id, method: method, params: params))

        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while Date() < deadline {
            let message = try readJSONObject(deadline: deadline)

            if let inboundID = message["id"],
               let inboundMethod = message["method"] as? String {
                // A read-only usage client should not receive server requests,
                // but reply explicitly rather than leave the server blocked.
                try respondUnsupported(id: inboundID, method: inboundMethod)
                continue
            }

            guard Self.id(message["id"], matches: id) else {
                // Notifications and responses to unrelated IDs are irrelevant
                // to this strictly sequential client.
                continue
            }

            if let error = message["error"] as? [String: Any] {
                throw Self.protocolError(method: method, error: error)
            }
            guard let result = message["result"] as? [String: Any] else {
                throw CodexBarError.cliFailed("codex app-server returned an invalid response for \(method)")
            }
            return result
        }

        throw CodexBarError.timeout
    }

    func stop() {
        guard started else { return }
        started = false

        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()

        if process.isRunning {
            // Give app-server a short chance to notice EOF and exit cleanly.
            for _ in 0..<5 where process.isRunning {
                usleep(100_000)
            }
        }
        if process.isRunning {
            Self.killDescendants(of: process.processIdentifier, depth: 4)
            process.terminate()
            for _ in 0..<10 where process.isRunning {
                usleep(100_000)
            }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
    }

    deinit {
        stop()
    }

    // MARK: Wire I/O

    private func sendNotification(method: String,
                                  params: [String: Any]?) throws {
        var object: [String: Any] = ["method": method]
        if let params { object["params"] = params }
        try writeJSON(object)
    }

    private func respondUnsupported(id: Any, method: String) throws {
        try writeJSON([
            "id": id,
            "error": [
                "code": -32601,
                "message": "CodexBar does not implement server request \(method)",
            ],
        ])
    }

    private func writeJSON(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexBarError.cliFailed("invalid app-server request")
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)

        let fd = stdinPipe.fileHandleForWriting.fileDescriptor
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd,
                                           base.advanced(by: offset),
                                           raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                throw CodexBarError.cliFailed("failed writing to codex app-server")
            }
        }
    }

    private func readJSONObject(deadline: Date) throws -> [String: Any] {
        while true {
            if let line = try popLine() {
                if line.isEmpty { continue }
                let object = try JSONSerialization.jsonObject(with: line, options: [])
                guard let dictionary = object as? [String: Any] else {
                    throw CodexBarError.cliFailed("codex app-server emitted non-object JSON")
                }
                return dictionary
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw CodexBarError.timeout }

            var descriptor = pollfd(fd: stdoutPipe.fileHandleForReading.fileDescriptor,
                                    events: Int16(POLLIN | POLLHUP | POLLERR),
                                    revents: 0)
            let milliseconds = Int32(min(Double(Int32.max),
                                         max(1, ceil(remaining * 1_000))))
            let ready = Darwin.poll(&descriptor, 1, milliseconds)
            if ready == 0 { throw CodexBarError.timeout }
            if ready < 0 {
                if errno == EINTR { continue }
                throw CodexBarError.cliFailed("failed reading from codex app-server")
            }

            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(stdoutPipe.fileHandleForReading.fileDescriptor,
                                    &chunk,
                                    chunk.count)
            if count > 0 {
                stdoutBuffer.append(contentsOf: chunk[0..<count])
                if stdoutBuffer.firstIndex(of: 0x0A) == nil,
                   stdoutBuffer.count > maxStdoutFrameBytes {
                    stdoutBuffer.removeAll(keepingCapacity: false)
                    throw CodexBarError.cliFailed("codex app-server response exceeded size limit")
                }
                continue
            }
            if count < 0, errno == EINTR { continue }

            let stderr = stderrText()
            if !stderr.isEmpty {
                throw CodexBarError.cliFailed("codex app-server exited: \(stderr)")
            }
            throw CodexBarError.cliFailed("codex app-server closed stdout")
        }
    }

    private func popLine() throws -> Data? {
        guard let newline = stdoutBuffer.firstIndex(of: 0x0A) else { return nil }
        guard newline <= maxStdoutFrameBytes else {
            stdoutBuffer.removeAll(keepingCapacity: false)
            throw CodexBarError.cliFailed("codex app-server response exceeded size limit")
        }
        var line = Data(stdoutBuffer[..<newline])
        stdoutBuffer.removeSubrange(...newline)
        if line.last == 0x0D { line.removeLast() }
        return line
    }

    private func stderrText() -> String {
        stderrLock.lock()
        let data = stderrTail
        stderrLock.unlock()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func id(_ value: Any?, matches expected: Int) -> Bool {
        if let number = value as? NSNumber { return number.intValue == expected }
        if let string = value as? String { return Int(string) == expected }
        return false
    }

    private static func protocolError(method: String,
                                      error: [String: Any]) -> CodexBarError {
        let code = (error["code"] as? NSNumber)?.intValue
        let message = (error["message"] as? String) ?? "unknown error"
        let lower = message.lowercased()

        if lower.contains("not signed in")
            || lower.contains("login") && lower.contains("required")
            || lower.contains("authentication") && lower.contains("required") {
            return .notSignedIn
        }
        if code == -32601 {
            return .cliFailed("Codex app-server does not support \(method). Update Codex CLI.")
        }
        return .cliFailed("app-server \(method): \(message)")
    }

    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private static func killDescendants(of pid: pid_t, depth: Int) {
        guard depth > 0 else { return }
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        pgrep.standardInput = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") {
            guard let child = pid_t(line.trimmingCharacters(in: .whitespaces)) else { continue }
            killDescendants(of: child, depth: depth - 1)
            kill(child, SIGKILL)
        }
    }
}

// MARK: - High-level structured API

enum CodexAppServerCLI {

    struct StatusResult {
        var status: CodexStatus
        var versionLine: String?
    }

    struct UsageResult {
        var usage: CodexUsage
        var versionLine: String?
    }

    static func fetchStatus(executablePath: String,
                            workingDirectory: String,
                            timeout: TimeInterval,
                            pathEntries: [String] = []) async throws -> StatusResult {
        let session = CodexAppServerSession()
        try session.start(executablePath: executablePath,
                          workingDirectory: workingDirectory,
                          environment: childEnvironment(pathEntries: pathEntries),
                          timeout: max(5, timeout))
        defer { session.stop() }

        let decoder = JSONDecoder()
        let accountJSON = try session.request(method: "account/read",
                                              params: [:],
                                              timeout: max(5, timeout))
        let account: AppServerAccountResponse = try decode(accountJSON, with: decoder)
        if account.requiresOpenaiAuth, account.account == nil {
            throw CodexBarError.notSignedIn
        }

        let limitsJSON = try session.request(
            method: "account/rateLimits/read",
            params: ["excludeResetCreditDetails": true],
            timeout: max(10, timeout)
        )
        let limits: AppServerRateLimitsResponse = try decode(limitsJSON, with: decoder)
        return StatusResult(status: makeStatus(account: account, limits: limits),
                            versionLine: nil)
    }

    static func fetchUsage(executablePath: String,
                           workingDirectory: String,
                           timeout: TimeInterval,
                           pathEntries: [String] = []) async throws -> UsageResult {
        let session = CodexAppServerSession()
        try session.start(executablePath: executablePath,
                          workingDirectory: workingDirectory,
                          environment: childEnvironment(pathEntries: pathEntries),
                          timeout: max(5, timeout))
        defer { session.stop() }

        let decoder = JSONDecoder()
        let accountJSON = try session.request(method: "account/read",
                                              params: [:],
                                              timeout: max(5, timeout))
        let account: AppServerAccountResponse = try decode(accountJSON, with: decoder)
        if account.requiresOpenaiAuth, account.account == nil {
            throw CodexBarError.notSignedIn
        }

        let usageJSON = try session.request(method: "account/usage/read",
                                            params: [:],
                                            timeout: max(180, timeout))
        let response: AppServerTokenUsageResponse = try decode(usageJSON, with: decoder)
        return UsageResult(usage: makeUsage(response), versionLine: nil)
    }

    /// Maps structured rate-limit windows to the existing UI model by duration,
    /// never by primary/secondary position. Codex currently describes the two
    /// windows as ~300 minutes and ~10,080 minutes.
    static func makeStatus(account: AppServerAccountResponse,
                           limits: AppServerRateLimitsResponse,
                           now: Date = Date()) -> CodexStatus {
        let snapshot = preferredSnapshot(in: limits)
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        let fiveHour = matchingWindow(in: windows, targetMinutes: 300)
        let weekly = matchingWindow(in: windows, targetMinutes: 10_080)

        var status = CodexStatus(fetchedAt: now)
        status.model = snapshot.normalModelSlug
        status.accountEmail = account.account?.email
        status.plan = displayPlan(account.account?.planType ?? snapshot.planType)

        if let fiveHour {
            status.fiveHourRemainingPercent = remainingPercent(fiveHour.usedPercent)
            status.fiveHourResetAt = dateFromEpoch(fiveHour.resetsAt)
        }
        if let weekly {
            status.weeklyRemainingPercent = remainingPercent(weekly.usedPercent)
            status.weeklyResetAt = dateFromEpoch(weekly.resetsAt)
        }
        return status
    }

    /// Converts exact daily token buckets into the same 0...4 heat levels used
    /// by Codex's own TUI: 0, >0, >25%, >50%, >75% of the peak day.
    static func makeUsage(_ response: AppServerTokenUsageResponse,
                          now: Date = Date()) -> CodexUsage {
        let summary = response.summary
        let activities: [DailyActivity]
        if let buckets = response.dailyUsageBuckets {
            activities = dailyActivities(from: buckets, now: now)
        } else {
            activities = []
        }

        return CodexUsage(
            lifetimeTokens: summary.lifetimeTokens,
            peakTokens: summary.peakDailyTokens,
            streakDays: summary.currentStreakDays.flatMap(Int.init(exactly:)),
            longestTaskSeconds: summary.longestRunningTurnSec.flatMap(Int.init(exactly:)),
            dailyActivity: activities,
            fetchedAt: now
        )
    }

    static func intensity(tokens: Int64, peak: Int64) -> Int {
        guard tokens > 0, peak > 0 else { return 0 }
        let value = Double(tokens)
        let maximum = Double(peak)
        if value * 4 > maximum * 3 { return 4 }
        if value * 2 > maximum { return 3 }
        if value * 4 > maximum { return 2 }
        return 1
    }

    static func childEnvironment(pathEntries: [String] = []) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        let allowedKeys: Set<String> = [
            "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR",
            "LANG", "LC_ALL", "LC_CTYPE",
            "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
            "CODEX_HOME", "OPENAI_API_KEY", "OPENAI_BASE_URL",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
            "https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY",
            "all_proxy", "ALL_PROXY", "no_proxy", "NO_PROXY",
        ]

        var env: [String: String] = [:]
        for (key, value) in parent
        where allowedKeys.contains(key) || key.hasPrefix("LC_") {
            env[key] = value
        }

        var dirs = pathEntries
        dirs.append(contentsOf: (parent["PATH"] ?? "").components(separatedBy: ":"))
        dirs.append(contentsOf: CodexLocator.pathDirectories())
        var seen = Set<String>()
        env["PATH"] = dirs
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")

        let hasProxy = ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"]
            .contains { env[$0]?.isEmpty == false }
        if !hasProxy, let proxy = AppServerSystemProxy.httpsProxy() {
            env["https_proxy"] = proxy
            env["HTTPS_PROXY"] = proxy
        }
        return env
    }

    // MARK: Mapping helpers

    private static func decode<T: Decodable>(_ object: [String: Any],
                                              with decoder: JSONDecoder) throws -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CodexBarError.cliFailed("invalid structured response from codex app-server: \(error.localizedDescription)")
        }
    }

    private static func preferredSnapshot(in response: AppServerRateLimitsResponse)
        -> AppServerRateLimitSnapshot {
        if let byID = response.rateLimitsByLimitId {
            if let codex = byID.first(where: { $0.key.caseInsensitiveCompare("codex") == .orderedSame })?.value {
                return codex
            }
            if let named = byID.values.first(where: {
                $0.limitId?.caseInsensitiveCompare("codex") == .orderedSame
            }) {
                return named
            }
        }
        return response.rateLimits
    }

    private static func matchingWindow(in windows: [AppServerRateLimitWindow],
                                       targetMinutes: Double) -> AppServerRateLimitWindow? {
        let tolerance = targetMinutes * 0.05
        return windows
            .compactMap { window -> (AppServerRateLimitWindow, Double)? in
                guard let duration = window.windowDurationMins else { return nil }
                let delta = abs(duration - targetMinutes)
                guard delta <= tolerance else { return nil }
                return (window, delta)
            }
            .min(by: { $0.1 < $1.1 })?.0
    }

    private static func remainingPercent(_ used: Double) -> Double {
        min(100, max(0, 100 - used))
    }

    private static func dateFromEpoch(_ seconds: Double?) -> Date? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func displayPlan(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "self_serve_business_prolite", "self_serve_business_usage_based", "business":
            return "Business"
        case "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "enterprise":
            return "Enterprise"
        case "edu": return "Edu"
        case "edu_plus": return "Edu Plus"
        case "edu_pro": return "Edu Pro"
        case "unknown": return nil
        default:
            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func dailyActivities(from buckets: [AppServerDailyUsageBucket],
                                        now: Date) -> [DailyActivity] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1 // Sunday, matching Codex TUI + HeatmapView.

        let today = calendar.startOfDay(for: now)
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let start = calendar.date(byAdding: .weekOfYear,
                                  value: -51,
                                  to: currentWeekStart) ?? currentWeekStart

        var totals: [Date: Int64] = [:]
        for bucket in buckets {
            guard let date = parseDay(bucket.startDate, calendar: calendar) else { continue }
            let day = calendar.startOfDay(for: date)
            guard day >= start, day <= today else { continue }
            let value = max(0, bucket.tokens)
            let old = totals[day, default: 0]
            let (sum, overflow) = old.addingReportingOverflow(value)
            totals[day] = overflow ? Int64.max : sum
        }

        let peak = totals.values.max() ?? 0
        var result: [DailyActivity] = []
        var day = start
        while day <= today {
            let tokens = totals[day] ?? 0
            result.append(DailyActivity(
                date: day,
                tokenCount: tokens > 0 ? tokens : nil,
                intensity: intensity(tokens: tokens, peak: peak)
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    private static func parseDay(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12 // Noon avoids DST midnight edge cases before startOfDay.
        return calendar.date(from: components)
    }
}

/// Reads macOS's system HTTPS proxy so a Finder-launched app-server follows
/// the same network path as Codex in the user's terminal.
enum AppServerSystemProxy {
    static func httpsProxy() -> String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
                as? [String: Any] else { return nil }
        let host = settings["HTTPSProxy"] as? String ?? settings["httpsProxy"] as? String
        let port = settings["HTTPSProxyPort"] as? Int ?? settings["httpsProxyPort"] as? Int
        guard let host, !host.isEmpty else { return nil }
        if let port, port > 0 { return "http://\(host):\(port)" }
        return "http://\(host)"
    }
}
