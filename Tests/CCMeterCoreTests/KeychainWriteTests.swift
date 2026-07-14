import XCTest
@testable import CCMeterCore

/// Records what was handed to `security`, so we can assert the secret never reaches argv.
private final class SpyKeychainCommand: KeychainCommandRunning {
    private(set) var arguments: [[String]] = []
    private(set) var inputs: [Data?] = []
    var results: [(status: Int32, output: Data)]
    var launchError: Error?

    init(results: [(status: Int32, output: Data)]) {
        self.results = results
    }

    func run(executable: String, arguments: [String], input: Data?) throws -> (status: Int32, output: Data) {
        self.arguments.append(arguments)
        self.inputs.append(input)
        if let launchError { throw launchError }
        return results.isEmpty ? (0, Data()) : results.removeFirst()
    }
}

private func blob(access: String, refresh: String) -> Data {
    Data(#"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)"}}"#.utf8)
}

final class KeychainWriteTests: XCTestCase {
    // MARK: - The secret must not travel through argv

    /// `security add-generic-password … -w <secret>` put the whole credential blob — access
    /// AND refresh token — on the command line, where any process on the machine can read it
    /// out of `ps aux` for the duration of the call.
    func testCredentialBlobIsPassedOnStdinAndNeverInArguments() throws {
        let spy = SpyKeychainCommand(results: [(0, Data())])
        let writer = KeychainWriter(service: "svc", account: "acct", runner: spy)
        let secret = blob(access: "SECRET-ACCESS", refresh: "SECRET-REFRESH")

        try writer.writeBlob(secret)

        let args = try XCTUnwrap(spy.arguments.first)
        for arg in args {
            XCTAssertFalse(arg.contains("SECRET-ACCESS"), "access token leaked into argv: \(arg)")
            XCTAssertFalse(arg.contains("SECRET-REFRESH"), "refresh token leaked into argv: \(arg)")
        }

        let stdin = try XCTUnwrap(spy.inputs.first ?? nil)
        let text = try XCTUnwrap(String(data: stdin, encoding: .utf8))
        XCTAssertTrue(text.contains("SECRET-ACCESS"), "the secret must actually reach security, on stdin")
    }

    /// `security -w` prompts *and asks to retype*, so a single copy on stdin fails with
    /// "passwords don't match" and silently stores nothing.
    func testSecretIsWrittenTwiceBecauseSecurityAsksToRetypeIt() throws {
        let spy = SpyKeychainCommand(results: [(0, Data())])
        let writer = KeychainWriter(service: "svc", account: "acct", runner: spy)

        try writer.writeBlob(blob(access: "A", refresh: "R"))

        let stdin = try XCTUnwrap(spy.inputs.first ?? nil)
        let lines = String(data: stdin, encoding: .utf8)!
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, "security retypes the password; it needs the secret twice")
        XCTAssertEqual(lines[0], lines[1])
    }

    func testNonZeroExitIsReportedRatherThanSilentlyIgnored() {
        let spy = SpyKeychainCommand(results: [(1, Data())])
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
        let spy = SpyKeychainCommand(results: [(0, blob(access: "their-access", refresh: "their-new-refresh"))])
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

        XCTAssertEqual(spy.arguments.count, 1, "only the read should have run; the write must be abandoned")
    }

    func testWriteProceedsWhenTheRefreshTokenIsStillTheOneWeRead() throws {
        let spy = SpyKeychainCommand(results: [
            (0, blob(access: "old-access", refresh: "unchanged-refresh")),   // read
            (0, Data())                                                       // write
        ])
        let store = KeychainCredentialStore(
            reader: KeychainReader(service: "svc", account: "acct", runner: spy),
            writer: KeychainWriter(service: "svc", account: "acct", runner: spy)
        )

        try store.write(accessToken: "our-access",
                        refreshToken: "our-new-refresh",
                        expiresAt: nil,
                        expectedCurrentRefreshToken: "unchanged-refresh")

        XCTAssertEqual(spy.arguments.count, 2, "read then write")
    }
}
