//
//  CodexSession.swift
//  CodexBar
//

import Foundation
import Darwin

/// Runs Codex CLI inside a PTY, drives it with slash commands and captures
/// raw output. No user input is forwarded; nothing is sent to any server by
/// this layer — the CLI itself does its own (already signed-in) networking.
final class CodexSession: @unchecked Sendable {

    private var masterFD: Int32 = -1
    private var process: Process?
    private var readSource: DispatchSourceRead?

    private let lock = NSLock()
    private var buffer = Data()
    private var automatedSlashCommandSubmitted = false

    /// OSC colour queries already answered in this session (`"]10;?"` /
    /// `"]11;?"`). Only touched from the read source's serial queue.
    private var answeredColorQueries: Set<String> = []

    private var childEnvironment: [String: String] = [:]

    // MARK: - Lifecycle

    /// Spawns `codex` in an isolated, empty working directory so that no
    /// project-level AGENTS.md / hooks / config is loaded.
    func start(executablePath: String, workingDirectory: String) throws {
        try FileManager.default.createDirectory(atPath: workingDirectory,
                                                withIntermediateDirectories: true)
        // The workspace exists only to isolate Codex from project-level files.
        // Keep other local users from planting or reading content in it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: workingDirectory)

        lock.lock()
        buffer.removeAll()
        automatedSlashCommandSubmitted = false
        lock.unlock()
        answeredColorQueries.removeAll()

        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw CodexBarError.cliFailed("openpty failed (errno \(errno))")
        }
        masterFD = master

        // Give the TUI a sane window size.
        var ws = winsize(ws_row: 50, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slave, UInt(TIOCSWINSZ), &ws)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = []
        proc.currentDirectoryPath = workingDirectory
        proc.environment = childEnvironment

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle

        let source = DispatchSource.makeReadSource(fileDescriptor: master,
                                                   queue: DispatchQueue(label: "codexbar.pty.read"))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let n = read(master, &chunk, chunk.count)
            if n > 0 {
                self.lock.lock()
                self.buffer.append(contentsOf: chunk[0..<n])
                self.lock.unlock()
                self.answerColorQueries()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.buffer.removeAll()
            self.lock.unlock()
        }
        source.resume()
        readSource = source

        do {
            try proc.run()
            process = proc
            close(slave) // child owns its copy now
        } catch {
            close(slave)
            source.cancel()
            readSource = nil
            if masterFD >= 0 {
                close(masterFD)
                masterFD = -1
            }
            throw error
        }
    }

    /// Appends environment entries for the child (TERM, proxy overrides…).
    func setEnvironment(_ env: [String: String]) {
        childEnvironment = env
    }

    func send(_ text: String) {
        guard masterFD >= 0 else { return }
        let data = Data(text.utf8)
        data.withUnsafeBytes { ptr in
            var offset = 0
            while offset < ptr.count {
                let n = write(masterFD, ptr.baseAddress!.advanced(by: offset), ptr.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    /// Claims the one automated slash-command submission allowed for this PTY.
    /// A session is never reused for a second slash command: if Enter is ever
    /// swallowed, retrying in the same composer could concatenate two commands
    /// and turn them into a normal model prompt (for example `/status/status`).
    func reserveAutomatedSlashCommand() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !automatedSlashCommandSubmitted else { return false }
        automatedSlashCommandSubmitted = true
        return true
    }

    /// Raw output accumulated so far.
    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8) ?? ""
    }

    // MARK: - Terminal colour queries

    /// Answers the CLI's default-colour queries (`OSC 10;?` for the foreground,
    /// `OSC 11;?` for the background) the way a real terminal would.
    ///
    /// This is not cosmetic. When nobody answers, the CLI cannot resolve the
    /// terminal's theme and collapses its heatmap ramp: every non-empty day is
    /// painted with the *same* colour, and the 5-tier intensity information is
    /// gone before the parser ever sees it (verified against codex-cli 0.155.1 —
    /// answered: `#F7E6CD #F1CFA0 #E9B265 #DF8E1D`, unanswered: 4× `#F9E2AF`).
    ///
    /// We report a light background so the ramp comes back as distinct steps;
    /// the app maps those colours onto its own accent palette, so the reported
    /// theme never reaches the screen.
    private func answerColorQueries() {
        lock.lock()
        let seen = buffer
        lock.unlock()

        for (query, response) in Self.colorQueryResponses
        where !answeredColorQueries.contains(query) {
            guard seen.range(of: Data("\u{1B}\(query)".utf8)) != nil else { continue }
            answeredColorQueries.insert(query)
            send("\u{1B}\(response)\u{1B}\\")
        }
    }

    /// Query prefix -> reply. Replies use the ST terminator (`ESC \\`), which
    /// the CLI's parser accepts and which can't be confused with input.
    private static let colorQueryResponses: [(String, String)] = [
        ("]10;?", "]10;rgb:0000/0000/0000"),
        ("]11;?", "]11;rgb:ffff/ffff/ffff"),
    ]

    /// Waits until `pattern` appears in cleaned output, or (when no pattern is
    /// requested) output has actually remained quiet for `quietSeconds`, or
    /// `timeout` elapses. Returns true only when a pattern was found.
    func waitFor(pattern: String?, quietSeconds: TimeInterval, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSize = currentBufferSize()
        var quietSince = Date()

        while Date() < deadline {
            let text = ANSITextCleaner.clean(snapshot())
            if let pattern, text.range(of: pattern, options: .caseInsensitive) != nil {
                return true
            }

            let size = currentBufferSize()
            if size != lastSize {
                lastSize = size
                quietSince = Date()
            } else if pattern == nil,
                      Date().timeIntervalSince(quietSince) >= max(0, quietSeconds) {
                return false
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    private func currentBufferSize() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    func stop() {
        // Kill descendants while the parent relationship still exists. If the
        // npm wrapper is terminated first, its native Codex child may be
        // re-parented and no longer discoverable with `pgrep -P`.
        if let process, process.isRunning {
            killDescendants(of: process.processIdentifier, depth: 4)
            process.terminate()
            // Grace period, then hard kill.
            for _ in 0..<20 where process.isRunning {
                usleep(100_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        readSource?.cancel()
        readSource = nil
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        process = nil
    }

    private func killDescendants(of pid: pid_t, depth: Int) {
        guard depth > 0 else { return }
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        pgrep.standardInput = FileHandle.nullDevice
        do {
            try pgrep.run()
        } catch {
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        for line in output.components(separatedBy: "\n") {
            if let child = pid_t(line.trimmingCharacters(in: .whitespaces)) {
                killDescendants(of: child, depth: depth - 1)
                kill(child, SIGKILL)
            }
        }
    }

    deinit {
        stop()
    }
}

// MARK: - High-level fetch

/// Every automated slash-command attempt gets a fresh, short-lived PTY.
/// A session is never reused for a retry: this is a deliberate safety boundary
/// preventing residual composer text from turning a slash command into a chat
/// prompt sent to the model.
enum CodexCLI {

    struct StatusResult {
        var statusRaw: String?
        var versionLine: String?
    }

    struct UsageResult {
        var usageRaw: String?
        var versionLine: String?
    }

    private static let allowedAutomatedSlashCommands: Set<String> = [
        "/status",
        "/usage daily",
        "/usage",
    ]

    /// Exposed internally for regression tests. Automated TUI input must never
    /// become an arbitrary chat prompt, even if a future caller passes bad text.
    static func isAllowedAutomatedCommand(_ command: String) -> Bool {
        allowedAutomatedSlashCommands.contains(command)
    }

    /// Starts codex, handles trust prompts, waits for a known idle composer and
    /// detects a signed-out state before any slash command is allowed through.
    private static func startReadySession(executablePath: String,
                                          workingDirectory: String,
                                          timeout: TimeInterval,
                                          pathEntries: [String]) async throws -> CodexSession {
        let session = CodexSession()
        session.setEnvironment(Self.childEnvironment(pathEntries: pathEntries))

        do {
            try session.start(executablePath: executablePath, workingDirectory: workingDirectory)
        } catch let error as CodexBarError {
            session.stop()
            throw error
        } catch {
            session.stop()
            throw CodexBarError.cliFailed("launch failed: \(error.localizedDescription)")
        }

        let placeholders = ["Ask Codex", "Explain this codebase"]
        let readinessDeadline = Date().addingTimeInterval(min(60, max(5, timeout)))
        var trustHandled = false
        var composerReady = false

        while Date() < readinessDeadline {
            let cleaned = ANSITextCleaner.clean(session.snapshot())
            let lower = cleaned.lowercased()

            if lower.contains("not signed in") {
                session.stop()
                throw CodexBarError.notSignedIn
            }

            if !trustHandled,
               cleaned.localizedCaseInsensitiveContains("Do you trust the contents of this directory") {
                // This is a fresh isolated workspace and no composer exists yet.
                // Confirm the trust prompt once, then wait for the real composer.
                trustHandled = true
                session.send("\r")
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            if placeholders.contains(where: { cleaned.localizedCaseInsensitiveContains($0) }) {
                composerReady = true
                break
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        guard composerReady else {
            session.stop()
            throw CodexBarError.timeout
        }

        // A placeholder can render before the final startup re-renders finish.
        // `waitFor` now honours the full quiet period rather than only ~0.8 s.
        _ = await session.waitFor(pattern: nil,
                                  quietSeconds: 5,
                                  timeout: min(20, max(5, timeout)))
        return session
    }

    static func versionLine(in raw: String) -> String? {
        StatusParser.firstMatch(in: ANSITextCleaner.clean(raw), pattern: #"Codex \(v([^)]+)\)"#)
    }

    /// Submits exactly one allow-listed slash command as a bracketed paste.
    /// Character-by-character typing triggers slash autocomplete, while a
    /// second submission in the same PTY could concatenate with stale text.
    private static func pasteAndSubmit(_ session: CodexSession,
                                       command: String) async throws {
        guard isAllowedAutomatedCommand(command) else {
            throw CodexBarError.cliFailed("refusing non-allow-listed automated input")
        }
        guard session.reserveAutomatedSlashCommand() else {
            throw CodexBarError.cliFailed("refusing a second slash command in one CLI session")
        }

        session.send("\u{1B}[200~\(command)\u{1B}[201~")
        try? await Task.sleep(nanoseconds: 800_000_000)
        session.send("\r")
    }

    /// Polls cleaned output for either the expected card marker or the TUI's
    /// task-running hint ("Esc to interrupt"). A model-turn marker wins over a
    /// card marker: once a command leaks into chat, the session is unsafe and
    /// must be destroyed without sending any more input.
    private static func waitForCardOrLeak(_ session: CodexSession,
                                          card: String,
                                          timeout: TimeInterval) async -> (Bool, Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = ANSITextCleaner.clean(session.snapshot())
            if text.range(of: "Esc to interrupt", options: .caseInsensitive) != nil {
                return (false, true)
            }
            if text.range(of: card, options: .caseInsensitive) != nil {
                return (true, false)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return (false, false)
    }

    // MARK: /status

    static func fetchStatus(executablePath: String,
                            workingDirectory: String,
                            timeout: TimeInterval,
                            pathEntries: [String] = []) async throws -> StatusResult {
        var lastVersion: String?

        // At most two attempts, and every retry starts a brand-new TUI. If the
        // first Enter was swallowed, its residual `/status` dies with that PTY.
        for _ in 0..<2 {
            let session = try await startReadySession(executablePath: executablePath,
                                                      workingDirectory: workingDirectory,
                                                      timeout: timeout,
                                                      pathEntries: pathEntries)
            try await pasteAndSubmit(session, command: "/status")
            let (hit, leaked) = await waitForCardOrLeak(session,
                                                        card: "5h limit",
                                                        timeout: min(45, timeout))
            let raw = session.snapshot()
            lastVersion = versionLine(in: raw) ?? lastVersion
            session.stop()

            if leaked {
                throw CodexBarError.cliFailed("slash command was interpreted as a chat prompt")
            }
            if hit {
                return StatusResult(statusRaw: raw, versionLine: lastVersion)
            }
        }

        // Fail closed: never let startup/banner text masquerade as /status.
        return StatusResult(statusRaw: nil, versionLine: lastVersion)
    }

    // MARK: /usage daily

    static func fetchUsage(executablePath: String,
                           workingDirectory: String,
                           timeout: TimeInterval,
                           pathEntries: [String] = []) async throws -> UsageResult {
        // Usage goes to the network backend and can be slow; allow a generous
        // window regardless of the short CLI timeout.
        let waitTimeout = max(180, timeout)
        var lastVersion: String?

        // Preferred path: `/usage daily`, once, in its own PTY.
        do {
            let session = try await startReadySession(executablePath: executablePath,
                                                      workingDirectory: workingDirectory,
                                                      timeout: timeout,
                                                      pathEntries: pathEntries)
            try await pasteAndSubmit(session, command: "/usage daily")
            let (hit, leaked) = await waitForCardOrLeak(session,
                                                        card: "Token activity",
                                                        timeout: waitTimeout / 2)
            if hit {
                _ = await session.waitFor(pattern: nil,
                                          quietSeconds: 12,
                                          timeout: min(120, waitTimeout / 2))
            }
            let raw = session.snapshot()
            lastVersion = versionLine(in: raw) ?? lastVersion
            session.stop()

            if leaked {
                throw CodexBarError.cliFailed("slash command was interpreted as a chat prompt")
            }
            if hit {
                return UsageResult(usageRaw: raw, versionLine: lastVersion)
            }
        }

        // Compatibility fallback for CLI versions that expose usage through
        // `/usage` → "Show usage". This is a fresh PTY, so no text from the
        // failed `/usage daily` attempt can survive into its composer.
        let session = try await startReadySession(executablePath: executablePath,
                                                  workingDirectory: workingDirectory,
                                                  timeout: timeout,
                                                  pathEntries: pathEntries)
        try await pasteAndSubmit(session, command: "/usage")

        let (menuFound, menuLeaked) = await waitForCardOrLeak(session,
                                                              card: "Show usage",
                                                              timeout: min(30, waitTimeout / 3))
        if menuLeaked {
            session.stop()
            throw CodexBarError.cliFailed("slash command was interpreted as a chat prompt")
        }
        guard menuFound else {
            let raw = session.snapshot()
            lastVersion = versionLine(in: raw) ?? lastVersion
            session.stop()
            return UsageResult(usageRaw: nil, versionLine: lastVersion)
        }

        // `/usage` is already confirmed to have opened its local menu. Enter
        // selects the highlighted "Show usage" item; no second slash command
        // is ever injected into this session.
        try? await Task.sleep(nanoseconds: 500_000_000)
        session.send("\r")

        let (hit, leaked) = await waitForCardOrLeak(session,
                                                    card: "Token activity",
                                                    timeout: waitTimeout / 2)
        if hit {
            _ = await session.waitFor(pattern: nil,
                                      quietSeconds: 12,
                                      timeout: min(120, waitTimeout / 2))
        }
        let raw = session.snapshot()
        lastVersion = versionLine(in: raw) ?? lastVersion
        session.stop()

        if leaked {
            throw CodexBarError.cliFailed("usage menu selection entered a model turn")
        }
        return UsageResult(usageRaw: hit ? raw : nil,
                           versionLine: lastVersion)
    }

    /// Child environment is intentionally allow-listed instead of blindly
    /// forwarding every secret present in the GUI process environment. Keep
    /// only values Codex commonly needs for identity/configuration, locale,
    /// TLS and proxies; PATH is rebuilt below.
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
        env["TERM"] = "xterm-256color"

        var dirs = pathEntries
        dirs.append(contentsOf: (parent["PATH"] ?? "").components(separatedBy: ":"))
        dirs.append(contentsOf: CodexLocator.pathDirectories())
        var seen = Set<String>()
        env["PATH"] = dirs
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")

        let hasProxy = ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"]
            .contains { env[$0]?.isEmpty == false }
        if !hasProxy, let proxy = SystemProxy.httpsProxy() {
            env["https_proxy"] = proxy
            env["HTTPS_PROXY"] = proxy
        }
        return env
    }
}

/// Reads the macOS system-wide HTTP/HTTPS proxy (e.g. Clash on 127.0.0.1).
enum SystemProxy {
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
