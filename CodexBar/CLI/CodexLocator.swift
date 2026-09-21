//
//  CodexLocator.swift
//  CodexBar
//

import Foundation
import Darwin

/// Finds the Codex CLI binary and reports its version.
///
/// Detection is harder than it looks: an app launched by Finder or `launchd`
/// inherits a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), so whatever the
/// user's shell resolves for `codex` is invisible here. On top of that the npm
/// `codex` is a Node shebang script, so even a correct path fails when `node`
/// isn't reachable.
///
/// The strategy is therefore:
/// 1. the user's explicit override,
/// 2. well-known package-manager prefixes,
/// 3. the process `PATH`,
/// 4. a scan of versioned install roots (nvm, WorkBuddy's managed Node, …),
/// 5. a last-resort question to the user's login shell.
///
/// A candidate only counts once a bounded `codex --version` probe succeeds and
/// returns a Codex-looking version string. Wherever possible the Node wrapper
/// is traded for the native binary it would spawn.
enum CodexLocator {

    static let commonPaths = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
    ]

    private static let versionProbeTimeout: TimeInterval = 3
    private static let maxProbeOutputBytes = 64 * 1024

    struct LocatedCodex {
        /// The executable to actually launch (the native binary when we can
        /// find it, otherwise the discovered wrapper).
        var path: String
        /// What discovery matched. Kept separate from `path` so the settings
        /// field can show — and persist — the stable, human-meaningful path
        /// (e.g. `~/.nvm/.../bin/codex`) instead of a version-pinned binary.
        var sourcePath: String
        var version: String?
        /// Directories to prepend to the child `PATH`. Populated only when the
        /// Node wrapper is used, so it can find `node`.
        var pathEntries: [String] = []
    }

    // MARK: - Discovery

    /// Priority: user override → common prefixes → `PATH` → scanned installs →
    /// login shell. Only a candidate that successfully identifies itself as
    /// Codex is returned; an arbitrary executable that merely exists is never
    /// launched by the app-server path.
    static func locate(override: String?) -> LocatedCodex? {
        for candidate in candidates(override: override) {
            guard let valid = usable(candidate) else { continue }
            let located = resolve(valid)
            if located.version != nil { return located }
        }
        return nil
    }

    /// Validates exactly one path and nothing else. Used by the settings
    /// "Detect" button so a typo is reported instead of silently falling back
    /// to some other install.
    static func inspect(path: String) -> LocatedCodex? {
        guard let valid = usable(path) else { return nil }
        let located = resolve(valid)
        return located.version != nil ? located : nil
    }

    private static func candidates(override: String?) -> [String] {
        var candidates: [String] = []
        if let override = normalized(override) {
            candidates.append(override)
        }
        candidates.append(contentsOf: commonPaths)
        candidates.append(contentsOf: pathDirectories().map { $0 + "/codex" })
        candidates.append(contentsOf: discoveredInstallPaths())
        if let fromShell = loginShellCodexPath() {
            candidates.append(fromShell)
        }
        return candidates
    }

    /// Expands `~`, strips surrounding quotes and ignores blank input.
    static func normalized(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return (text as NSString).expandingTildeInPath
    }

    /// `nil` unless the path resolves to a regular executable owned by the
    /// current user or root and is not group/world-writable. This rejects the
    /// most dangerous PATH-hijack cases without breaking normal Homebrew/nvm
    /// installations or an explicit user-owned Codex install.
    private static func usable(_ rawPath: String) -> String? {
        guard let path = normalized(rawPath) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }

        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              let owner = attributes[.ownerAccountID] as? NSNumber else {
            return nil
        }

        let mode = permissions.uint16Value
        guard mode & 0o022 == 0 else { return nil }

        let ownerID = uid_t(owner.uint32Value)
        guard ownerID == 0 || ownerID == geteuid() else { return nil }
        return path
    }

    /// Turns a validated wrapper path into the thing we actually want to run.
    private static func resolve(_ path: String) -> LocatedCodex {
        // Prefer the native binary over the npm Node wrapper: the wrapper
        // spawns the real binary as a child process, which complicates cleanup
        // and needs `node` on the child `PATH`.
        if let native = nativeBinary(for: path), usable(native) != nil {
            return LocatedCodex(path: native, sourcePath: path, version: version(of: native))
        }
        let bin = nodeBinDirectory(forWrapper: path).map { [$0] } ?? []
        return LocatedCodex(path: path,
                            sourcePath: path,
                            version: version(of: path, pathEntries: bin),
                            pathEntries: bin)
    }

    // MARK: - npm wrapper → native binary

    /// npm layout: `<prefix>/bin/codex` is a symlink into
    /// `<prefix>/lib/node_modules/@openai/codex/bin/codex.js`, which spawns
    /// `<prefix>/lib/node_modules/@openai/codex-darwin-<arch>/vendor/<triple>/bin/codex`.
    static func nativeBinary(for wrapper: String) -> String? {
        var roots: [String] = []

        // The symlink usually already points inside `node_modules`, which is
        // the most reliable place to start from (it survives any prefix
        // layout, including the `<version>/lib/...` nesting).
        let resolved = URL(fileURLWithPath: wrapper).resolvingSymlinksInPath().path
        if let range = resolved.range(of: "/node_modules/@openai/", options: .backwards) {
            roots.append(trimmedTrailingSlash(String(resolved[..<range.upperBound])))
        }

        // …and for wrappers that are real files, walk up looking for the
        // conventional roots.
        var url = URL(fileURLWithPath: wrapper)
        for _ in 0..<8 {
            url = url.deletingLastPathComponent()
            roots.append(url.appendingPathComponent("node_modules/@openai").path)
            roots.append(url.appendingPathComponent("lib/node_modules/@openai").path)
            if url.path.isEmpty || url.path == "/" { break }
        }

        for root in roots where FileManager.default.fileExists(atPath: root) {
            if let binary = nativeBinary(inOpenAIDirectory: root) { return binary }
        }
        return nil
    }

    /// Looks only for the platform package expected on the current CPU. This
    /// avoids treating an unrelated `codex-darwin-*` directory as authoritative.
    /// Both flat and nested npm layouts are supported.
    private static func nativeBinary(inOpenAIDirectory directory: String) -> String? {
        var roots = [directory]
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for entry in entries where !entry.hasPrefix(".") {
            roots.append("\(directory)/\(entry)/node_modules/@openai")
        }

        for root in roots {
            let candidate = "\(root)/\(hostPackage)/vendor/\(hostTriple)/bin/codex"
            if usable(candidate) != nil { return candidate }
        }
        return nil
    }

    private static var hostPackage: String {
        #if arch(arm64)
        return "codex-darwin-arm64"
        #else
        return "codex-darwin-x64"
        #endif
    }

    private static var hostTriple: String {
        #if arch(arm64)
        return "aarch64-apple-darwin"
        #else
        return "x86_64-apple-darwin"
        #endif
    }

    /// Keeps generated paths free of `//`, which would otherwise show up in the
    /// settings UI.
    private static func trimmedTrailingSlash(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Walks up from a wrapper looking for a sibling `bin/node`, e.g.
    /// `…/nvm/versions/node/v24.19.0/lib/node_modules/@openai/…` → `…/v24.19.0/bin`.
    static func nodeBinDirectory(forWrapper wrapper: String) -> String? {
        var url = URL(fileURLWithPath: wrapper).resolvingSymlinksInPath()
        for _ in 0..<10 {
            url = url.deletingLastPathComponent()
            let bin = url.appendingPathComponent("bin")
            let node = bin.appendingPathComponent("node")
            if usable(node.path) != nil { return bin.path }
            if url.path.isEmpty || url.path == "/" { break }
        }
        return nil
    }

    // MARK: - PATH

    /// The process `PATH`, plus the directories a macOS GUI app usually loses.
    static func pathDirectories() -> [String] {
        var dirs: [String] = []
        let raw = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        dirs.append(contentsOf: raw.components(separatedBy: ":"))
        dirs.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
        ])
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func findOnPath(_ name: String) -> String? {
        for dir in pathDirectories() {
            let candidate = dir + "/" + name
            if usable(candidate) != nil { return candidate }
        }
        return nil
    }

    // MARK: - Scanned install roots

    /// Versioned package-manager prefixes. Newest install (by modification
    /// date) wins, which correlates with newest CLI version.
    private static func discoveredInstallPaths() -> [String] {
        let home = NSHomeDirectory()
        let roots = [
            home + "/.workbuddy/binaries/node/versions",  // WorkBuddy managed Node
            home + "/.nvm/versions/node",
            home + "/.nodenv/versions",
            home + "/.fnm/node-versions",                 // fnm
            home + "/.volta/bin",                         // volta (flat)
            home + "/.bun/bin",                           // bun (flat)
            home + "/.local/bin",                         // pipx / uv (flat)
            home + "/Library/pnpm",                       // pnpm (flat)
            home + "/.asdf/shims",                        // asdf (flat)
        ]

        var found: [String] = []
        for root in roots {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: root) {
                for entry in entries where !entry.hasPrefix(".") {
                    let versioned = "\(root)/\(entry)/bin/codex"
                    if usable(versioned) != nil {
                        found.append(versioned)
                    }
                }
            }
            let flat = root + "/codex"
            if usable(flat) != nil {
                found.append(flat)
            }
        }
        return found.sorted { modificationDate($0) > modificationDate($1) }
    }

    private static func modificationDate(_ path: String) -> Date {
        // Stat the target, not the symlink, so a freshly installed version
        // sorts by when its payload landed.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: - Login shell

    /// Asks the user's login shell where `codex` lives. This remains a
    /// last-resort fallback for custom setups. Output is bounded and the shell
    /// is killed after five seconds so a noisy or broken rc file cannot hang
    /// CodexBar indefinitely.
    private static func loginShellCodexPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard usable(shell) != nil else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // `-i` so `.zshrc` is sourced; that is where most people put `PATH`.
        proc.arguments = ["-ilc", "command -v codex"]
        let stdout = Pipe()
        let box = OutputCollector(limit: maxProbeOutputBytes)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            box.append(handle.availableData)
        }
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline { usleep(50_000) }
        if proc.isRunning {
            terminate(proc)
            stdout.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        stdout.fileHandleForReading.readabilityHandler = nil

        let snapshot = box.snapshot
        guard !snapshot.overflowed else { return nil }
        // Any trailing startup noise is ignored: `command -v` prints last.
        let last = snapshot.text
            .components(separatedBy: .newlines)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return usable(last ?? "")
    }

    /// Thread-safe bounded sink for a `readabilityHandler`.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var data = Data()
        private var didOverflow = false

        init(limit: Int) {
            self.limit = max(1, limit)
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }

            let remaining = max(0, limit - data.count)
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                didOverflow = true
            }
        }

        var snapshot: (text: String, overflowed: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (String(data: data, encoding: .utf8) ?? "", didOverflow)
        }
    }

    // MARK: - Version probe

    /// Runs a bounded `codex --version` probe. Both stdout and stderr are
    /// drained asynchronously, the process is terminated after three seconds,
    /// and only a Codex-looking version string is accepted.
    static func version(of path: String, pathEntries: [String] = []) -> String? {
        guard usable(path) != nil else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        if !pathEntries.isEmpty {
            var env = ProcessInfo.processInfo.environment
            var dirs = pathEntries
            dirs.append(contentsOf: (env["PATH"] ?? "").components(separatedBy: ":"))
            dirs.append(contentsOf: pathDirectories())
            var seen = Set<String>()
            env["PATH"] = dirs
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .joined(separator: ":")
            proc.environment = env
        }

        let stdout = Pipe()
        let stderr = Pipe()
        let output = OutputCollector(limit: maxProbeOutputBytes)
        let errors = OutputCollector(limit: maxProbeOutputBytes)
        stdout.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { errors.append($0.availableData) }
        proc.standardOutput = stdout
        proc.standardError = stderr
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let deadline = Date().addingTimeInterval(versionProbeTimeout)
        while proc.isRunning && Date() < deadline { usleep(25_000) }
        let timedOut = proc.isRunning
        if timedOut { terminate(proc) }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        guard !timedOut, proc.terminationStatus == 0 else { return nil }
        let stdoutSnapshot = output.snapshot
        let stderrSnapshot = errors.snapshot
        guard !stdoutSnapshot.overflowed, !stderrSnapshot.overflowed else { return nil }

        let text = stdoutSnapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeCodexVersion(text) else { return nil }
        return text
    }

    private static func looksLikeCodexVersion(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 4_096 else { return false }
        let pattern = #"(?i)\b(?:openai\s+)?codex(?:-cli)?\b[^\r\n]{0,96}\b\d+\.\d+(?:\.\d+)?\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let gracefulDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < gracefulDeadline { usleep(25_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < killDeadline { usleep(25_000) }
        }
    }
}
