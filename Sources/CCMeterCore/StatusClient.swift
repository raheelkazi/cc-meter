import Foundation

public protocol StatusFetching {
    /// Current status for a provider, or nil on any fetch/parse failure (never a fabricated outage).
    func fetch(_ provider: UsageProvider) async -> ProviderStatus?
}

/// Fetches a provider's Statuspage `summary.json` over the shared `Transport` and evaluates it.
public struct HTTPStatusClient: StatusFetching {
    private let transport: Transport
    public init(transport: Transport) { self.transport = transport }

    public static func statusURL(for provider: UsageProvider) -> URL {
        switch provider {
        case .claude: return URL(string: "https://status.claude.com/api/v2/summary.json")!
        case .codex: return URL(string: "https://status.openai.com/api/v2/summary.json")!
        }
    }

    public func fetch(_ provider: UsageProvider) async -> ProviderStatus? {
        let url = Self.statusURL(for: provider)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: HTTPResponse
        do { response = try await transport.send(request) } catch { return nil }
        guard response.status == 200 else { return nil }
        guard let summary = try? JSONDecoder().decode(StatusSummary.self, from: response.data) else { return nil }
        return ProviderStatusEvaluator.evaluate(summary, provider: provider, statusURL: URL(string: "https://\(url.host ?? "")")!)
    }
}
