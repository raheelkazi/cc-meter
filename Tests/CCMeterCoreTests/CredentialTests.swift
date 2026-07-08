import XCTest
@testable import CCMeterCore

final class CredentialTests: XCTestCase {
    func testParsesFullCredentials() throws {
        let creds = try parseCredentials(from: Fixtures.credentialBlob)
        XCTAssertEqual(creds.accessToken, "sk-test-abc123")
        XCTAssertEqual(creds.refreshToken, "rt-test")
        // expiresAt is epoch millis 1783113000000 -> seconds 1783113000.
        XCTAssertEqual(creds.expiresAt, Date(timeIntervalSince1970: 1_783_113_000))
    }

    func testParsesWhenRefreshAndExpiryAbsent() throws {
        let blob = #"{"claudeAiOauth":{"accessToken":"only-access"}}"#.data(using: .utf8)!
        let creds = try parseCredentials(from: blob)
        XCTAssertEqual(creds.accessToken, "only-access")
        XCTAssertNil(creds.refreshToken)
        XCTAssertNil(creds.expiresAt)
    }

    func testUpdatedBlobReplacesTokensAndPreservesOtherKeys() throws {
        let updated = try updatedBlob(original: Fixtures.credentialBlob,
                                      accessToken: "new-access",
                                      refreshToken: "new-refresh",
                                      expiresAt: Date(timeIntervalSince1970: 2000))
        let root = try JSONSerialization.jsonObject(with: updated) as! [String: Any]
        let oauth = root["claudeAiOauth"] as! [String: Any]
        XCTAssertEqual(oauth["accessToken"] as? String, "new-access")
        XCTAssertEqual(oauth["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual(oauth["expiresAt"] as? Int, 2_000_000)   // ms
        // Unowned fields are preserved.
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertNotNil(root["mcpOAuth"])
    }

    func testUpdatedBlobRoundTripsThroughParse() throws {
        let updated = try updatedBlob(original: Fixtures.credentialBlob,
                                      accessToken: "rotated",
                                      refreshToken: nil,
                                      expiresAt: nil)
        // Passing nil refresh leaves the original refresh token intact.
        let creds = try parseCredentials(from: updated)
        XCTAssertEqual(creds.accessToken, "rotated")
        XCTAssertEqual(creds.refreshToken, "rt-test")
    }
}
