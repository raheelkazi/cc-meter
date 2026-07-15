import XCTest
@testable import CCMeterCore

final class UsageIndexerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private func claudeLine(_ ts: String, req: String, msg: String, tokens: Int) -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","cwd":"/Users/x/cc-meter","requestId":"\(req)",\
        "message":{"id":"\(msg)","model":"claude-opus-4-8","usage":{"input_tokens":\(tokens),"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    private func makeIndexer(_ fs: InMemoryFileSystem, _ store: UsageEventStoring, _ cursors: CursorStoring) -> UsageIndexer {
        UsageIndexer(fileSystem: fs, store: store, cursors: cursors,
                     claudeProjectsDir: "/claude", codexSessionsDir: "/codex", now: { self.now })
    }

    func testFirstTickIngestsClaudeEvents() {
        let fs = InMemoryFileSystem()
        fs.addFile(path: "/claude/proj/s.jsonl",
                   contents: Data((claudeLine("2026-07-15T00:00:00.000Z", req: "r1", msg: "m1", tokens: 10) + "\n").utf8),
                   modified: now)
        let store = InMemoryUsageEventStore(now: { self.now })
        let cursors = InMemoryCursorStore()
        makeIndexer(fs, store, cursors).tick()
        XCTAssertEqual(store.events(since: .distantPast).map(\.tokens.input), [10])
    }

    func testSecondTickReadsOnlyAppendedBytes() {
        let fs = InMemoryFileSystem()
        let first = claudeLine("2026-07-15T00:00:00.000Z", req: "r1", msg: "m1", tokens: 10) + "\n"
        fs.addFile(path: "/claude/proj/s.jsonl", contents: Data(first.utf8), modified: now)
        let store = InMemoryUsageEventStore(now: { self.now })
        let cursors = InMemoryCursorStore()
        let indexer = makeIndexer(fs, store, cursors)
        indexer.tick()

        let second = first + claudeLine("2026-07-15T00:01:00.000Z", req: "r2", msg: "m2", tokens: 20) + "\n"
        fs.addFile(path: "/claude/proj/s.jsonl", contents: Data(second.utf8), modified: now)
        indexer.tick()
        XCTAssertEqual(store.events(since: .distantPast).map(\.tokens.input).sorted(), [10, 20])
    }

    func testDuplicateRecordsAreCountedOnce() {
        let fs = InMemoryFileSystem()
        let dup = claudeLine("2026-07-15T00:00:00.000Z", req: "r1", msg: "m1", tokens: 10) + "\n"
        fs.addFile(path: "/claude/proj/s.jsonl", contents: Data((dup + dup).utf8), modified: now)
        let store = InMemoryUsageEventStore(now: { self.now })
        makeIndexer(fs, store, InMemoryCursorStore()).tick()
        XCTAssertEqual(store.events(since: .distantPast).count, 1)
    }

    func testTruncatedFileResetsCursorWithoutDoubleCounting() {
        let fs = InMemoryFileSystem()
        let line = claudeLine("2026-07-15T00:00:00.000Z", req: "r1", msg: "m1", tokens: 10) + "\n"
        fs.addFile(path: "/claude/proj/s.jsonl", contents: Data(line.utf8), modified: now)
        let store = InMemoryUsageEventStore(now: { self.now })
        let cursors = InMemoryCursorStore()
        let indexer = makeIndexer(fs, store, cursors)
        indexer.tick()
        // File rotated/rewritten shorter, same content.
        fs.addFile(path: "/claude/proj/s.jsonl", contents: Data(line.utf8), modified: now)
        indexer.tick()
        XCTAssertEqual(store.events(since: .distantPast).count, 1, "dedup guards the re-read")
    }

    func testPartialTrailingLineIsNotDoubleCounted() {
        let fs = InMemoryFileSystem()
        let full = claudeLine("2026-07-15T00:00:00.000Z", req: "r1", msg: "m1", tokens: 10) + "\n"
        // First tick sees the line before its trailing newline has been written.
        fs.addFile(path: "/claude/proj/s.jsonl", contents: Data(String(full.dropLast()).utf8), modified: now)
        let store = InMemoryUsageEventStore(now: { self.now })
        let indexer = makeIndexer(fs, store, InMemoryCursorStore())
        indexer.tick()
        XCTAssertTrue(store.events(since: .distantPast).isEmpty, "a newline-less partial line is not parsed yet")

        // The newline arrives on the next write; the line is now counted exactly once.
        fs.addFile(path: "/claude/proj/s.jsonl", contents: Data(full.utf8), modified: now)
        indexer.tick()
        XCTAssertEqual(store.events(since: .distantPast).count, 1)
    }

    func testFilesOlderThanHorizonAreSkipped() {
        let fs = InMemoryFileSystem()
        fs.addFile(path: "/claude/proj/old.jsonl",
                   contents: Data((claudeLine("2026-06-01T00:00:00.000Z", req: "r", msg: "m", tokens: 99) + "\n").utf8),
                   modified: now.addingTimeInterval(-30*24*3600))
        let store = InMemoryUsageEventStore(now: { self.now })
        makeIndexer(fs, store, InMemoryCursorStore()).tick()
        XCTAssertTrue(store.events(since: .distantPast).isEmpty)
    }
}
