//
//  CodexLocator.swift
//  CodexBar
//

import Foundation

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
/// A candidate only counts once `codex --version` actually runs, and wherever
/// possible the Node wrapper is traded for the native binary it would spawn.
enum CodexLocator {

    static let commonPaths = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
    ]

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
    /// login shell. Returns the first candidate that reports a version; if none
    /// do, the first one that at least exists (so the UI can show a path).
    static func locate(override: String?) -> LocatedCodex? {
        var weakest: LocatedCodex?
        for candidate in candidates(override: override) {
            guard let valid = usable(candidate) else { continue }
            let located = resolve(valid)
            if located.version != nil { return located }
            if weakest == nil { weakest = located }
        }
        return weakest
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

    /// `nil` unless the path exists, is a file and is executable.
    private static func usable(_ rawPath: String) -> String? {
        guard let path = normalized(rawPath) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// Turns a validated wrapper path into the thing we actually want to run.
    private static func resolve(_ path: String) -> LocatedCodex {
        // Prefer the native binary over the npm Node wrapper: the wrapper
        // spawns the real binary as a child process, which complicates cleanup
        // and needs `node` on the child `PATH`.
        if let native = nativeBinary(for: path) {
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

    /// Looks for `codex-darwin-*/vendor/<triple>/bin/codex` inside an `@openai`
    /// directory — and one level deeper, because npm has two layouts in the
    /// wild for the platform package:
    ///
    /// * flat (nvm/bun):    `@openai/{codex, codex-darwin-arm64}`
    /// * nested (WorkBuddy): `@openai/codex/node_modules/@openai/codex-darwin-arm64`
    private static func nativeBinary(inOpenAIDirectory directory: String) -> String? {
        var roots = [directory]
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for entry in entries where !entry.hasPrefix(".") {
            roots.append("\(directory)/\(entry)/node_modules/@openai")
        }

        let triples = [hostTriple, "aarch64-apple-darwin", "x86_64-apple-darwin"]
        for root in roots {
            let packages = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for package in packages where package.hasPrefix("codex-darwin-") {
                for triple in triples {
                    let candidate = "\(root)/\(package)/vendor/\(triple)/bin/codex"
                    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
                }
            }
        }
        return nil
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
            if FileManager.default.isExecutableFile(atPath: node.path) { return bin.path }
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
                    if FileManager.default.isExecutableFile(atPath: versioned) {
                        found.append(versioned)
                    }
                }
            }
            let flat = root + "/codex"
            if FileManager.default.isExecutableFile(atPath: flat) {
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

    /// Asks the user's login shell where `codex` lives. This is what makes
    /// custom setups (nvm, fnm, a hand-edited `PATH`, …) work without the app
    /// hard-coding every possible prefix.
    private static func loginShellCodexPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // `-i` so `.zshrc` is sourced; that is where most people put `PATH`.
        proc.arguments = ["-ilc", "command -v codex"]
        let stdout = Pipe()
        let box = OutputCollector()
        // Drain asynchronously: a chatty rc file can otherwise fill the pipe
        // buffer and deadlock the wait below.
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
            proc.terminate()
            stdout.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        // Any trailing startup noise is ignored: `command -v` prints last.
        let last = box.text
            .components(separatedBy: .newlines)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return usable(last ?? "")
    }

    /// Thread-safe sink for a `readabilityHandler`.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    // MARK: - Version probe

    /// `codex --version`, e.g. "codex-cli 0.155.1". `pathEntries` are
    /// prepended to `PATH` so a Node wrapper can be probed even though the app
    /// itself has no `node` on its `PATH`.
    static func version(of path: String, pathEntries: [String] = []) -> String? {
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
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return out?.isEmpty == false ? out : nil
        } catch {
            return nil
        }
    }
}
