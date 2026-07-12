import XCTest
@testable import CCMeterCore

private struct StubCodexResolver: CodexExecutableResolving {
    let url: URL?
    func resolve() -> URL? { url }
}

private final class StubCodexTransport: CodexAppServerTransport {
    var result: Result<Data, Error>
    private(set) var executable: URL?
    private(set) var input: Data?
    private(set) var responseID: Int?
    private(set) var timeout: TimeInterval?

    init(_ result: Result<Data, Error>) { self.result = result }

    func exchange(executable: URL, input: Data,
                  responseID: Int, timeout: TimeInterval) async throws -> Data {
        self.executable = executable
        self.input = input
        self.responseID = responseID
        self.timeout = timeout
        return try result.get()
    }
}

final class CodexUsageClientTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/test/codex")
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func client(response: Data = Fixtures.codexMultiLimitJSON,
                        error: Error? = nil,
                        executable: URL? = URL(fileURLWithPath: "/test/codex"))
        -> (CodexUsageClient, StubCodexTransport) {
        let transport = StubCodexTransport(error.map(Result.failure) ?? .success(response))
        let client = CodexUsageClient(
            resolver: StubCodexResolver(url: executable),
            transport: transport,
            appVersion: "9.9.9",
            timeout: 4,
            now: { self.now }
        )
        return (client, transport)
    }

    func testSendsStableHandshakeAndRateLimitRequest() async {
        let (client, transport) = client()
        _ = await client.fetch()

        XCTAssertEqual(transport.executable, executable)
        XCTAssertEqual(transport.responseID, 2)
        XCTAssertEqual(transport.timeout, 4)
        let lines = String(data: transport.input!, encoding: .utf8)!
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("\"method\":\"initialize\""))
        XCTAssertTrue(lines[0].contains("\"name\":\"cc_meter\""))
        XCTAssertTrue(lines[0].contains("\"version\":\"9.9.9\""))
        XCTAssertEqual(lines[1], "{\"method\":\"initialized\"}")
        XCTAssertEqual(lines[2], "{\"method\":\"account/rateLimits/read\",\"id\":2}")
    }

    func testMissingExecutableIsNoCredentials() async {
        let (client, _) = client(executable: nil)
        let result = await client.fetch()
        XCTAssertEqual(result.failureError, .noCredentials)
    }

    func testAuthenticationProtocolErrorIsUnauthorized() async {
        let data = "{\"id\":2,\"error\":{\"code\":-32000,\"message\":\"Unauthorized\"}}"
            .data(using: .utf8)!
        let (client, _) = client(response: data)
        let result = await client.fetch()
        XCTAssertEqual(result.failureError, .unauthorized)
    }

    func testMethodNotFoundAsksUserToUpdateCodex() async {
        let data = "{\"id\":2,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}"
            .data(using: .utf8)!
        let (client, _) = client(response: data)
        guard case .badResponse(let message) = await client.fetch().failureError else {
            return XCTFail("expected bad response")
        }
        XCTAssertTrue(message.contains("update Codex"))
    }

    func testOverloadedProtocolErrorIsTransient() async {
        let data = "{\"id\":2,\"error\":{\"code\":-32001,\"message\":\"Server overloaded\"}}"
            .data(using: .utf8)!
        let (client, _) = client(response: data)
        guard case .network = await client.fetch().failureError else {
            return XCTFail("expected network error")
        }
    }

    func testTransportFailuresAreTransient() async {
        for error in [CodexTransportError.launch("boom"), .timeout, .prematureEOF("closed")] {
            let (client, _) = client(error: error)
            guard case .network = await client.fetch().failureError else {
                return XCTFail("expected network error for \(error)")
            }
        }
    }

    func testMalformedResponseIsBadResponse() async {
        let (client, _) = client(response: Data("not json".utf8))
        guard case .badResponse(let message) = await client.fetch().failureError else {
            return XCTFail("expected bad response")
        }
        XCTAssertTrue(message.contains("Codex response"))
    }

    func testResolverSelectsFirstExecutableCandidate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-codex-resolver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let missing = directory.appendingPathComponent("missing")
        let executable = directory.appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: executable.path)

        XCTAssertEqual(CodexExecutableResolver(candidates: [missing, executable]).resolve(), executable)
    }
}

private extension Result where Failure == UsageError {
    var failureError: UsageError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
