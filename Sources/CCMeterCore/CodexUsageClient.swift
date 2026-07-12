import Foundation

public protocol CodexExecutableResolving {
    func resolve() -> URL?
}

public protocol CodexAppServerTransport {
    func exchange(executable: URL,
                  input: Data,
                  responseID: Int,
                  timeout: TimeInterval) async throws -> Data
}

public enum CodexTransportError: Error, Equatable {
    case launch(String)
    case timeout
    case prematureEOF(String)
}

public struct CodexExecutableResolver: CodexExecutableResolving {
    private let candidates: [URL]
    private let fileManager: FileManager

    public init(candidates: [URL]? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.candidates = candidates ?? Self.defaultCandidates()
    }

    public func resolve() -> URL? {
        candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func defaultCandidates() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls = [
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex")
        ]
        if let pathURL = whichCodex() { urls.append(pathURL) }
        urls.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            home.appendingPathComponent(".local/bin/codex")
        ])
        return urls
    }

    private static func whichCodex() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["codex"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}

public struct CodexUsageClient: UsageFetching {
    private let resolver: CodexExecutableResolving
    private let transport: CodexAppServerTransport
    private let appVersion: String
    private let timeout: TimeInterval
    private let now: () -> Date

    public init(resolver: CodexExecutableResolving,
                transport: CodexAppServerTransport,
                appVersion: String,
                timeout: TimeInterval = 10,
                now: @escaping () -> Date = { Date() }) {
        self.resolver = resolver
        self.transport = transport
        self.appVersion = appVersion
        self.timeout = timeout
        self.now = now
    }

    public func fetch() async -> Result<Usage, UsageError> {
        guard let executable = resolver.resolve() else { return .failure(.noCredentials) }
        do {
            let data = try await transport.exchange(executable: executable,
                                                    input: requestData(),
                                                    responseID: 2,
                                                    timeout: timeout)
            let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
            return .success(try response.toUsage(now: now()))
        } catch let error as CodexProtocolError {
            return .failure(mapProtocolError(error))
        } catch let error as CodexTransportError {
            return .failure(.network(transportMessage(error)))
        } catch is DecodingError {
            return .failure(.badResponse("Codex response could not be decoded"))
        } catch CodexResponseError.missingResult {
            return .failure(.badResponse("Codex response did not contain rate limits"))
        } catch {
            return .failure(.network("Codex app server failed: \(error.localizedDescription)"))
        }
    }

    private func requestData() -> Data {
        let encodedVersion = (try? JSONEncoder().encode(appVersion))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"development\""
        let lines = [
            "{\"method\":\"initialize\",\"id\":1,\"params\":{\"clientInfo\":{\"name\":\"cc_meter\",\"title\":\"cc-meter\",\"version\":\(encodedVersion)}}}",
            "{\"method\":\"initialized\"}",
            "{\"method\":\"account/rateLimits/read\",\"id\":2}"
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func mapProtocolError(_ error: CodexProtocolError) -> UsageError {
        let message = error.message.lowercased()
        if message.contains("unauthorized") || message.contains("not logged in")
            || message.contains("authentication") {
            return .unauthorized
        }
        if error.code == -32601 || message.contains("method not found") {
            return .badResponse("Codex does not support usage limits; update Codex and try again")
        }
        if error.code == -32001 || message.contains("overloaded") {
            return .network("Codex app server is overloaded")
        }
        return .badResponse("Codex app server error \(error.code): \(error.message)")
    }

    private func transportMessage(_ error: CodexTransportError) -> String {
        switch error {
        case .launch(let message): return "Codex app server could not start: \(message)"
        case .timeout: return "Codex app server timed out"
        case .prematureEOF(let message): return "Codex app server closed early: \(message)"
        }
    }
}
