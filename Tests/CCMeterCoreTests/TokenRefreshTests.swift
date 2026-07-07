import XCTest
@testable import CCMeterCore

private final class FakeCredentialStore: CredentialStoring {
    var credentials: StoredCredentials
    var rawBlob: Data
    var written: (accessToken: String, refreshToken: String?, expiresAt: Date?)?

    init(credentials: StoredCredentials, rawBlob: Data = Data("{}".utf8)) {
        self.credentials = credentials
        self.rawBlob = rawBlob
    }

    func read() throws -> (credentials: StoredCredentials, rawBlob: Data) {
        (credentials, rawBlob)
    }

    func write(accessToken: String, refreshToken: String?, expiresAt: Date?) throws {
        written = (accessToken, refreshToken, expiresAt)
        credentials = StoredCredentials(accessToken: accessToken,
                                        refreshToken: refreshToken ?? credentials.refreshToken,
                                        expiresAt: expiresAt)
    }
}

/// A transport returning a queued sequence of responses (one per call).
private final class SequencedTransport: Transport {
    private var responses: [Result<HTTPResponse, Error>]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Result<HTTPResponse, Error>]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let next = responses.isEmpty ? .success(HTTPResponse(status: 500, data: Data())) : responses.removeFirst()
        return try next.get()
    }
}

private struct FixedToken: TokenProviding {
    let token: String
    func currentToken() throws -> String { token }
}

final class TokenRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func refreshBody(access: String, refresh: String? = nil, expiresIn: Double? = nil) -> Data {
        var dict: [String: Any] = ["access_token": access]
        if let refresh { dict["refresh_token"] = refresh }
        if let expiresIn { dict["expires_in"] = expiresIn }
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    func testRefreshWritesBackAndReturnsToken() async throws {
        let store = FakeCredentialStore(
            credentials: StoredCredentials(accessToken: "old", refreshToken: "rt", expiresAt: nil))
        let transport = SequencedTransport([.success(HTTPResponse(status: 200,
            data: refreshBody(access: "new", refresh: "rt2", expiresIn: 3600)))])
        let refresher = OAuthTokenRefresher(store: store, transport: transport, now: { self.now })

        let result = try await refresher.refresh()
        XCTAssertEqual(result, "new")
        XCTAssertEqual(store.written?.accessToken, "new")
        XCTAssertEqual(store.written?.refreshToken, "rt2")
        XCTAssertEqual(store.written?.expiresAt, now.addingTimeInterval(3600))
    }

    func testRefreshReturnsNilWithoutRefreshToken() async throws {
        let store = FakeCredentialStore(
            credentials: StoredCredentials(accessToken: "old", refreshToken: nil, expiresAt: nil))
        let transport = SequencedTransport([])
        let refresher = OAuthTokenRefresher(store: store, transport: transport, now: { self.now })
        let result = try await refresher.refresh()
        XCTAssertNil(result)
        XCTAssertNil(store.written)
    }

    func testRefreshReturnsNilOnNon200() async throws {
        let store = FakeCredentialStore(
            credentials: StoredCredentials(accessToken: "old", refreshToken: "rt", expiresAt: nil))
        let transport = SequencedTransport([.success(HTTPResponse(status: 400, data: Data()))])
        let refresher = OAuthTokenRefresher(store: store, transport: transport, now: { self.now })
        let result = try await refresher.refresh()
        XCTAssertNil(result)
        XCTAssertNil(store.written)
    }

    // MARK: - UsageClient integration

    func testClientRefreshesOn401ThenRetries() async {
        let store = FakeCredentialStore(
            credentials: StoredCredentials(accessToken: "old", refreshToken: "rt", expiresAt: nil))
        // 1st usage call: 401. Refresh call: 200 new token. 2nd usage call: 200 usage.
        let transport = SequencedTransport([
            .success(HTTPResponse(status: 401, data: Data())),
            .success(HTTPResponse(status: 200, data: refreshBody(access: "new"))),
            .success(HTTPResponse(status: 200, data: Fixtures.usageJSON))
        ])
        let refresher = OAuthTokenRefresher(store: store, transport: transport, now: { self.now })
        let client = UsageClient(tokenProvider: FixedToken(token: "old"),
                                 transport: transport,
                                 refresher: refresher,
                                 now: { self.now })
        let result = await client.fetch()
        guard case .success(let usage) = result else { return XCTFail("expected success after refresh") }
        XCTAssertEqual(usage.limits.count, 3)
        // Retried usage request carried the refreshed bearer token.
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer new")
    }

    func testClientStaysUnauthorizedWhenRefreshUnavailable() async {
        let store = FakeCredentialStore(
            credentials: StoredCredentials(accessToken: "old", refreshToken: nil, expiresAt: nil))
        let transport = SequencedTransport([.success(HTTPResponse(status: 401, data: Data()))])
        let refresher = OAuthTokenRefresher(store: store, transport: transport, now: { self.now })
        let client = UsageClient(tokenProvider: FixedToken(token: "old"),
                                 transport: transport,
                                 refresher: refresher,
                                 now: { self.now })
        let result = await client.fetch()
        guard case .failure(.unauthorized) = result else { return XCTFail("expected unauthorized fallback") }
    }
}
