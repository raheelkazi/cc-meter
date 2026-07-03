import Foundation
import Combine

public enum MeterState {
    case loading
    case ok(Usage)
    case error(UsageError)
}

public enum DisplayMode { case used, remaining }

public struct MeterRow: Identifiable {
    public let id: String
    public let label: String
    public let displayPercent: Int
    public let barFraction: Double
    public let color: MeterColor
    public let countdown: String
}

@MainActor
public final class MeterViewModel: ObservableObject {
    @Published public private(set) var state: MeterState = .loading
    @Published public var displayMode: DisplayMode = .remaining
    @Published public private(set) var lastUpdated: Date?

    private let client: UsageFetching
    private let interval: TimeInterval
    private let now: () -> Date
    private var timer: Timer?

    public init(client: UsageFetching,
                interval: TimeInterval = 30,
                now: @escaping () -> Date = { Date() }) {
        self.client = client
        self.interval = interval
        self.now = now
    }

    /// Kicks off an immediate fetch and schedules periodic refreshes.
    public func start() {
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // The Timer callback is nonisolated; hop to the main actor before
            // touching this main-actor-isolated view model.
            Task { @MainActor in self?.refreshNow() }
        }
    }

    public func refreshNow() {
        Task { @MainActor in await self.refresh() }
    }

    public func refresh() async {
        let result = await client.fetch()
        switch result {
        case .success(let usage):
            state = .ok(usage)
            lastUpdated = now()
        case .failure(let error):
            if case .ok = state, isTransient(error) {
                // Keep last-known data on transient errors; do not disrupt display.
            } else {
                state = .error(error)
            }
        }
    }

    public func toggleMode() {
        displayMode = (displayMode == .used) ? .remaining : .used
    }

    private func isTransient(_ error: UsageError) -> Bool {
        switch error {
        case .rateLimited, .network: return true
        case .noCredentials, .unauthorized: return false
        }
    }

    public var compact: (percent: Int, color: MeterColor)? {
        guard case .ok(let usage) = state else { return nil }
        let active = usage.limits.filter { $0.isActive }
        let pool = active.isEmpty ? usage.limits : active
        guard let top = pool.max(by: { $0.percent < $1.percent }) else { return nil }
        let color = burnRateColor(percent: top.percent, resetsAt: top.resetsAt,
                                  windowLength: top.kind.length, now: now())
        return (Int(top.percent.rounded()), color)
    }

    public var rows: [MeterRow] {
        guard case .ok(let usage) = state else { return [] }
        let mode = displayMode
        let clock = now()
        return usage.limits.map { limit in
            let usedPct = Int(limit.percent.rounded())
            let displayPercent = mode == .used ? usedPct : (100 - usedPct)
            let color = burnRateColor(percent: limit.percent, resetsAt: limit.resetsAt,
                                      windowLength: limit.kind.length, now: clock)
            return MeterRow(id: limit.kind.label,
                            label: limit.kind.label,
                            displayPercent: displayPercent,
                            barFraction: Double(displayPercent) / 100.0,
                            color: color,
                            countdown: countdownText(to: limit.resetsAt, now: clock))
        }
    }
}
