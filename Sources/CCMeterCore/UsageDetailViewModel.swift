import Foundation
import Combine

/// Backs the popover's Usage tab: holds the selected provider and window, reads the event store,
/// and publishes a `UsageBreakdown`. The window is bounded by the live reset time so its totals
/// reconcile with the percentages the Limits tab shows. `indexerTick` is a synchronous closure
/// (just `indexer.tick()`); this view-model owns hopping it off the main thread, because indexing
/// enumerates thousands of log files and must never stall the UI (the #16 lesson).
@MainActor
public final class UsageDetailViewModel: ObservableObject {
    @Published public var provider: UsageProvider { didSet { recompute() } }
    @Published public var window: UsageWindow { didSet { recompute() } }
    @Published public private(set) var breakdown: UsageBreakdown?
    /// False until the first index pass finishes, so the tab can show a progress state on first launch.
    @Published public private(set) var hasIndexed = false

    private let store: UsageEventStoring
    private let resetsAt: (UsageProvider, UsageWindow) -> Date?
    private let indexerTick: () -> Void
    private let logsPresentFor: (UsageProvider) -> Bool
    private let now: () -> Date
    private static let work = DispatchQueue(label: "cc-meter.usage-indexer.tick", qos: .utility)

    public init(store: UsageEventStoring,
                resetsAt: @escaping (UsageProvider, UsageWindow) -> Date?,
                indexerTick: @escaping () -> Void,
                logsPresent: @escaping (UsageProvider) -> Bool = { _ in true },
                now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.resetsAt = resetsAt
        self.indexerTick = indexerTick
        self.logsPresentFor = logsPresent
        self.now = now
        self.provider = .claude
        self.window = .fiveHour
        recompute()
    }

    public func logsPresent(_ provider: UsageProvider) -> Bool { logsPresentFor(provider) }

    public func recompute() {
        let clock = now()
        let start = resetsAt(provider, window).map { $0.addingTimeInterval(-window.length) }
            ?? clock.addingTimeInterval(-window.length)
        let events = store.events(since: start)
        breakdown = UsageBreakdownBuilder.build(events: events, provider: provider,
                                                window: window, windowStart: start, now: clock)
    }

    /// Shows current data immediately, then indexes off the main thread and recomputes when done.
    public func refreshInBackground() {
        recompute()
        Self.work.async { [weak self] in
            self?.indexerTick()
            Task { @MainActor in
                self?.hasIndexed = true
                self?.recompute()
            }
        }
    }

    public func onAppear() { refreshInBackground() }
}
