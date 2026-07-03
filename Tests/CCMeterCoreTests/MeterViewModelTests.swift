import XCTest
@testable import CCMeterCore

private final class StubClient: UsageFetching {
    var result: Result<Usage, UsageError>
    init(_ result: Result<Usage, UsageError>) { self.result = result }
    func fetch() async -> Result<Usage, UsageError> { result }
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
        stub.result = .failure(.rateLimited)
        await vm.refresh()                       // transient -> keep .ok
        guard case .ok = vm.state else { return XCTFail("expected still ok") }
        XCTAssertEqual(vm.rows.count, 3)
        XCTAssertEqual(vm.compact?.percent, 54)
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
}
