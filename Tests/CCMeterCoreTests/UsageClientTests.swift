import XCTest
@testable import CCMeterCore

private struct FakeTransport: Transport {
    let status: Int
    let data: Data
    var error: Error?
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if let error { throw error }
        return HTTPResponse(status: status, data: data)
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
                        error: Error? = nil) -> UsageClient {
        UsageClient(tokenProvider: FakeToken(token: token),
                    transport: FakeTransport(status: status, data: data, error: error),
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
        XCTAssertEqual(result.failureError, .rateLimited)
    }

    func testTransportErrorMapsToNetwork() async {
        let err = NSError(domain: "test", code: -1)
        let result = await client(status: 0, data: Data(), error: err).fetch()
        if case .network = result.failureError { } else { XCTFail("expected network error") }
    }
}

private extension Result where Failure == UsageError {
    var failureError: UsageError? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
