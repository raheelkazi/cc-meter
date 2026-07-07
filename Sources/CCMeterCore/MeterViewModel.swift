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
    @Published public var displayMode: DisplayMode = .used
    /// Time of the last successful fetch, backing the "updated ..." staleness cue.
    @Published public private(set) var lastUpdated: Date?

    private let client: UsageFetching
    private let interval: TimeInterval
    private let store: UsageStoring?
    private let cacheMaxAge: TimeInterval
    private let now: () -> Date
    private var timer: Timer?
    /// Server-directed quiet period after a 429. Timer polls inside it are
    /// skipped: retrying early burns the shared rate budget and extends the
    /// throttle. Manual Refresh still goes through.
    private var backoffUntil: Date?

    public init(client: UsageFetching,
                interval: TimeInterval = 60,
                store: UsageStoring? = nil,
                cacheMaxAge: TimeInterval = 24 * 3600,
                now: @escaping () -> Date = { Date() }) {
        self.client = client
        self.interval = interval
        self.store = store
        self.cacheMaxAge = cacheMaxAge
        self.now = now
    }

    /// Kicks off an immediate fetch and schedules periodic refreshes.
    /// Seeds the display from the last persisted fetch first, so a rate-limited
    /// first fetch shows dated-but-real numbers instead of an error.
    public func start() {
        loadCachedUsage()
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // The Timer callback is nonisolated; hop to the main actor and refresh.
            Task { @MainActor in await self?.refreshIfNotBackedOff() }
        }
    }

    public func refreshNow() {
        Task { @MainActor in await self.refresh() }
    }

    func refreshIfNotBackedOff() async {
        if let backoffUntil, now() < backoffUntil { return }
        await refresh()
    }

    public func refresh() async {
        let result = await client.fetch()
        switch result {
        case .success(let usage):
            state = .ok(usage)
            lastUpdated = now()
            backoffUntil = nil
            store?.save(SavedUsage(usage: usage, savedAt: now()))
        case .failure(let error):
            if case .rateLimited(let retryAfter) = error {
                // Honor the server's back-off, but never poll faster than the
                // regular interval either way.
                backoffUntil = now().addingTimeInterval(max(retryAfter ?? interval, interval))
            } else {
                backoffUntil = nil
            }
            switch (state, error) {
            case (.ok, _) where isTransient(error):
                break   // Keep last-known data on transient errors.
            case (.loading, .rateLimited):
                break   // Still waiting for a first result; not an error condition.
            default:
                state = .error(error)
            }
        }
    }

    func loadCachedUsage() {
        guard case .loading = state,
              let saved = store?.load(),
              now().timeIntervalSince(saved.savedAt) < cacheMaxAge else { return }
        state = .ok(saved.usage)
        lastUpdated = saved.savedAt
    }

    public func toggleMode() {
        displayMode = (displayMode == .used) ? .remaining : .used
    }

    private func isTransient(_ error: UsageError) -> Bool {
        switch error {
        case .rateLimited, .network: return true
        case .noCredentials, .unauthorized, .badResponse: return false
        }
    }

    /// Human "updated ..." cue for the last successful fetch, so kept-stale data
    /// (shown after a transient failure) is visibly dated rather than silently old.
    public var lastUpdatedText: String? {
        guard let lastUpdated else { return nil }
        let secs = Int(now().timeIntervalSince(lastUpdated))
        if secs < 10 { return "updated just now" }
        if secs < 60 { return "updated \(secs)s ago" }
        let mins = secs / 60
        if mins < 60 { return "updated \(mins)m ago" }
        return "updated \(mins / 60)h ago"
    }

    /// Rounds a limit's used percent and colors it by usage level. Shared by the
    /// menu-bar badge (compact) and the popover rows so the mapping lives once.
    private func summarize(_ limit: UsageLimit) -> (percent: Int, color: MeterColor) {
        let color = usageColor(percent: limit.percent)
        return (Int(limit.percent.rounded()), color)
    }

    public var compact: (percent: Int, color: MeterColor)? {
        guard case .ok(let usage) = state else { return nil }
        let active = usage.limits.filter { $0.isActive }
        let pool = active.isEmpty ? usage.limits : active
        guard let top = pool.max(by: { $0.percent < $1.percent }) else { return nil }
        return summarize(top)
    }

    public var rows: [MeterRow] {
        guard case .ok(let usage) = state else { return [] }
        let mode = displayMode
        let clock = now()
        return usage.limits.enumerated().map { index, limit in
            let used = summarize(limit)
            let displayPercent = mode == .used ? used.percent : (100 - used.percent)
            // Index-prefixed id stays unique even if two windows share a label.
            return MeterRow(id: "\(index)-\(limit.kind.label)",
                            label: limit.kind.label,
                            displayPercent: displayPercent,
                            barFraction: Double(displayPercent) / 100.0,
                            color: used.color,
                            countdown: countdownText(to: limit.resetsAt, now: clock))
        }
    }
}
