import XCTest
@testable import CCMeterCore

final class UsageEventStoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private func event(_ key: String, at: Date, tokens: Int = 10, project: String = "cc-meter") -> UsageEvent {
        UsageEvent(provider: .claude, at: at, project: project, model: "claude-opus-4-8",
                   tokens: TokenCounts(input: tokens), dedupKey: key)
    }

    func testAppendDropsDuplicateKeys() {
        let store = InMemoryUsageEventStore(now: { self.start })
        store.append([event("k1", at: start), event("k2", at: start)])
        store.append([event("k1", at: start), event("k3", at: start)])  // k1 is a dup
        XCTAssertEqual(Set(store.events(since: .distantPast).map(\.dedupKey)), ["k1", "k2", "k3"])
    }

    func testEventsSinceFilters() {
        let store = InMemoryUsageEventStore(now: { self.start })
        store.append([event("old", at: start), event("new", at: start.addingTimeInterval(600))])
        XCTAssertEqual(store.events(since: start.addingTimeInterval(300)).map(\.dedupKey), ["new"])
    }

    func testRetentionPrunesAndFreesTheKey() {
        var clock = start
        let store = InMemoryUsageEventStore(retention: 3600, now: { clock })
        store.append([event("a", at: clock)])
        clock = start.addingTimeInterval(7200)                 // 2h later, past 1h retention
        store.append([event("a", at: clock)])                  // key freed -> re-added
        XCTAssertEqual(store.events(since: .distantPast).map(\.at), [clock])
    }

    func testFileStorePersistsAndDedupsAcrossInstances() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccm-events-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileUsageEventStore(url: url, now: { self.start })
        store.append([event("k1", at: start)])
        store.flush()

        let reopened = FileUsageEventStore(url: url, now: { self.start })
        reopened.append([event("k1", at: start), event("k2", at: start)])  // k1 already on disk
        reopened.flush()
        XCTAssertEqual(Set(reopened.events(since: .distantPast).map(\.dedupKey)), ["k1", "k2"])
    }

    func testCompactionRewritesDroppingExpired() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccm-events-compact-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var clock = start
        let store = FileUsageEventStore(url: url, retention: 60, compactEvery: 2, now: { clock })
        store.append([event("expire", at: clock)])
        clock = start.addingTimeInterval(600)
        store.append([event("keep1", at: clock)])
        store.append([event("keep2", at: clock)])   // 2nd append after start -> compaction
        store.flush()

        let reopened = FileUsageEventStore(url: url, retention: 60, now: { clock })
        XCTAssertEqual(Set(reopened.events(since: .distantPast).map(\.dedupKey)), ["keep1", "keep2"])
    }

    func testLoadDedupsDuplicateLinesOnDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccm-dup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = try JSONEncoder().encode(event("k1", at: start))
        var payload = Data(); payload.append(line); payload.append(0x0A); payload.append(line); payload.append(0x0A)
        try payload.write(to: url)
        let store = FileUsageEventStore(url: url, now: { self.start })
        XCTAssertEqual(store.events(since: .distantPast).count, 1, "duplicate lines on disk are collapsed on load")
    }
}
