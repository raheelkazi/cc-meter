import Foundation
import Combine

/// Polls each provider's status on a slow timer and publishes the latest per-provider status.
/// A failed fetch keeps the last-known status - it never clears a known outage or invents one.
@MainActor
public final class StatusMonitor: ObservableObject {
    @Published public private(set) var statuses: [UsageProvider: ProviderStatus] = [:]

    private let client: StatusFetching
    private let providers: [UsageProvider]
    private let interval: TimeInterval
    private let now: () -> Date
    private var timer: Timer?

    public init(client: StatusFetching,
                providers: [UsageProvider] = [.claude, .codex],
                interval: TimeInterval = 300,
                now: @escaping () -> Date = { Date() }) {
        self.client = client
        self.providers = providers
        self.interval = interval
        self.now = now
    }

    public func start() {
        Task { @MainActor in await self.refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    public func refresh() async {
        for provider in providers {
            if let status = await client.fetch(provider) {
                statuses[provider] = status
            }
            // nil -> keep last-known; never clear or fabricate.
        }
    }

    public func status(for provider: UsageProvider) -> ProviderStatus? { statuses[provider] }
    public func level(for provider: UsageProvider) -> StatusLevel { statuses[provider]?.level ?? .ok }

    deinit { timer?.invalidate() }
}
