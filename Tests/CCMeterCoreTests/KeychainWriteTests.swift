import XCTest
@testable import CCMeterCore

private func blob(access: String, refresh: String) -> Data {
    Data(#"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)"}}"#.utf8)
}

final class KeychainWriteTests: XCTestCase {
    // MARK: - The secret must not travel through argv

    /// `security add-generic-password … -w <secret>` put the whole credential blob — access
    /// AND refresh token — on the command line, where any process on the machine can read it
    /// out of `ps aux` for the duration of the call.
    func testCredentialBlobIsPassedOnStdinAndNeverInArguments() throws {
        let spy = SpyCommandRunner.succeeding()
        let writer = KeychainWriter(service: "svc", account: "acct", runner: spy)
        let secret = blob(access: "SECRET-ACCESS", refresh: "SECRET-REFRESH")

        try writer.writeBlob(secret)

        let args = try XCTUnwrap(spy.commands.first?.arguments)
        for arg in args {
            XCTAssertFalse(arg.contains("SECRET-ACCESS"), "access token leaked into argv: \(arg)")
            XCTAssertFalse(arg.contains("SECRET-REFRESH"), "refresh token leaked into argv: \(arg)")
        }

        let stdin = try XCTUnwrap(spy.commands.first?.input)
        let text = try XCTUnwrap(String(data: stdin, encoding: .utf8))
        XCTAssertTrue(text.contains("SECRET-ACCESS"), "the secret must actually reach security, on stdin")
    }

    /// `security -w` prompts *and asks to retype*, so a single copy on stdin fails with
    /// "passwords don't match" and silently stores nothing.
    func testSecretIsWrittenTwiceBecauseSecurityAsksToRetypeIt() throws {
        let spy = SpyCommandRunner.succeeding()
        let writer = KeychainWriter(service: "svc", account: "acct", runner: spy)

        try writer.writeBlob(blob(access: "A", refresh: "R"))

        let stdin = try XCTUnwrap(spy.commands.first?.input)
        let lines = String(data: stdin, encoding: .utf8)!
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, "security retypes the password; it needs the secret twice")
        XCTAssertEqual(lines[0], lines[1])
    }

    func testNonZeroExitIsReportedRatherThanSilentlyIgnored() {
        let spy = SpyCommandRunner(results: [CommandResult(status: 1, standardOutput: Data(), standardError: Data("item not found".utf8), timedOut: false)])
        let writer = KeychainWriter(service: "svc", account: "acct", runner: spy)

        XCTAssertThrowsError(try writer.writeBlob(blob(access: "A", refresh: "R")))
    }

    // MARK: - The lost-update race against the `claude` CLI

    /// cc-meter edits the *Claude CLI's* Keychain item. Both notice expiry at the same moment,
    /// so both refresh at the same moment. Anthropic rotates the refresh token on use, so a
    /// blind read-modify-write clobbers whichever rotation landed first — invalidating a live
    /// refresh token and signing the user out of Claude Code.
    func testWriteIsAbandonedWhenAnotherProcessRotatedTheRefreshTokenUnderUs() throws {
        // Read returns a blob whose refresh token is NOT the one we based our refresh on:
        // the CLI got there first.
        let spy = SpyCommandRunner.succeeding([blob(access: "their-access", refresh: "their-new-refresh")])
        let store = KeychainCredentialStore(
            reader: KeychainReader(service: "svc", account: "acct", runner: spy),
            writer: KeychainWriter(service: "svc", account: "acct", runner: spy)
        )

        XCTAssertThrowsError(
            try store.write(accessToken: "our-access",
                            refreshToken: "our-new-refresh",
                            expiresAt: nil,
                            expectedCurrentRefreshToken: "the-old-one-we-read")
        ) { error in
            XCTAssertEqual(error as? CredentialWriteError, .concurrentRotation)
        }

        XCTAssertEqual(spy.commands.count, 1, "only the read should have run; the write must be abandoned")
    }

    func testWriteProceedsWhenTheRefreshTokenIsStillTheOneWeRead() throws {
        let spy = SpyCommandRunner.succeeding([
            blob(access: "old-access", refresh: "unchanged-refresh"),   // read
            Data()                                                      // write
        ])
        let store = KeychainCredentialStore(
            reader: KeychainReader(service: "svc", account: "acct", runner: spy),
            writer: KeychainWriter(service: "svc", account: "acct", runner: spy)
        )

        try store.write(accessToken: "our-access",
                        refreshToken: "our-new-refresh",
                        expiresAt: nil,
                        expectedCurrentRefreshToken: "unchanged-refresh")

        XCTAssertEqual(spy.commands.count, 2, "read then write")
    }
}
