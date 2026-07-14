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

    func testFileStorePersistsAcrossInstances() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let clock = start
        let store = FileHistoryStore(url: url, now: { clock })
        store.record(usage(session: 42, at: clock))
        store.flush()   // disk writes are off the main thread now

        let reopened = FileHistoryStore(url: url, now: { clock })
        XCTAssertEqual(reopened.recent(kindLabel: "5-hour", since: start.addingTimeInterval(-1)).map(\.percent), [42])
    }

    func testHistoryDoesNotMixProvidersWithSameWindowLabel() {
        let store = InMemoryHistoryStore(now: { self.start })
        store.record(usage(session: 10, at: start), provider: .claude)
        store.record(usage(session: 70, at: start), provider: .codex)

        XCTAssertEqual(store.recent(provider: .claude, kindLabel: "5-hour", since: .distantPast)
            .map(\.percent), [10])
        XCTAssertEqual(store.recent(provider: .codex, kindLabel: "5-hour", since: .distantPast)
            .map(\.percent), [70])
    }

    func testLegacyHistoryWithoutProviderDecodesAsClaude() throws {
        let data = """
        {"kindLabel":"5-hour","percent":12,"at":1000000}
        """.data(using: .utf8)!
        let sample = try JSONDecoder().decode(HistorySample.self, from: data)
        XCTAssertEqual(sample.provider, .claude)
    }

    func testProviderHistoryFilesUseDistinctFilenames() {
        XCTAssertTrue(FileHistoryStore.defaultURL(provider: .claude).path
            .hasSuffix("history.json"))
        XCTAssertTrue(FileHistoryStore.defaultURL(provider: .codex).path
            .hasSuffix("history-codex.json"))
    }

    /// A file written by an older build is a single JSON array. It must still load, and be
    /// rewritten as JSON Lines rather than silently discarded.
    func testLegacyJSONArrayFileIsLoadedAndMigrated() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let legacy = [HistorySample(provider: .claude, kindLabel: "5-hour", percent: 42,
                                    at: start, windowResetsAt: nil)]
        try JSONEncoder().encode(legacy).write(to: url)

        let store = FileHistoryStore(url: url, now: { self.start })
        XCTAssertEqual(store.recent(kindLabel: "5-hour", since: .distantPast).map(\.percent), [42],
                       "an old-format file must not be silently dropped")

        store.flush()
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.hasPrefix("["), "the file should have been migrated to JSON Lines")

        // And it still reads back after migration.
        let reopened = FileHistoryStore(url: url, now: { self.start })
        XCTAssertEqual(reopened.recent(kindLabel: "5-hour", since: .distantPast).map(\.percent), [42])
    }

    /// A poll appends its own samples instead of re-serialising the whole file.
    func testRecordAppendsRatherThanRewritingTheWholeFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-append-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileHistoryStore(url: url, compactEvery: 1_000, now: { self.start })
        for i in 0..<5 {
            store.record(usage(session: Double(i), at: start.addingTimeInterval(Double(i))))
        }
        store.flush()

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 5, "one line per sample")

        let reopened = FileHistoryStore(url: url, now: { self.start })
        XCTAssertEqual(reopened.recent(kindLabel: "5-hour", since: .distantPast).count, 5)
    }

    /// Appending forever would grow the file without bound, since pruning only trims memory.
    /// Compaction is what actually shrinks it.
    func testCompactionRewritesTheFileAndDropsExpiredSamples() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-meter-compact-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var clock = start
        let store = FileHistoryStore(url: url, retention: 60, compactEvery: 3, now: { clock })

        store.record(usage(session: 1, at: clock))          // will expire
        clock = start.addingTimeInterval(600)               // 10 min later; retention is 60s
        store.record(usage(session: 2, at: clock))
        store.record(usage(session: 3, at: clock))          // 3rd record -> compaction
        store.flush()

        let reopened = FileHistoryStore(url: url, retention: 60, now: { clock })
        let percents = reopened.recent(kindLabel: "5-hour", since: .distantPast).map(\.percent)
        XCTAssertFalse(percents.contains(1), "the expired sample must be gone from disk after compaction")
        XCTAssertEqual(percents.sorted(), [2, 3])
    }

}
