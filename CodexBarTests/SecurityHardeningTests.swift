//
//  SecurityHardeningTests.swift
//  CodexBarTests
//

import XCTest
@testable import CodexBar

final class SecurityHardeningTests: XCTestCase {

    func testNonCodexExecutableIsRejected() {
        XCTAssertNil(CodexLocator.inspect(path: "/usr/bin/true"))
    }

    func testWorldWritableCandidateIsRejectedBeforeExecution() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarSecurityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("codex")
        try "#!/bin/sh\necho 'codex-cli 9.9.9'\n".write(to: executable,
                                                           atomically: true,
                                                           encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o777],
                                              ofItemAtPath: executable.path)

        XCTAssertNil(CodexLocator.inspect(path: executable.path))
    }

    func testPersistedTimingSettingsAreFiniteAndBounded() throws {
        let json = """
        {
          "statusRefreshInterval": 1e100,
          "usageRefreshInterval": -10,
          "cliTimeout": 1e100
        }
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.statusRefreshInterval, 3_600)
        XCTAssertEqual(decoded.usageRefreshInterval, 300)
        XCTAssertEqual(decoded.cliTimeout, 600)
    }
}
