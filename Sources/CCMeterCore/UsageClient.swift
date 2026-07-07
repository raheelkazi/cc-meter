import Foundation

public struct HTTPResponse {
    public let status: Int
    public let data: Data
    public let headers: [String: String]

    public init(status: Int, data: Data, headers: [String: String] = [:]) {
        self.status = status
        self.data = data
        self.headers = headers
    }

    /// Header lookup ignoring case, since proxies re-case header names freely.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol Transport {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: Transport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            headers["\(key)"] = "\(value)"
        }
        return HTTPResponse(status: http?.statusCode ?? 0, data: data, headers: headers)
    }
}

public protocol UsageFetching {
    func fetch() async -> Result<Usage, UsageError>
}

public struct UsageClient: UsageFetching {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    let tokenProvider: TokenProviding
    let transport: Transport
    let now: () -> Date

    public init(tokenProvider: TokenProviding, transport: Transport, now: @escaping () -> Date) {
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.now = now
    }

    public func fetch() async -> Result<Usage, UsageError> {
        let token: String
        do { token = try tokenProvider.currentToken() }
        catch { return .failure(.noCredentials) }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let response: HTTPResponse
        do { response = try await transport.send(request) }
        catch { return .failure(.network(error.localizedDescription)) }

        switch response.status {
        case 200:
            do {
                let wire = try JSONDecoder().decode(UsageResponse.self, from: response.data)
                return .success(wire.toUsage(now: now()))
            } catch {
                // A decode failure means the response shape changed - deterministic,
                // not a transient blip - so surface it rather than keep stale data.
                return .failure(.badResponse("decode failed: \(error)"))
            }
        case 401, 403: return .failure(.unauthorized)
        case 429:
            // Retry-After can also be an HTTP-date; we only honor the
            // delta-seconds form and let the caller fall back otherwise.
            let retryAfter = response.header("Retry-After").flatMap(TimeInterval.init)
            return .failure(.rateLimited(retryAfter: retryAfter))
        case 500...599: return .failure(.network("HTTP \(response.status)"))
        default: return .failure(.badResponse("HTTP \(response.status)"))
        }
    }
}
