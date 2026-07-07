import XCTest
@testable import CCMeterCore

private final class FakeTransport: Transport {
    let status: Int
    let data: Data
    let headers: [String: String]
    var error: Error?
    var capturedRequest: URLRequest?

    init(status: Int, data: Data, headers: [String: String] = [:], error: Error? = nil) {
        self.status = status
        self.data = data
        self.headers = headers
        self.error = error
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        capturedRequest = request
        if let error { throw error }
        return HTTPResponse(status: status, data: data, headers: headers)
    }
}

private struct FakeToken: TokenProviding {
    var token: String?
    func currentToken() throws -> String {
        guard let token else { throw UsageError.noCredentials }
        return token
    }
}

final class UsageClientTests: XCTestCase {
    private func client(status: Int, data: Data, token: String? = "sk-test",
                        headers: [String: String] = [:], error: Error? = nil) -> UsageClient {
        UsageClient(tokenProvider: FakeToken(token: token),
                    transport: FakeTransport(status: status, data: data,
                                             headers: headers, error: error),
                    now: { Date(timeIntervalSince1970: 1783100000) })
    }

    func testSuccessDecodesUsage() async {
        let result = await client(status: 200, data: Fixtures.usageJSON).fetch()
        switch result {
        case .success(let usage): XCTAssertEqual(usage.limits.count, 3)
        case .failure(let e): XCTFail("expected success, got \(e)")
        }
    }

    func testMissingTokenIsNoCredentials() async {
        let result = await client(status: 200, data: Fixtures.usageJSON, token: nil).fetch()
        XCTAssertEqual(result.failureError, .noCredentials)
    }

    func testUnauthorizedMapsToUnauthorized() async {
        let result = await client(status: 401, data: Data()).fetch()
        XCTAssertEqual(result.failureError, .unauthorized)
    }

    func testRateLimitedMapsToRateLimited() async {
        let result = await client(status: 429, data: Data()).fetch()
        XCTAssertEqual(result.failureError, .rateLimited(retryAfter: nil))
    }

    func testRateLimitedParsesRetryAfterSeconds() async {
        let result = await client(status: 429, data: Data(),
                                  headers: ["Retry-After": "300"]).fetch()
        XCTAssertEqual(result.failureError, .rateLimited(retryAfter: 300))
    }

    func testRetryAfterHeaderLookupIsCaseInsensitive() async {
        let result = await client(status: 429, data: Data(),
                                  headers: ["retry-after": "120"]).fetch()
        XCTAssertEqual(result.failureError, .rateLimited(retryAfter: 120))
    }

    func testNonNumericRetryAfterFallsBackToNil() async {
        // The HTTP-date form is valid per spec; we don't parse it, we fall back.
        let result = await client(status: 429, data: Data(),
                                  headers: ["Retry-After": "Tue, 07 Jul 2026 20:00:00 GMT"]).fetch()
        XCTAssertEqual(result.failureError, .rateLimited(retryAfter: nil))
    }

    func testTransportErrorMapsToNetwork() async {
        let err = NSError(domain: "test", code: -1)
        let result = await client(status: 0, data: Data(), error: err).fetch()
        if case .network = result.failureError { } else { XCTFail("expected network error") }
    }

    func testOtherStatusMapsToNetwork() async {
        let result = await client(status: 500, data: Data()).fetch()
        if case .network(let message) = result.failureError {
            XCTAssertTrue(message.contains("500"))
        } else {
            XCTFail("expected network error for HTTP 500")
        }
    }

    func testSendsCorrectRequest() async {
        let transport = FakeTransport(status: 200, data: Fixtures.usageJSON)
        let client = UsageClient(tokenProvider: FakeToken(token: "sk-test"),
                                 transport: transport,
                                 now: { Date(timeIntervalSince1970: 1783100000) })
        _ = await client.fetch()
        let req = transport.capturedRequest
        XCTAssertEqual(req?.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(req?.httpMethod, "GET")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testDecodeFailureMapsToBadResponse() async {
        // 200 with an undecodable body is deterministic -> badResponse (not transient).
        let result = await client(status: 200, data: Data("not json".utf8)).fetch()
        if case .badResponse(let message) = result.failureError {
            XCTAssertTrue(message.contains("decode"))
        } else {
            XCTFail("expected badResponse for an undecodable 200 body")
        }
    }

    func testForbiddenMapsToUnauthorized() async {
        // 403 is a hard credential/permission error, not a transient blip.
        let result = await client(status: 403, data: Data()).fetch()
        XCTAssertEqual(result.failureError, .unauthorized)
    }

    func testUnexpectedClientStatusMapsToBadResponse() async {
        let result = await client(status: 404, data: Data()).fetch()
        if case .badResponse(let message) = result.failureError {
            XCTAssertTrue(message.contains("404"))
        } else {
            XCTFail("expected badResponse for HTTP 404")
        }
    }
}

private extension Result where Failure == UsageError {
    var failureError: UsageError? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
