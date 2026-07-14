import XCTest
@testable import CCMeterCore

private struct StubCodexResolver: CodexExecutableResolving {
    let url: URL?
    func resolve() -> CodexExecutable? {
        url.map { CodexExecutable(url: $0, searchPath: nil) }
    }
}

private final class StubCodexTransport: CodexAppServerTransport {
    var result: Result<[Int: Data], Error>
    private(set) var executable: CodexExecutable?
    private(set) var input: Data?
    private(set) var responseIDs: Set<Int>?
    private(set) var timeout: TimeInterval?

    init(_ result: Result<[Int: Data], Error>) { self.result = result }

    func exchange(executable: CodexExecutable, input: Data,
                  responseIDs: Set<Int>, timeout: TimeInterval) async throws -> [Int: Data] {
        self.executable = executable
        self.input = input
        self.responseIDs = responseIDs
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
        let responses = [
            2: response,
            3: Data(#"{"id":3,"result":{"config":{"model":"gpt-5.6-sol"}}}"#.utf8),
            4: Data(#"{"id":4,"result":{"data":[{"model":"gpt-5.6-sol","displayName":"GPT-5.6-Sol"}]}}"#.utf8)
        ]
        let transport = StubCodexTransport(error.map(Result.failure) ?? .success(responses))
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

        XCTAssertEqual(transport.executable?.url, executable)
        XCTAssertEqual(transport.responseIDs, [2, 3, 4])
        XCTAssertEqual(transport.timeout, 4)
        let lines = String(data: transport.input!, encoding: .utf8)!
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines[0].contains("\"method\":\"initialize\""))
        XCTAssertTrue(lines[0].contains("\"name\":\"cc_meter\""))
        XCTAssertTrue(lines[0].contains("\"version\":\"9.9.9\""))
        XCTAssertEqual(lines[1], "{\"method\":\"initialized\"}")
        XCTAssertEqual(lines[2], "{\"method\":\"account/rateLimits/read\",\"id\":2}")
        XCTAssertEqual(lines[3], "{\"method\":\"config/read\",\"id\":3,\"params\":{}}")
        XCTAssertEqual(lines[4], "{\"method\":\"model/list\",\"id\":4,\"params\":{}}")
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

    func testResolvesActiveModelDisplayNameForUnnamedCodexLimits() async throws {
        let (client, _) = client()

        let result = await client.fetch()
        let usage = try XCTUnwrap(result.successValue)

        XCTAssertEqual(usage.limits.map(\.kind.label), [
            "5-hour · GPT-5.6-Sol",
            "7-day · GPT-5.6-Sol",
            "7-day · GPT-5.3-Codex-Spark"
        ])
    }

    func testMalformedModelMetadataFallsBackToGenericLabels() async throws {
        let (client, transport) = client()
        transport.result = .success([
            2: Fixtures.codexMultiLimitJSON,
            3: Data("not json".utf8),
            4: Data(#"{"id":4,"error":{"code":-32601,"message":"Method not found"}}"#.utf8)
        ])

        let result = await client.fetch()
        let usage = try XCTUnwrap(result.successValue)

        XCTAssertEqual(usage.limits.map(\.kind.label), [
            "5-hour", "7-day", "7-day · GPT-5.3-Codex-Spark"
        ])
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

        XCTAssertEqual(CodexExecutableResolver(candidates: [missing, executable]).resolve()?.url,
                       executable)
    }

    func testProcessTransportHandlesExecutableThatExitsImmediately() async {
        let transport = CodexAppServerProcess()
        do {
            _ = try await transport.exchange(
                executable: CodexExecutable(url: URL(fileURLWithPath: "/usr/bin/false"),
                                            searchPath: nil),
                input: Data(repeating: 0x78, count: 64 * 1024),
                responseIDs: [2, 3, 4],
                timeout: 2
            )
            XCTFail("expected the exited process to fail")
        } catch let error as CodexTransportError {
            guard case .prematureEOF = error else {
                return XCTFail("expected premature EOF, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testProcessTransportCollectsAllExpectedResponses() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-codex-transport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"method":"account/rateLimits/updated"}' '{"id":4,"result":{"data":[]}}' '{"id":2,"result":{"rateLimits":null}}' '{"id":3,"result":{"config":{}}}'
        sleep 1
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: executable.path)

        let responses = try await CodexAppServerProcess().exchange(
            executable: CodexExecutable(url: executable, searchPath: nil),
            input: Data("requests\\n".utf8),
            responseIDs: [2, 3, 4],
            timeout: 2
        )

        XCTAssertEqual(Set(responses.keys), [2, 3, 4])
        XCTAssertTrue(String(data: responses[2]!, encoding: .utf8)!.contains("rateLimits"))
        XCTAssertTrue(String(data: responses[4]!, encoding: .utf8)!.contains("data"))
    }

    /// npm ships codex as a `#!/usr/bin/env node` script, so launching it requires its
    /// interpreter on the child's PATH. Under launchd, cc-meter's PATH is only
    /// /usr/bin:/bin:/usr/sbin:/sbin — which is why Codex silently never appeared.
    private func makeShebangCodex() throws -> (directory: URL, codex: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-codex-shebang-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let interpreter = directory.appendingPathComponent("fakenode")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"id":2,"result":{"rateLimits":null}}' '{"id":3,"result":{"config":{}}}' '{"id":4,"result":{"data":[]}}'
        sleep 1
        """
        try Data(script.utf8).write(to: interpreter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: interpreter.path)

        let codex = directory.appendingPathComponent("codex")
        try Data("#!/usr/bin/env fakenode\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: codex.path)
        return (directory, codex)
    }

    func testProcessTransportLaunchesShebangExecutableUsingSearchPath() async throws {
        let (directory, codex) = try makeShebangCodex()
        defer { try? FileManager.default.removeItem(at: directory) }

        let responses = try await CodexAppServerProcess().exchange(
            executable: CodexExecutable(url: codex,
                                        searchPath: "\(directory.path):/usr/bin:/bin"),
            input: Data("requests\n".utf8),
            responseIDs: [2, 3, 4],
            timeout: 5
        )

        XCTAssertEqual(Set(responses.keys), [2, 3, 4])
    }

    func testProcessTransportFailsWhenInterpreterIsNotOnSearchPath() async throws {
        let (directory, codex) = try makeShebangCodex()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await CodexAppServerProcess().exchange(
                executable: CodexExecutable(url: codex, searchPath: "/usr/bin:/bin"),
                input: Data("requests\n".utf8),
                responseIDs: [2, 3, 4],
                timeout: 5
            )
            XCTFail("expected launch to fail when the interpreter is off the search path")
        } catch is CodexTransportError {
            // Expected: this is the production failure the search path fixes.
        }
    }
}

private extension Result where Failure == UsageError {
    var failureError: UsageError? {
        if case .failure(let error) = self { return error }
        return nil
    }

    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
