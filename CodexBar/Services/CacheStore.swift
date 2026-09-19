//
//  CacheStore.swift
//  CodexBar
//

import Foundation

/// Atomic, corruption-tolerant JSON cache under
/// ~/Library/Application Support/CodexBar/
final class CacheStore: @unchecked Sendable {

    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
            self.directory = base.appendingPathComponent("CodexBar", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory,
                                                 withIntermediateDirectories: true)
    }

    var cliWorkspaceURL: URL {
        directory.appendingPathComponent("CLIWorkspace", isDirectory: true)
    }

    private func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Loads and decodes a cached value. Corrupt or unreadable files are
    /// ignored (and removed) so the app falls back to a fresh fetch.
    func load<T: Codable>(_ type: T.Type, file: String) -> T? {
        let fileURL = url(for: file)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Corrupted cache: remove and start over.
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    /// Atomic write; failures are non-fatal (cache is best-effort).
    func save<T: Codable>(_ value: T, file: String) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url(for: file), options: [.atomic])
        } catch {
            // Ignore write failures; next refresh will retry.
        }
    }

    func remove(file: String) {
        try? FileManager.default.removeItem(at: url(for: file))
    }
}
