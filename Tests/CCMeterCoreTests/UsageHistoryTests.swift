import XCTest
@testable import CCMeterCore

final class UsageHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func usage(session: Double, at: Date) -> Usage {
        Usage(limits: [UsageLimit(kind: .session, percent: session,
                                  resetsAt: at.addingTimeInterval(3600), isActive: true)],
              fetchedAt: at)
    }

    func testRecordAppendsPerLimit() {
        var clock = start
        let store = InMemoryHistoryStore(now: { clock })
        store.record(usage(session: 10, at: clock))
        clock = start.addingTimeInterval(60)
        store.record(usage(session: 20, at: clock))
        let samples = store.recent(kindLabel: "5-hour", since: start.addingTimeInterval(-1))
        XCTAssertEqual(samples.map(\.percent), [10, 20])
    }

    func testRecentFiltersByKindAndTime() {
        var clock = start
        let store = InMemoryHistoryStore(now: { clock })
        store.record(usage(session: 10, at: clock))
        clock = start.addingTimeInterval(600)
        store.record(usage(session: 30, at: clock))
        let recent = store.recent(kindLabel: "5-hour", since: start.addingTimeInterval(300))
        XCTAssertEqual(recent.map(\.percent), [30])
        XCTAssertTrue(store.recent(kindLabel: "7-day", since: start).isEmpty)
    }

    func testPruneDropsSamplesPastRetention() {
        var clock = start
        let store = InMemoryHistoryStore(retention: 3600, now: { clock })
        store.record(usage(session: 5, at: clock))
        clock = start.addingTimeInterval(7200)   // 2h later, past 1h retention
        store.record(usage(session: 50, at: clock))
        let all = store.recent(kindLabel: "5-hour", since: start.addingTimeInterval(-10_000))
        XCTAssertEqual(all.map(\.percent), [50])  // the old 5% was pruned
    }

    func testSeriesDownsampleKeepsEndpoints() {
        let samples = (0..<100).map {
            HistorySample(kindLabel: "5-hour", percent: Double($0),
                          at: start.addingTimeInterval(Double($0)))
        }
        let store = InMemoryHistoryStore(samples: samples)
        let series = store.series(kindLabel: "5-hour", maxPoints: 10)
        XCTAssertEqual(series.count, 10)
        XCTAssertEqual(series.first, 0)
        XCTAssertEqual(series.last, 99)
    }

    func testSeriesReturnsAllWhenUnderMax() {
        let store = InMemoryHistoryStore(samples: [
            HistorySample(kindLabel: "5-hour", percent: 1, at: start),
            HistorySample(kindLabel: "5-hour", percent: 2, at: start.addingTimeInterval(1))
        ])
        XCTAssertEqual(store.series(kindLabel: "5-hour", maxPoints: 24), [1, 2])
    }

    func testFileStorePersistsAcrossInstances() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let clock = start
        let store = FileHistoryStore(url: url, now: { clock })
        store.record(usage(session: 42, at: clock))

        let reopened = FileHistoryStore(url: url, now: { clock })
        XCTAssertEqual(reopened.recent(kindLabel: "5-hour", since: start.addingTimeInterval(-1)).map(\.percent), [42])
    }
}
