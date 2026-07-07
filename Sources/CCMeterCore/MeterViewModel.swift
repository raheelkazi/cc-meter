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
    /// Time-to-exhaustion projection, e.g. "~40m to limit", or nil when the pace
    /// is flat/insufficient to project.
    public let burn: String?
    /// True when the projection exhausts the window before it resets (worth emphasis).
    public let burnUrgent: Bool
    /// Recent used-percent samples for a trend sparkline (empty when no history).
    public let series: [Double]
}

@MainActor
public final class MeterViewModel: ObservableObject {
    @Published public private(set) var state: MeterState = .loading
    @Published public var displayMode: DisplayMode = .used
    /// Time of the last successful fetch, backing the "updated ..." staleness cue.
    @Published public private(set) var lastUpdated: Date?

    private let client: UsageFetching
    private var interval: TimeInterval
    private let store: UsageStoring?
    private let cacheMaxAge: TimeInterval
    private let now: () -> Date
    private let history: HistoryStoring?
    private let notifier: ThresholdNotifier?
    private let notificationSink: Notifying?
    private var preferences: Preferences
    private var timer: Timer?
    /// Server-directed quiet period after a 429. Timer polls inside it are
    /// skipped: retrying early burns the shared rate budget and extends the
    /// throttle. Manual Refresh still goes through.
    private var backoffUntil: Date?

    /// Window of history used to estimate burn rate; long enough to smooth a poll
    /// or two of noise, short enough to react to a fresh spike.
    private let burnWindow: TimeInterval = 2 * 3600
    private let sparklinePoints = 24

    public init(client: UsageFetching,
                interval: TimeInterval = 60,
                store: UsageStoring? = nil,
                cacheMaxAge: TimeInterval = 24 * 3600,
                preferences: Preferences = Preferences(),
                history: HistoryStoring? = nil,
                notifier: ThresholdNotifier? = nil,
                notificationSink: Notifying? = nil,
                now: @escaping () -> Date = { Date() }) {
        self.client = client
        self.interval = interval
        self.store = store
        self.cacheMaxAge = cacheMaxAge
        self.preferences = preferences
        self.history = history
        self.notifier = notifier
        self.notificationSink = notificationSink
        self.now = now
        self.displayMode = preferences.defaultShowRemaining ? .remaining : .used
    }

    /// Kicks off an immediate fetch and schedules periodic refreshes.
    /// Seeds the display from the last persisted fetch first, so a rate-limited
    /// first fetch shows dated-but-real numbers instead of an error.
    public func start() {
        loadCachedUsage()
        refreshNow()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
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
            if preferences.historyEnabled { history?.record(usage) }
            dispatchNotifications(for: usage)
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

    /// Applies updated preferences at runtime: re-reads polling cadence (restarting
    /// the timer if it changed) and display default. Threshold/history changes take
    /// effect on the next fetch.
    public func apply(_ preferences: Preferences) {
        let normalized = preferences.normalized()
        let intervalChanged = normalized.pollInterval != self.interval
        self.preferences = normalized
        self.interval = normalized.pollInterval
        if intervalChanged, timer != nil { scheduleTimer() }
    }

    public func toggleMode() {
        displayMode = (displayMode == .used) ? .remaining : .used
    }

    private func dispatchNotifications(for usage: Usage) {
        guard let notifier, let sink = notificationSink else { return }
        for event in notifier.evaluate(usage, preferences: preferences, now: now()) {
            sink.post(event)
        }
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

    /// Spend/extra-credit info from the last successful fetch, if the endpoint
    /// reported any.
    public var spend: Spend? {
        guard case .ok(let usage) = state else { return nil }
        return usage.spend
    }

    public var rows: [MeterRow] {
        guard case .ok(let usage) = state else { return [] }
        let mode = displayMode
        let clock = now()
        return usage.limits.enumerated().map { index, limit in
            let used = summarize(limit)
            let displayPercent = mode == .used ? used.percent : (100 - used.percent)
            let label = limit.kind.label

            let samples = history?.recent(kindLabel: label, since: clock.addingTimeInterval(-burnWindow)) ?? []
            let projection = burnProjection(samples: samples,
                                            currentPercent: limit.percent,
                                            resetsAt: limit.resetsAt,
                                            now: clock)
            let series = history?.series(kindLabel: label, maxPoints: sparklinePoints) ?? []

            // Index-prefixed id stays unique even if two windows share a label.
            return MeterRow(id: "\(index)-\(label)",
                            label: label,
                            displayPercent: displayPercent,
                            barFraction: Double(displayPercent) / 100.0,
                            color: used.color,
                            countdown: countdownText(to: limit.resetsAt, now: clock),
                            burn: projection.map(burnText),
                            burnUrgent: projection?.willExhaustBeforeReset ?? false,
                            series: series)
        }
    }
}
