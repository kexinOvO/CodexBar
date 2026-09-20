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

        lock.lock()
        buffer.removeAll()
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

        try proc.run()
        process = proc
        close(slave) // child owns its copy now
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

    /// Query prefix -> reply. Replies use the ST terminator (`ESC \`), which
    /// the CLI's parser accepts and which can't be confused with input.
    private static let colorQueryResponses: [(String, String)] = [
        ("]10;?", "]10;rgb:0000/0000/0000"),
        ("]11;?", "]11;rgb:ffff/ffff/ffff"),
    ]

    /// Waits until `pattern` appears in cleaned output, or output is quiet for
    /// `quietSeconds`, or `timeout` elapses. Returns true when pattern found.
    func waitFor(pattern: String?, quietSeconds: TimeInterval, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = ANSITextCleaner.clean(snapshot())
            if let pattern, text.range(of: pattern, options: .caseInsensitive) != nil {
                return true
            }
            let size = currentBufferSize()
            try? await Task.sleep(nanoseconds: 400_000_000)
            if pattern == nil && currentBufferSize() == size {
                // No pattern requested: quiet detection is enough.
                let size2 = currentBufferSize()
                try? await Task.sleep(nanoseconds: 400_000_000)
                if size2 == currentBufferSize() { return false }
            }
        }
        return false
    }

    private func currentBufferSize() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
            // Grace period, then hard kill.
            for _ in 0..<20 where process.isRunning {
                usleep(100_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        // The npm `codex` launcher is a Node wrapper that spawns a native
        // binary; killing the wrapper orphans it. Kill the descendants too.
        if let process {
            killDescendants(of: process.processIdentifier, depth: 2)
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

/// Runs each slash command in its own short-lived session. A dedicated
/// session per command is more reliable than reusing one TUI: the /status
/// popup otherwise swallows the following command's text.
enum CodexCLI {

    struct StatusResult {
        var statusRaw: String?
        var versionLine: String?
    }

    struct UsageResult {
        var usageRaw: String?
        var versionLine: String?
    }

    /// Starts codex, waits for TUI readiness, handles trust prompts and
    /// detects a signed-out state.
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

        // Wait for TUI readiness in two phases: first output, then the idle
        // input placeholder (a command sent too early is silently dropped).
        _ = await session.waitFor(pattern: "Codex", quietSeconds: 5, timeout: min(45, timeout))
        let readyText = session.snapshot()
        let placeholders = ["Ask Codex", "Explain this codebase"]
        if !placeholders.contains(where: { readyText.localizedCaseInsensitiveContains($0) }) {
            for placeholder in placeholders {
                if await session.waitFor(pattern: placeholder,
                                         quietSeconds: 4,
                                         timeout: min(40, timeout)) {
                    break
                }
            }
        }
        // The placeholder can render while the TUI is still initializing
        // ("model: loading"). Give it a settle period so typed commands and
        // the Enter key aren't swallowed by re-renders.
        _ = await session.waitFor(pattern: nil, quietSeconds: 5, timeout: 20)

        if readyText.lowercased().contains("not signed in")
            || session.snapshot().lowercased().contains("not signed in") {
            session.stop()
            throw CodexBarError.notSignedIn
        }
        if session.snapshot().contains("Do you trust the contents of this directory") {
            session.send("\r")
            _ = await session.waitFor(pattern: nil, quietSeconds: 4, timeout: 20)
        }
        return session
    }

    private static func quit(_ session: CodexSession) {
        session.send("\u{1B}")
        usleep(500_000)
        session.send("/quit\r")
        usleep(1_500_000)
        session.stop()
    }

    static func versionLine(in raw: String) -> String? {
        StatusParser.firstMatch(in: ANSITextCleaner.clean(raw), pattern: #"Codex \(v([^)]+)\)"#)
    }

    // MARK: /status

    static func fetchStatus(executablePath: String,
                            workingDirectory: String,
                            timeout: TimeInterval,
                            pathEntries: [String] = []) async throws -> StatusResult {
        let session = try await startReadySession(executablePath: executablePath,
                                                  workingDirectory: workingDirectory,
                                                  timeout: timeout,
                                                  pathEntries: pathEntries)
        defer { quit(session) }

        // "5h limit" only appears in the /status card — the startup warning
        // ("...weekly limit left...") and banner don't contain it.
        // One retry in case the first command got swallowed mid-init.
        var found = false
        for attempt in 0..<2 {
            if attempt > 0 {
                session.send("\u{1B}")
                try? await Task.sleep(nanoseconds: 800_000_000)
                await clearComposer(session)
            }
            await pasteAndSubmit(session, command: "/status")
            let (hit, leaked) = await waitForCardOrLeak(session,
                                                        card: "5h limit",
                                                        timeout: min(45, timeout))
            // Guard against the retry failure mode observed with codex-cli
            // 0.155.1: if Enter was swallowed and the re-paste concatenated
            // ("/status/status"), the TUI submits it as a *chat prompt* to
            // the model — burning tokens and leaving a junk task in the
            // linked ChatGPT account. The interrupt hint only appears while
            // a model turn is running, i.e. the command leaked. Bail out
            // immediately instead of waiting out the clock.
            if leaked { break }
            if hit { found = true; break }
        }
        let raw = session.snapshot()
        return StatusResult(statusRaw: found ? raw : raw,
                            versionLine: versionLine(in: raw))
    }

    // MARK: /usage daily

    /// Submits a command as a bracketed paste. Typing character-by-character
    /// triggers the slash-command autocomplete menu, which swallows the rest
    /// of the text; a paste bypasses per-key handling entirely.
    private static func pasteAndSubmit(_ session: CodexSession, command: String) async {
        session.send("\u{1B}[200~\(command)\u{1B}[201~")
        try? await Task.sleep(nanoseconds: 800_000_000)
        session.send("\r")
    }

    /// Wipes residual composer text with repeated backspaces. ESC alone only
    /// closes popups — it does NOT clear the input line, so a re-paste after
    /// a swallowed Enter would otherwise concatenate with the leftover text
    /// ("/status" + "/status") and go out as a chat prompt to the model.
    /// Extra backspaces on an already-empty composer are harmless no-ops.
    private static func clearComposer(_ session: CodexSession) async {
        session.send(String(repeating: "\u{7F}", count: 80))
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    /// Polls cleaned output for either the expected card marker or the TUI's
    /// task-running hint ("Esc to interrupt"). The hint is only rendered
    /// while a *model turn* is in flight, which for these local slash
    /// commands means the submission leaked as a chat prompt. Returns
    /// `(cardFound, promptLeaked)`; a leak short-circuits the retry ladder.
    private static func waitForCardOrLeak(_ session: CodexSession,
                                          card: String,
                                          timeout: TimeInterval) async -> (Bool, Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = ANSITextCleaner.clean(session.snapshot())
            if text.range(of: card, options: .caseInsensitive) != nil {
                return (true, false)
            }
            if text.range(of: "Esc to interrupt", options: .caseInsensitive) != nil {
                return (false, true)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return (false, false)
    }

    static func fetchUsage(executablePath: String,
                           workingDirectory: String,
                           timeout: TimeInterval,
                           pathEntries: [String] = []) async throws -> UsageResult {
        // Usage goes to the network backend and can be slow; allow a
        // generous window regardless of the short CLI timeout.
        let waitTimeout = max(180, timeout)
        let session = try await startReadySession(executablePath: executablePath,
                                                  workingDirectory: workingDirectory,
                                                  timeout: timeout,
                                                  pathEntries: pathEntries)
        defer { quit(session) }

        // Ladder: paste → second Enter (left unsubmitted) → /usage menu.
        var found = false
        for attempt in 0..<3 {
            switch attempt {
            case 0:
                await pasteAndSubmit(session, command: "/usage daily")
            case 1:
                session.send("\r")
            default:
                // Same guard as fetchStatus: wipe residual composer text so
                // the typed "/usage" can't concatenate with leftovers.
                session.send("\u{1B}")
                try? await Task.sleep(nanoseconds: 400_000_000)
                await clearComposer(session)
                session.send("/usage\r")
                if await session.waitFor(pattern: "Show usage", quietSeconds: 8, timeout: 30) {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    session.send("\r")
                }
            }
            // Accidental chat-prompt leak detector (see fetchStatus).
            let (hit, leaked) = await waitForCardOrLeak(session,
                                                        card: "Token activity",
                                                        timeout: waitTimeout / 3)
            if leaked { break }
            found = hit
            if found {
                // The header can appear in a "Token activity   Loading..."
                // frame while the heatmap is still being fetched from the
                // backend. Wait for output to go quiet before capturing.
                _ = await session.waitFor(pattern: nil,
                                          quietSeconds: 12,
                                          timeout: min(120, waitTimeout / 3))
                break
            }
        }
        let raw = session.snapshot()
        return UsageResult(usageRaw: found ? raw : nil,
                           versionLine: versionLine(in: raw))
    }

    /// Child environment: inherits the app environment, ensures TERM looks
    /// like a real terminal, and propagates the macOS system HTTPS proxy so
    /// the CLI's backend requests behave like they do in the user's terminal.
    ///
    /// `pathEntries` are prepended to `PATH`; the locator supplies them when it
    /// had to fall back to the Node-based npm wrapper, which needs `node` on
    /// `PATH` — something a Finder-launched app does not have.
    static func childEnvironment(pathEntries: [String] = []) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"

        var dirs = pathEntries
        dirs.append(contentsOf: (env["PATH"] ?? "").components(separatedBy: ":"))
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
