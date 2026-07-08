import Foundation
import Combine

public enum MeterState {
    case loading
    case ok(Usage)
    case error(UsageError)
}

public enum DisplayMode { case used, remaining }

public struct BurnForecast: Equatable {
    public let rateText: String
    public let limitText: String
    public let detailText: String
    public let isUrgent: Bool
}

public struct MeterHero: Equatable {
    public let label: String
    public let percent: Int
    public let fraction: Double
    public let color: MeterColor
    public let status: String
    public let countdown: String
    public let burn: String?
    public let burnUrgent: Bool
    public let forecast: BurnForecast?
}

public struct StaleSnapshot: Equatable {
    public let title: String
    public let detail: String
}

public struct MeterRow: Identifiable {
    public let id: String
    public let label: String
    public let isPromoted: Bool
    public let displayPercent: Int
    public let barFraction: Double
    public let color: MeterColor
    public let countdown: String
    /// Time-to-exhaustion projection, e.g. "~40m to limit", or nil when the pace
    /// is flat/insufficient to project.
    public let burn: String?
    /// True when the projection exhausts the window before it resets (worth emphasis).
    public let burnUrgent: Bool
    /// Current burn rate and projected exhaustion/reset outcome.
    public let forecast: BurnForecast?
}

@MainActor
public final class MeterViewModel: ObservableObject {
    @Published public private(set) var state: MeterState = .loading
    @Published public var displayMode: DisplayMode = .used
    /// Time of the last successful fetch, backing the "updated ..." staleness cue.
    @Published public private(set) var lastUpdated: Date?
    /// Transient failure state shown while the UI keeps rendering last-known data.
    @Published public private(set) var staleSnapshot: StaleSnapshot?

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
    /// Guards against overlapping fetches. Two refreshes racing (a timer tick and
    /// a manual Refresh, say) could each hit the 401 path and fire concurrent
    /// token refreshes with the same refresh token, invalidating the grant and
    /// leaving the Keychain in a bad state. `@MainActor` makes this flag a safe
    /// mutex across the awaits inside `refresh()`.
    private var isFetching = false

    /// Window of history used to estimate burn rate; long enough to smooth a poll
    /// or two of noise, short enough to react to a fresh spike.
    private let burnWindow: TimeInterval = 2 * 3600
    /// Two samples belong to the same limit window when their reset times are
    /// within this tolerance. The endpoint's `resets_at` jitters by up to ~1s
    /// between fetches, so exact equality wrongly split every poll into its own
    /// "window" (killing burn forecasts). A real reset moves `resets_at` by the
    /// whole window (>=5h), so a generous minutes-scale tolerance is unambiguous.
    private let windowMatchTolerance: TimeInterval = 600

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
        // Coalesce concurrent refreshes; a fetch already in flight will publish
        // fresh data for everyone, so a second overlapping call is redundant and
        // unsafe (see `isFetching`).
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        let result = await client.fetch()
        switch result {
        case .success(let usage):
            state = .ok(usage)
            lastUpdated = now()
            backoffUntil = nil
            staleSnapshot = nil
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
                staleSnapshot = makeStaleSnapshot(for: error)
                break   // Keep last-known data on transient errors.
            case (.loading, .rateLimited):
                break   // Still waiting for a first result; not an error condition.
            default:
                staleSnapshot = nil
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
    /// the timer if it changed) and the display default. Threshold/history changes
    /// take effect on the next fetch.
    public func apply(_ preferences: Preferences) {
        let normalized = preferences.normalized()
        let intervalChanged = normalized.pollInterval != self.interval
        // Flip the live display only when the default actually changes, so an
        // unrelated settings edit doesn't stomp a manual Used/Left toggle.
        let showRemainingChanged =
            normalized.defaultShowRemaining != self.preferences.defaultShowRemaining
        self.preferences = normalized
        self.interval = normalized.pollInterval
        if intervalChanged, timer != nil { scheduleTimer() }
        if showRemainingChanged {
            displayMode = normalized.defaultShowRemaining ? .remaining : .used
        }
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

    private func makeStaleSnapshot(for error: UsageError) -> StaleSnapshot {
        let age = lastUpdatedText.map { "Last successful fetch \($0)." } ?? "Showing the last successful fetch."
        switch error {
        case .rateLimited:
            let retry = backoffUntil.map { " Next automatic retry in \(Self.durationText(to: $0, now: now()))." } ?? ""
            return StaleSnapshot(title: "Using last good snapshot", detail: "Rate limited. \(age)\(retry)")
        case .network(let message):
            return StaleSnapshot(title: "Using last good snapshot", detail: "Network error. \(age) \(message)")
        case .noCredentials, .unauthorized, .badResponse:
            return StaleSnapshot(title: "Using last good snapshot", detail: age)
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
        guard let top = mostConstrainedLimit() else { return nil }
        return summarize(top)
    }

    public var hero: MeterHero? {
        guard let top = mostConstrainedLimit() else { return nil }
        let clock = now()
        let used = summarize(top)
        let samples = currentWindowSamples(for: top, label: top.kind.label)
        let projection = burnProjection(samples: samples.filter { $0.at >= clock.addingTimeInterval(-burnWindow) },
                                        currentPercent: top.percent,
                                        resetsAt: top.resetsAt,
                                        now: clock)
        return MeterHero(label: top.kind.label,
                         percent: used.percent,
                         fraction: min(1, max(0, top.percent / 100.0)),
                         color: used.color,
                         status: heroStatus(label: top.kind.label,
                                            color: used.color,
                                            burnUrgent: projection?.willExhaustBeforeReset ?? false),
                         countdown: countdownText(to: top.resetsAt, now: clock),
                         burn: projection.map(burnText),
                         burnUrgent: projection?.willExhaustBeforeReset ?? false,
                         forecast: projection.flatMap {
                             burnForecast(projection: $0,
                                          currentPercent: top.percent,
                                          resetsAt: top.resetsAt,
                                          now: clock)
                         })
    }

    private func mostConstrainedLimit() -> UsageLimit? {
        guard case .ok(let usage) = state else { return nil }
        return mostConstrainedIndexedLimit(in: usage)?.limit
    }

    private func mostConstrainedIndexedLimit(in usage: Usage) -> (index: Int, limit: UsageLimit)? {
        let indexed = usage.limits.enumerated().map { (index: $0.offset, limit: $0.element) }
        let active = indexed.filter { $0.limit.isActive }
        let pool = active.isEmpty ? indexed : active
        return pool.max(by: { $0.limit.percent < $1.limit.percent })
    }

    public var detailRows: [MeterRow] {
        rows.filter { !$0.isPromoted }
    }

    private func heroStatus(label: String, color: MeterColor, burnUrgent: Bool) -> String {
        if burnUrgent { return "\(label) may run out early" }
        switch color {
        case .green: return "\(label) has room"
        case .amber: return "\(label) is warm"
        case .red: return "\(label) is nearly full"
        }
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
        let promotedIndex = mostConstrainedIndexedLimit(in: usage)?.index
        return usage.limits.enumerated().map { index, limit in
            let used = summarize(limit)
            let displayPercent = mode == .used ? used.percent : (100 - used.percent)
            let label = limit.kind.label
            let windowSamples = currentWindowSamples(for: limit, label: label)
            let burnSamples = windowSamples.filter { $0.at >= clock.addingTimeInterval(-burnWindow) }
            let projection = burnProjection(samples: burnSamples,
                                            currentPercent: limit.percent,
                                            resetsAt: limit.resetsAt,
                                            now: clock)

            // Index-prefixed id stays unique even if two windows share a label.
            return MeterRow(id: "\(index)-\(label)",
                            label: label,
                            isPromoted: index == promotedIndex,
                            displayPercent: displayPercent,
                            barFraction: Double(displayPercent) / 100.0,
                            color: used.color,
                            countdown: countdownText(to: limit.resetsAt, now: clock),
                            burn: projection.map(burnText),
                            burnUrgent: projection?.willExhaustBeforeReset ?? false,
                            forecast: projection.flatMap {
                                burnForecast(projection: $0,
                                             currentPercent: limit.percent,
                                             resetsAt: limit.resetsAt,
                                             now: clock)
                            })
        }
    }

    private func currentWindowSamples(for limit: UsageLimit, label: String) -> [HistorySample] {
        // Only consider samples from the current window: after a reset the old
        // window's percentages must not pollute the burn rate or the trend.
        // Match by tolerance rather than exact equality because `resets_at`
        // jitters sub-second between fetches. (Legacy samples without a
        // recorded window are treated as matching.)
        (history?.recent(kindLabel: label, since: .distantPast) ?? [])
            .filter { sample in
                guard let windowResetsAt = sample.windowResetsAt else { return true }
                return abs(windowResetsAt.timeIntervalSince(limit.resetsAt)) < windowMatchTolerance
            }
    }

    private func burnForecast(projection: BurnProjection,
                              currentPercent: Double,
                              resetsAt: Date,
                              now: Date) -> BurnForecast? {
        let hoursUntilReset = resetsAt.timeIntervalSince(now) / 3600.0
        guard hoursUntilReset > 0 else { return nil }
        let safeRate = max(0, (100 - currentPercent) / hoursUntilReset)
        let limitText = projection.willExhaustBeforeReset
            ? "Limit in \(Self.durationText(projection.timeToLimit))"
            : "Reset comes first"
        return BurnForecast(rateText: "\(Self.rateText(projection.ratePerHour)) burn",
                            limitText: limitText,
                            detailText: "\(Self.rateText(projection.ratePerHour)) now vs \(Self.rateText(safeRate)) safe",
                            isUrgent: projection.willExhaustBeforeReset)
    }

    private static func rateText(_ rate: Double) -> String {
        if rate >= 10 {
            return "+\(Int(rate.rounded()))%/h"
        }
        return String(format: "+%.1f%%/h", rate)
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let secs = max(0, Int(seconds))
        let days = secs / 86400
        let hours = (secs % 86400) / 3600
        let mins = (secs % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(max(1, mins))m"
    }

    private static func durationText(to date: Date, now: Date) -> String {
        let secs = max(0, Int(date.timeIntervalSince(now)))
        let hours = secs / 3600
        let mins = (secs % 3600) / 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(max(1, mins))m"
    }
}
