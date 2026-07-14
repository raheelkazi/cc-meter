import XCTest
@testable import CCMeterCore

private final class StubClient: UsageFetching {
    var result: Result<Usage, UsageError>
    private(set) var fetchCount = 0
    init(_ result: Result<Usage, UsageError>) { self.result = result }
    func fetch() async -> Result<Usage, UsageError> {
        fetchCount += 1
        return result
    }
}

private final class StubStore: UsageStoring {
    var saved: SavedUsage?
    init(_ saved: SavedUsage? = nil) { self.saved = saved }
    func save(_ saved: SavedUsage) { self.saved = saved }
    func load() -> SavedUsage? { saved }
}

private final class SpyNotifier: Notifying {
    var events: [NotificationEvent] = []
    func post(_ event: NotificationEvent) { events.append(event) }
}

@MainActor
final class MeterViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func sampleUsage() -> Usage {
        let week: TimeInterval = 7 * 24 * 3600
        return Usage(limits: [
            UsageLimit(kind: .session, percent: 3,
                       resetsAt: now.addingTimeInterval(3600), isActive: false),
            UsageLimit(kind: .weeklyAll, percent: 37,
                       resetsAt: now.addingTimeInterval(week / 2), isActive: false),
            UsageLimit(kind: .weeklyScoped(model: "Fable"), percent: 54,
                       resetsAt: now.addingTimeInterval(week / 2), isActive: true)
        ], fetchedAt: now)
    }

    func testRefreshSetsOkAndBuildsRows() async {
        let vm = MeterViewModel(client: StubClient(.success(sampleUsage())),
                                interval: 30, now: { self.now })
        await vm.refresh()
        guard case .ok = vm.state else { return XCTFail("expected ok") }
        XCTAssertEqual(vm.rows.count, 3)
        XCTAssertEqual(vm.rows[0].label, "5-hour")
    }

    func testCompactPicksMostConstrainedActive() async {
        let vm = MeterViewModel(client: StubClient(.success(sampleUsage())),
                                interval: 30, now: { self.now })
        await vm.refresh()
        XCTAssertEqual(vm.compact?.percent, 54)   // active Fable window
    }

    func testHeroUsesMostConstrainedActiveLimit() async {
        let vm = MeterViewModel(client: StubClient(.success(sampleUsage())),
                                interval: 30, now: { self.now })
        vm.displayMode = .remaining
        await vm.refresh()
        XCTAssertEqual(vm.hero?.label, "7-day · Fable")
        XCTAssertEqual(vm.hero?.percent, 54)       // always used percent, not remaining-mode display
        XCTAssertEqual(vm.hero?.status, "7-day · Fable is warm")
        XCTAssertEqual(vm.detailRows.map(\.label), ["5-hour", "7-day"])
        XCTAssertEqual(vm.rows.filter(\.isPromoted).map(\.label), ["7-day · Fable"])
    }

    func testRemainingModeInvertsPercent() async {
        let vm = MeterViewModel(client: StubClient(.success(sampleUsage())),
                                interval: 30, now: { self.now })
        vm.displayMode = .remaining
        await vm.refresh()
        // session used 3 -> remaining 97
        XCTAssertEqual(vm.rows[0].displayPercent, 97)
        vm.displayMode = .used
        XCTAssertEqual(vm.rows[0].displayPercent, 3)
    }

    func testHardErrorReplacesState() async {
        let vm = MeterViewModel(client: StubClient(.failure(.unauthorized)),
                                interval: 30, now: { self.now })
        await vm.refresh()
        guard case .error(.unauthorized) = vm.state else { return XCTFail("expected unauthorized") }
    }

    func testHardErrorReplacesLastKnownOk() async {
        let stub = StubClient(.success(sampleUsage()))
        let vm = MeterViewModel(client: stub, interval: 30, now: { self.now })
        await vm.refresh()                        // reach .ok
        stub.result = .failure(.unauthorized)     // hard error
        await vm.refresh()
        guard case .error(.unauthorized) = vm.state else {
            return XCTFail("expected hard error to replace last-known .ok")
        }
    }

    func testTransientErrorKeepsLastKnown() async {
        let stub = StubClient(.success(sampleUsage()))
        let vm = MeterViewModel(client: stub, interval: 30, now: { self.now })
        await vm.refresh()                       // now .ok
        stub.result = .failure(.rateLimited(retryAfter: nil))
        await vm.refresh()                       // transient -> keep .ok
        guard case .ok = vm.state else { return XCTFail("expected still ok") }
        XCTAssertEqual(vm.rows.count, 3)
        XCTAssertEqual(vm.compact?.percent, 54)
        XCTAssertEqual(vm.staleSnapshot?.title, "Using last good snapshot")
        XCTAssertTrue(vm.staleSnapshot?.detail.contains("Rate limited") ?? false)
    }

    func testStaleSnapshotClearsAfterSuccess() async {
        let stub = StubClient(.success(sampleUsage()))
        let vm = MeterViewModel(client: stub, interval: 30, now: { self.now })
        await vm.refresh()
        stub.result = .failure(.network("offline"))
        await vm.refresh()
        XCTAssertNotNil(vm.staleSnapshot)
        stub.result = .success(sampleUsage())
        await vm.refresh()
        XCTAssertNil(vm.staleSnapshot)
    }

    func testCompactFallsBackToMaxWhenNoneActive() async {
        let week: TimeInterval = 7 * 24 * 3600
        let usage = Usage(limits: [
            UsageLimit(kind: .session, percent: 12, resetsAt: now.addingTimeInterval(3600), isActive: false),
            UsageLimit(kind: .weeklyAll, percent: 40, resetsAt: now.addingTimeInterval(week / 2), isActive: false)
        ], fetchedAt: now)
        let vm = MeterViewModel(client: StubClient(.success(usage)), interval: 30, now: { self.now })
        await vm.refresh()
        XCTAssertEqual(vm.compact?.percent, 40)   // no active -> max among all
    }

    func testCompactPrefersActiveEvenWhenInactiveIsLarger() async {
        // The active-limit filter only matters when an inactive limit is the
        // global max; otherwise the test cannot tell the filter from a plain max.
        let week: TimeInterval = 7 * 24 * 3600
        let usage = Usage(limits: [
            UsageLimit(kind: .weeklyAll, percent: 80,
                       resetsAt: now.addingTimeInterval(week / 2), isActive: false),
            UsageLimit(kind: .weeklyScoped(model: "Fable"), percent: 54,
                       resetsAt: now.addingTimeInterval(week / 2), isActive: true)
        ], fetchedAt: now)
        let vm = MeterViewModel(client: StubClient(.success(usage)), interval: 30, now: { self.now })
        await vm.refresh()
        XCTAssertEqual(vm.compact?.percent, 54)   // active wins even though 80 is larger
    }

    func testDefaultDisplayModeIsUsedAndToggleFlips() async {
        let vm = MeterViewModel(client: StubClient(.success(sampleUsage())),
                                interval: 30, now: { self.now })
        XCTAssertEqual(vm.displayMode, .used)     // default pinned
        await vm.refresh()
        XCTAssertEqual(vm.rows[0].displayPercent, 3)    // used mode: session 3%
        vm.toggleMode()
        XCTAssertEqual(vm.displayMode, .remaining)
        XCTAssertEqual(vm.rows[0].displayPercent, 97)   // remaining
    }

    func testTransientErrorWhileLoadingSurfacesError() async {
        // A transient failure keeps last-known data only when we already have
        // some. From the initial .loading state it must surface, not stay stuck.
        let vm = MeterViewModel(client: StubClient(.failure(.network("offline"))),
                                interval: 30, now: { self.now })
        await vm.refresh()
        guard case .error(.network) = vm.state else {
            return XCTFail("first-fetch transient failure must surface as .error, not stay loading")
        }
    }

    func testRowColorReflectsUsedPercentInBothModes() async {
        // Color must be derived from the used percent, identical in either mode;
        // deriving it from the inverted display percent would mis-color remaining view.
        let vm = MeterViewModel(client: StubClient(.success(sampleUsage())),
                                interval: 30, now: { self.now })
        await vm.refresh()
        vm.displayMode = .used
        let usedModeColor = vm.rows[0].color
        vm.displayMode = .remaining
        XCTAssertEqual(vm.rows[0].color, usedModeColor)
    }

    func testBadResponseWhileOkReplacesState() async {
        // A decode failure / unexpected status is deterministic, not transient:
        // it must replace last-known data, not be silently kept forever.
        let stub = StubClient(.success(sampleUsage()))
        let vm = MeterViewModel(client: stub, interval: 30, now: { self.now })
        await vm.refresh()                                       // reach .ok
        stub.result = .failure(.badResponse("decode failed: x"))
        await vm.refresh()
        guard case .error(.badResponse) = vm.state else {
            return XCTFail("badResponse must replace .ok, not be kept as transient")
        }
    }

    func testLastUpdatedSetOnSuccessAndCueAvailable() async {
        let vm = MeterViewModel(client: StubClient(.success(sampleUsage())),
                                interval: 30, now: { self.now })
        XCTAssertNil(vm.lastUpdated)
        await vm.refresh()
        XCTAssertEqual(vm.lastUpdated, now)
        XCTAssertNotNil(vm.lastUpdatedText)
    }

    // MARK: Rate-limit back-off

    func testRateLimitedWhileLoadingStaysLoading() async {
        // The very first fetch hitting a 429 is not an error condition; the
        // badge should keep showing "loading", not flip to "!".
        let vm = MeterViewModel(client: StubClient(.failure(.rateLimited(retryAfter: 300))),
                                interval: 30, now: { self.now })
        await vm.refresh()
        guard case .loading = vm.state else {
            return XCTFail("429 from .loading must stay .loading, got \(vm.state)")
        }
    }

    func testRetryAfterSuppressesTimerPollsUntilElapsed() async {
        var clock = now
        let stub = StubClient(.failure(.rateLimited(retryAfter: 300)))
        let vm = MeterViewModel(client: stub, interval: 30, now: { clock })
        await vm.refresh()                       // 429 -> back off 300s
        XCTAssertEqual(stub.fetchCount, 1)

        clock = now.addingTimeInterval(60)       // inside the back-off window
        await vm.refreshIfNotBackedOff()
        XCTAssertEqual(stub.fetchCount, 1, "poll inside Retry-After must be skipped")

        clock = now.addingTimeInterval(301)      // window elapsed
        await vm.refreshIfNotBackedOff()
        XCTAssertEqual(stub.fetchCount, 2)
    }

    func testRateLimitedWithoutRetryAfterBacksOffOneInterval() async {
        var clock = now
        let stub = StubClient(.failure(.rateLimited(retryAfter: nil)))
        let vm = MeterViewModel(client: stub, interval: 30, now: { clock })
        await vm.refresh()
        clock = now.addingTimeInterval(15)       // inside the interval fallback
        await vm.refreshIfNotBackedOff()
        XCTAssertEqual(stub.fetchCount, 1)
        clock = now.addingTimeInterval(31)
        await vm.refreshIfNotBackedOff()
        XCTAssertEqual(stub.fetchCount, 2)
    }

    func testRetryAfterShorterThanIntervalIsFloored() async {
        // Never poll faster than the regular cadence just because the server's
        // back-off happens to be tiny.
        var clock = now
        let stub = StubClient(.failure(.rateLimited(retryAfter: 5)))
        let vm = MeterViewModel(client: stub, interval: 30, now: { clock })
        await vm.refresh()
        clock = now.addingTimeInterval(10)       // past retryAfter, inside interval
        await vm.refreshIfNotBackedOff()
        XCTAssertEqual(stub.fetchCount, 1)
    }

    func testManualRefreshBypassesBackoff() async {
        let stub = StubClient(.failure(.rateLimited(retryAfter: 300)))
        let vm = MeterViewModel(client: stub, interval: 30, now: { self.now })
        await vm.refresh()                       // enter back-off
        await vm.refresh()                       // explicit user refresh
        XCTAssertEqual(stub.fetchCount, 2)
    }

    func testSuccessClearsBackoff() async {
        var clock = now
        let stub = StubClient(.failure(.rateLimited(retryAfter: 300)))
        let vm = MeterViewModel(client: stub, interval: 30, now: { clock })
        await vm.refresh()                       // enter back-off
        stub.result = .success(sampleUsage())
        await vm.refresh()                       // manual refresh succeeds
        clock = now.addingTimeInterval(31)       // one interval later, still < 300s
        await vm.refreshIfNotBackedOff()
        XCTAssertEqual(stub.fetchCount, 3, "success must clear the back-off window")
    }

    // MARK: Persisted last-good usage

    func testLoadCachedUsageSeedsStateAndTimestamp() {
        let savedAt = now.addingTimeInterval(-120)
        let store = StubStore(SavedUsage(usage: sampleUsage(), savedAt: savedAt))
        let vm = MeterViewModel(client: StubClient(.failure(.rateLimited(retryAfter: nil))),
                                interval: 30, store: store, now: { self.now })
        vm.loadCachedUsage()
        guard case .ok = vm.state else { return XCTFail("expected cached .ok") }
        XCTAssertEqual(vm.lastUpdated, savedAt)   // "updated 2m ago", not "just now"
    }

    func testStaleCacheIsIgnored() {
        let store = StubStore(SavedUsage(usage: sampleUsage(),
                                         savedAt: now.addingTimeInterval(-25 * 3600)))
        let vm = MeterViewModel(client: StubClient(.failure(.rateLimited(retryAfter: nil))),
                                interval: 30, store: store, now: { self.now })
        vm.loadCachedUsage()
        guard case .loading = vm.state else {
            return XCTFail("cache older than cacheMaxAge must not seed the display")
        }
    }

    func testCacheDoesNotOverwriteFreshFetch() async {
        let store = StubStore(SavedUsage(usage: sampleUsage(), savedAt: now))
        let vm = MeterViewModel(client: StubClient(.failure(.unauthorized)),
                                interval: 30, store: store, now: { self.now })
        await vm.refresh()                        // real result arrived first
        vm.loadCachedUsage()
        guard case .error(.unauthorized) = vm.state else {
            return XCTFail("cache must only seed the initial .loading state")
        }
    }

    func testSuccessfulFetchPersistsToStore() async {
        let store = StubStore()
        let vm = MeterViewModel(client: StubClient(.success(sampleUsage())),
                                interval: 30, store: store, now: { self.now })
        await vm.refresh()
        XCTAssertEqual(store.saved, SavedUsage(usage: sampleUsage(), savedAt: now))
    }

    // MARK: - History, burn, spend, notifications

    func testHistoryRecordedOnSuccessfulRefresh() async {
        let history = InMemoryHistoryStore(now: { self.now })
        let vm = MeterViewModel(client: StubClient(.success(sampleUsage())),
                                history: history, now: { self.now })
        await vm.refresh()
        let samples = history.recent(kindLabel: "5-hour", since: now.addingTimeInterval(-1))
        XCTAssertEqual(samples.map(\.percent), [3])
    }

    func testHistoryNotRecordedWhenDisabled() async {
        let history = InMemoryHistoryStore(now: { self.now })
        let vm = MeterViewModel(client: StubClient(.success(sampleUsage())),
                                preferences: Preferences(historyEnabled: false),
                                history: history, now: { self.now })
        await vm.refresh()
        XCTAssertTrue(history.recent(kindLabel: "5-hour", since: now.addingTimeInterval(-10_000)).isEmpty)
    }

    func testRowsSurfaceBurnProjectionFromHistory() async {
        // Pre-seed a rising session trend over the last hour.
        let samples = stride(from: 0, through: 60, by: 15).map {
            HistorySample(kindLabel: "5-hour", percent: 40 + Double($0) / 3,
                          at: now.addingTimeInterval(Double($0 - 60) * 60))
        }
        let history = InMemoryHistoryStore(samples: samples, now: { self.now })
        let usage = Usage(limits: [
            UsageLimit(kind: .session, percent: 60,
                       resetsAt: now.addingTimeInterval(10 * 3600), isActive: true)
        ], fetchedAt: now)
        let vm = MeterViewModel(client: StubClient(.success(usage)),
                                history: history, now: { self.now })
        await vm.refresh()
        XCTAssertNotNil(vm.rows.first?.burn)
        XCTAssertEqual(vm.rows.first?.forecast?.rateText, "+20%/h burn")
        XCTAssertEqual(vm.rows.first?.forecast?.limitText, "Limit in 2h 0m")
        XCTAssertEqual(vm.rows.first?.forecast?.detailText, "+20%/h now vs +4.0%/h safe")
        XCTAssertTrue(vm.rows.first?.forecast?.isUrgent ?? false)
    }

    func testBurnForecastIgnoresPriorWindowSamples() async {
        // A steep rising trend, but all in the *previous* window (different reset).
        let oldReset = now.addingTimeInterval(-60)
        let priorWindow = stride(from: 0, through: 60, by: 15).map {
            HistorySample(kindLabel: "5-hour", percent: 40 + Double($0),
                          at: now.addingTimeInterval(Double($0 - 120) * 60),
                          windowResetsAt: oldReset)
        }
        let history = InMemoryHistoryStore(samples: priorWindow, now: { self.now })
        // Fresh window: reset moved forward, usage dropped to ~2%.
        let usage = Usage(limits: [
            UsageLimit(kind: .session, percent: 2,
                       resetsAt: now.addingTimeInterval(5 * 3600), isActive: true)
        ], fetchedAt: now)
        let vm = MeterViewModel(client: StubClient(.success(usage)),
                                history: history, now: { self.now })
        await vm.refresh()
        // Only the single new-window sample counts: no false projection from the
        // old steep climb.
        XCTAssertNil(vm.rows.first?.burn)
        XCTAssertNil(vm.rows.first?.forecast)
    }

    func testBurnForecastToleratesPriorSampleResetJitter() async {
        // Same window, but every fetch recorded a slightly different resets_at
        // (the endpoint jitters it sub-second). All samples must still count:
        // exact-equality matching wrongly dropped all but the latest, killing
        // the burn projection.
        let baseReset = now.addingTimeInterval(5 * 3600)
        let samples = Array(stride(from: 0, through: 60, by: 15)).enumerated().map { index, minute in
            HistorySample(kindLabel: "5-hour",
                          percent: 40 + Double(minute) / 3,
                          at: now.addingTimeInterval(Double(minute - 60) * 60),
                          windowResetsAt: baseReset.addingTimeInterval(Double(index) * 0.2))
        }
        let history = InMemoryHistoryStore(samples: samples, now: { self.now })
        let usage = Usage(limits: [
            UsageLimit(kind: .session, percent: 60,
                       resetsAt: baseReset.addingTimeInterval(0.9), isActive: true)
        ], fetchedAt: now)
        let vm = MeterViewModel(client: StubClient(.success(usage)),
                                history: history, now: { self.now })
        await vm.refresh()
        XCTAssertEqual(vm.rows.first?.forecast?.rateText, "+20%/h burn")
        XCTAssertNotNil(vm.rows.first?.forecast)
    }

    func testApplyFlipsDisplayModeWhenDefaultChanges() {
        let vm = MeterViewModel(client: StubClient(.success(sampleUsage())), now: { self.now })
        XCTAssertEqual(vm.displayMode, .used)
        vm.apply(Preferences(defaultShowRemaining: true))
        XCTAssertEqual(vm.displayMode, .remaining)
        vm.apply(Preferences(defaultShowRemaining: false))
        XCTAssertEqual(vm.displayMode, .used)
    }

    func testApplyDoesNotStompManualToggleWhenDefaultUnchanged() {
        let vm = MeterViewModel(client: StubClient(.success(sampleUsage())), now: { self.now })
        vm.toggleMode()
        XCTAssertEqual(vm.displayMode, .remaining)
        // Unrelated edit; defaultShowRemaining still false, so don't override.
        vm.apply(Preferences(pollInterval: 200))
        XCTAssertEqual(vm.displayMode, .remaining)
    }

    func testSpendExposedFromState() async {
        let usage = Usage(limits: [], spend: Spend(amount: 3.2, limit: 10, currency: "USD"), fetchedAt: now)
        let vm = MeterViewModel(client: StubClient(.success(usage)), now: { self.now })
        XCTAssertNil(vm.spend)
        await vm.refresh()
        XCTAssertEqual(vm.spend?.amount, 3.2)
    }

    func testDefaultShowRemainingSetsInitialDisplayMode() {
        let vm = MeterViewModel(client: StubClient(.success(sampleUsage())),
                                preferences: Preferences(defaultShowRemaining: true),
                                now: { self.now })
        XCTAssertEqual(vm.displayMode, .remaining)
    }

    func testNotificationsDispatchedToSinkOnThresholdCross() async {
        let sink = SpyNotifier()
        let stub = StubClient(.success(sessionUsage(50)))
        let vm = MeterViewModel(client: stub,
                                notifier: ThresholdNotifier(),
                                notificationSink: sink,
                                now: { self.now })
        await vm.refresh()                    // baseline at 50%, no events
        XCTAssertTrue(sink.events.isEmpty)
        stub.result = .success(sessionUsage(82))
        await vm.refresh()                    // crosses 80%
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertTrue(sink.events[0].id.contains("80"))
    }

    private func sessionUsage(_ percent: Double) -> Usage {
        Usage(limits: [UsageLimit(kind: .session, percent: percent,
                                  resetsAt: now.addingTimeInterval(3600), isActive: true)],
              fetchedAt: now)
    }
}
