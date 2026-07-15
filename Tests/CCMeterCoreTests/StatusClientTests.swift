import XCTest
@testable import CCMeterCore

final class StatusClientTests: XCTestCase {
    private struct StubTransport: Transport {
        let result: Result<HTTPResponse, Error>
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            switch result { case .success(let r): return r; case .failure(let e): throw e }
        }
    }
    private func ok(_ body: String) -> StubTransport {
        StubTransport(result: .success(HTTPResponse(status: 200, data: body.data(using: .utf8)!)))
    }

    func testFetchSuccessProducesStatus() async {
        let body = "{\"status\":{\"indicator\":\"major\",\"description\":\"Partial outage\"},\"components\":[{\"name\":\"Codex API\",\"status\":\"major_outage\"}],\"incidents\":[]}"
        let status = await HTTPStatusClient(transport: ok(body)).fetch(.codex)
        XCTAssertEqual(status?.level, .major)
        XCTAssertEqual(status?.provider, .codex)
    }

    func testTransportFailureReturnsNil() async {
        let client = HTTPStatusClient(transport: StubTransport(result: .failure(URLError(.notConnectedToInternet))))
        let status = await client.fetch(.claude)
        XCTAssertNil(status, "our own network failure must never fabricate a status")
    }

    func testNon200ReturnsNil() async {
        let client = HTTPStatusClient(transport: StubTransport(result: .success(HTTPResponse(status: 503, data: Data()))))
        let status = await client.fetch(.claude)
        XCTAssertNil(status)
    }

    func testGarbageBodyReturnsNil() async {
        let status = await HTTPStatusClient(transport: ok("not json")).fetch(.claude)
        XCTAssertNil(status)
    }

    func testStatusURLsPerProvider() {
        XCTAssertEqual(HTTPStatusClient.statusURL(for: .claude).absoluteString, "https://status.claude.com/api/v2/summary.json")
        XCTAssertEqual(HTTPStatusClient.statusURL(for: .codex).absoluteString, "https://status.openai.com/api/v2/summary.json")
    }
}
