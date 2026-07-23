import Foundation

public protocol CodexExecutableResolving {
    func resolve() -> CodexExecutable?
}

public protocol CodexAppServerTransport {
    func exchange(executable: CodexExecutable,
                  input: Data,
                  responseIDs: Set<Int>,
                  timeout: TimeInterval) async throws -> [Int: Data]
}

public enum CodexTransportError: Error, Equatable {
    case launch(String)
    case timeout
    case prematureEOF(String)
}

/// Finds the codex CLI.
///
/// Well-known install locations are checked first, so the common case costs nothing. Anything
/// else — nvm, fnm, volta, asdf, a custom npm prefix — is invisible to a launchd agent, so we
/// fall back to the PATH the user's own login shell reports.
public struct CodexExecutableResolver: CodexExecutableResolving {
    private let candidates: [URL]
    private let fileManager: FileManager
    private let loginShellPath: LoginShellPathProviding

    public init(candidates: [URL]? = nil,
                fileManager: FileManager = .default,
                loginShellPath: LoginShellPathProviding = LoginShellPath()) {
        self.fileManager = fileManager
        self.candidates = candidates ?? Self.defaultCandidates()
        self.loginShellPath = loginShellPath
    }

    public func resolve() -> CodexExecutable? {
        if let url = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return CodexExecutable(url: url, searchPath: searchPath(alongside: url))
        }
        guard let path = loginShellPath.loginShellPath(),
              let url = firstExecutable(named: "codex", on: path) else { return nil }
        return CodexExecutable(url: url, searchPath: path)
    }

    /// An npm-installed codex is a `#!/usr/bin/env node` script, and its `node` sits in the same
    /// directory, so that directory has to be on the child's PATH for the script to launch.
    private func searchPath(alongside url: URL) -> String {
        let directory = url.deletingLastPathComponent().path
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return inherited.isEmpty ? directory : "\(directory):\(inherited)"
    }

    private func firstExecutable(named name: String, on path: String) -> URL? {
        for directory in path.split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static func defaultCandidates(home: URL) -> [URL] {
        return [
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            home.appendingPathComponent(".local/bin/codex")
        ]
    }

    private static func defaultCandidates() -> [URL] {
        defaultCandidates(home: FileManager.default.homeDirectoryForCurrentUser)
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
            let responses = try await transport.exchange(executable: executable,
                                                         input: requestData(),
                                                         responseIDs: [2, 3, 4],
                                                         timeout: timeout)
            guard let data = responses[2] else {
                throw CodexResponseError.missingResult
            }
            let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
            let modelName = activeModelDisplayName(from: responses)
            return .success(try response.toUsage(now: now(),
                                                 unnamedCodexModelName: modelName))
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

    private func activeModelDisplayName(from responses: [Int: Data]) -> String? {
        let decoder = JSONDecoder()
        guard let configData = responses[3],
              let modelData = responses[4],
              let config = try? decoder.decode(CodexConfigResponse.self, from: configData),
              let modelID = config.activeModelID,
              let models = try? decoder.decode(CodexModelListResponse.self, from: modelData)
        else { return nil }
        return models.displayName(for: modelID)
    }

    private func requestData() -> Data {
        let encodedVersion = (try? JSONEncoder().encode(appVersion))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"development\""
        let lines = [
            "{\"method\":\"initialize\",\"id\":1,\"params\":{\"clientInfo\":{\"name\":\"cc_meter\",\"title\":\"cc-meter\",\"version\":\(encodedVersion)}}}",
            "{\"method\":\"initialized\"}",
            "{\"method\":\"account/rateLimits/read\",\"id\":2}",
            "{\"method\":\"config/read\",\"id\":3,\"params\":{}}",
            "{\"method\":\"model/list\",\"id\":4,\"params\":{}}"
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
