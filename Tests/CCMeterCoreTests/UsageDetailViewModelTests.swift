import XCTest
@testable import CCMeterCore

@MainActor
final class UsageDetailViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 5_000_000)

    private func event(_ provider: UsageProvider, project: String, input: Int, at: Date) -> UsageEvent {
        UsageEvent(provider: provider, at: at, project: project, model: "claude-opus-4-8",
                   tokens: TokenCounts(input: input), dedupKey: "\(project)-\(at.timeIntervalSince1970)")
    }

    func testBreakdownUsesResetsAtToBoundTheWindow() {
        let resets = now.addingTimeInterval(3600)            // 5h window started now-4h
        let store = InMemoryUsageEventStore(events: [
            event(.claude, project: "cc-meter", input: 40, at: now.addingTimeInterval(-3600)),   // in window
            event(.claude, project: "cc-meter", input: 99, at: now.addingTimeInterval(-5*3600)), // before window start
        ], now: { self.now })

        let vm = UsageDetailViewModel(store: store,
                                      resetsAt: { _, _ in resets },
                                      indexerTick: {}, now: { self.now })
        vm.recompute()
        XCTAssertEqual(vm.breakdown?.totalTokens, 40)
    }

    func testSwitchingWindowRecomputes() {
        let resets = now.addingTimeInterval(24 * 3600)
        let store = InMemoryUsageEventStore(events: [
            event(.claude, project: "cc-meter", input: 10, at: now.addingTimeInterval(-6*3600)), // in 7d not 5h
        ], now: { self.now })
        let vm = UsageDetailViewModel(store: store, resetsAt: { _, _ in resets }, indexerTick: {}, now: { self.now })
        vm.window = .fiveHour
        XCTAssertEqual(vm.breakdown?.totalTokens, 0)
        vm.window = .sevenDay
        XCTAssertEqual(vm.breakdown?.totalTokens, 10)
    }

    func testOnAppearIndexesOffMainAndSetsHasIndexed() {
        // The indexer runs on a background queue, so observe it through a thread-safe side effect
        // (appending to the store) rather than a raced counter.
        let store = InMemoryUsageEventStore(now: { self.now })
        let exp = expectation(description: "indexed")
        let vm = UsageDetailViewModel(
            store: store, resetsAt: { _, _ in nil },
            indexerTick: {
                store.append([UsageEvent(provider: .claude, at: self.now, project: "p",
                                         model: "claude-opus-4-8", tokens: TokenCounts(input: 7),
                                         dedupKey: "tick")])
            },
            now: { self.now })
        XCTAssertFalse(vm.hasIndexed)
        vm.onAppear()
        Task { @MainActor in
            while !vm.hasIndexed { try? await Task.sleep(nanoseconds: 5_000_000) }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertTrue(vm.hasIndexed)
        XCTAssertEqual(store.events(since: .distantPast).map(\.dedupKey), ["tick"])
    }

    func testLogsPresentReflectsInjectedClosure() {
        let vm = UsageDetailViewModel(store: InMemoryUsageEventStore(now: { self.now }),
                                      resetsAt: { _, _ in nil }, indexerTick: {},
                                      logsPresent: { $0 == .claude }, now: { self.now })
        XCTAssertTrue(vm.logsPresent(.claude))
        XCTAssertFalse(vm.logsPresent(.codex))
    }
}
