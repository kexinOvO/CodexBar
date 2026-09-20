//
//  CodexSessionSecurityTests.swift
//  CodexBarTests
//

import XCTest
@testable import CodexBar

final class CodexSessionSecurityTests: XCTestCase {

    func testAutomatedSlashCommandAllowListIsExact() {
        XCTAssertTrue(CodexCLI.isAllowedAutomatedCommand("/status"))
        XCTAssertTrue(CodexCLI.isAllowedAutomatedCommand("/usage daily"))
        XCTAssertTrue(CodexCLI.isAllowedAutomatedCommand("/usage"))

        XCTAssertFalse(CodexCLI.isAllowedAutomatedCommand("/quit"))
        XCTAssertFalse(CodexCLI.isAllowedAutomatedCommand("hello"))
        XCTAssertFalse(CodexCLI.isAllowedAutomatedCommand("/status/status"))
        XCTAssertFalse(CodexCLI.isAllowedAutomatedCommand("/usage daily/usage daily"))
        XCTAssertFalse(CodexCLI.isAllowedAutomatedCommand("/status\nhello"))
        XCTAssertFalse(CodexCLI.isAllowedAutomatedCommand(" /status"))
    }

    func testSessionAllowsOnlyOneAutomatedSlashCommand() {
        let session = CodexSession()
        XCTAssertTrue(session.reserveAutomatedSlashCommand())
        XCTAssertFalse(session.reserveAutomatedSlashCommand())
        XCTAssertFalse(session.reserveAutomatedSlashCommand())
    }

    func testEnvironmentDoesNotForwardUnrelatedSecrets() {
        let environment = CodexCLI.childEnvironment()

        // These are representative secrets that may exist in a developer's
        // login environment but are unrelated to CodexBar's child process.
        XCTAssertNil(environment["GITHUB_TOKEN"])
        XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(environment["NPM_TOKEN"])

        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertFalse((environment["PATH"] ?? "").isEmpty)
    }
}
