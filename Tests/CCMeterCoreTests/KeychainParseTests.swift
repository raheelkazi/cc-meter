import XCTest
@testable import CCMeterCore

final class KeychainParseTests: XCTestCase {
    func testParsesAccessTokenFromBlob() throws {
        let token = try parseToken(from: Fixtures.credentialBlob)
        XCTAssertEqual(token, "sk-test-abc123")
    }

    func testThrowsNoCredentialsForEmptyToken() {
        let blob = #"{"claudeAiOauth":{"accessToken":""}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try parseToken(from: blob)) { error in
            XCTAssertEqual(error as? UsageError, .noCredentials)
        }
    }

    func testThrowsNoCredentialsForMissingOAuth() {
        let blob = #"{"mcpOAuth":{}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try parseToken(from: blob)) { error in
            XCTAssertEqual(error as? UsageError, .noCredentials)
        }
    }
}
