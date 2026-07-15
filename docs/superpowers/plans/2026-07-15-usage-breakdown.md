# Usage & Cost Intelligence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Usage" tab to the cc-meter popover that shows real token consumption (and a notional $ estimate) per project and per model, bucketed into the current 5h / 7d rate-limit window, parsed incrementally from Claude Code and Codex local session logs.

**Architecture:** All logic lives in `CCMeterCore` behind an injected `FileSystemReading` seam so it is fully unit-testable without touching real logs. A background `UsageIndexer` reads only new bytes of recently-touched log files (offset cursors), parses them into deduplicated `UsageEvent`s, and appends them to a thread-safe JSON-Lines `UsageEventStore` (mirrors the existing `FileHistoryStore`). A `UsageDetailViewModel` rolls stored events into a `UsageBreakdown` for the selected provider/window; a new SwiftUI `UsageTabView` renders it. The parsed data feeds only the Usage tab.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit + SwiftUI, XCTest. macOS 13+. No new dependencies (hand-drawn SwiftUI bar chart, not Swift Charts).

## Global Constraints

- Platform floor: **macOS 13** (`Package.swift`). Do not use APIs newer than macOS 13.
- All new logic goes in target **`CCMeterCore`**; only SwiftUI views, `SettingsView`, and `AppDelegate` wiring go in target **`cc-meter`**. New files need no `Package.swift` edit (SPM auto-discovers files under a target's directory).
- Persisted files live under `~/Library/Application Support/cc-meter/` via `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`, exactly like `FileHistoryStore.defaultURL`.
- Every stored type decodes leniently (missing fields fall back to defaults) so a new build never fails to read an old file.
- Inject `now: () -> Date = { Date() }` into everything time-dependent; tests pass a fixed clock. Never call `Date()` inside logic.
- No em dashes in code comments or copy (use hyphens).
- Retention horizon = **7 days**; the indexer only parses files with mtime within **8 days** (1-day margin).
- Notional `$` is always secondary and labeled an estimate; unknown/unpriced models (e.g. Codex) show an explicit "n/a" rather than a wrong number.
- Test style: XCTest, `@testable import CCMeterCore`, fixed `Date(timeIntervalSince1970:)` clocks, temp-file URLs with `defer { try? FileManager.default.removeItem(at: url) }`, `store.flush()` before reopening a file store (see `Tests/CCMeterCoreTests/UsageHistoryTests.swift`).
- Run the full suite with: `swift test 2>&1 | tail -30`. Run one test with: `swift test --filter <TestClass>/<testMethod> 2>&1 | tail -30`.
- Commit after each task with a `feat:`/`test:` message. Branch is `feat/usage-breakdown`.

## Global Interfaces (types defined across tasks - authoritative signatures)

```swift
// Task 1
public struct TokenCounts: Equatable, Codable {
    public var input, output, cacheCreation, cacheRead, reasoning: Int
    public init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0, reasoning: Int = 0)
    public var total: Int { input + output + cacheCreation + cacheRead } // reasoning excluded (subset of output)
    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts
}
public struct UsageEvent: Equatable, Codable {
    public let provider: UsageProvider
    public let at: Date
    public let project: String
    public let model: String
    public let tokens: TokenCounts
    public let dedupKey: String
    public init(provider: UsageProvider, at: Date, project: String, model: String, tokens: TokenCounts, dedupKey: String)
}

// Task 2
public struct FileEntry: Equatable { public let path: String; public let modified: Date; public let size: Int }
public protocol FileSystemReading {
    func recursiveFiles(inDirectory dir: String, withSuffix suffix: String) -> [FileEntry]
    func read(path: String, fromOffset offset: Int, length: Int) -> Data?
}
public struct SystemFileSystem: FileSystemReading { public init() }
public final class InMemoryFileSystem: FileSystemReading { /* test double */ }

// Task 3
public enum ProjectName { public static func from(cwd: String) -> String }

// Task 4 / 5 - parsers return events plus (Codex) carried state
public enum ClaudeUsageLogParser { public static func parse(lines: Data) -> [UsageEvent] }
public struct CodexParseState: Equatable { public var model: String?; public var cwd: String?; public var sessionId: String?; public init(model: String? = nil, cwd: String? = nil, sessionId: String? = nil) }
public enum CodexUsageLogParser {
    public static func parse(lines: Data, state: CodexParseState) -> (events: [UsageEvent], state: CodexParseState)
}

// Task 6
public protocol UsageEventStoring: AnyObject {
    func append(_ events: [UsageEvent])
    func events(since: Date) -> [UsageEvent]
    func flush()
}
public final class FileUsageEventStore: UsageEventStoring {
    public init(url: URL, retention: TimeInterval = 7*24*3600, compactEvery: Int = 500, now: @escaping () -> Date = { Date() })
    public static func defaultURL(fileManager: FileManager = .default) -> URL
}
public final class InMemoryUsageEventStore: UsageEventStoring {
    public init(events: [UsageEvent] = [], retention: TimeInterval = 7*24*3600, now: @escaping () -> Date = { Date() })
}

// Task 7
public struct FileCursor: Codable, Equatable { public var offset: Int; public var size: Int; public var codexModel: String?; public var codexCwd: String?; public var codexSessionId: String? }
public protocol CursorStoring: AnyObject { func load() -> [String: FileCursor]; func save(_ cursors: [String: FileCursor]) }
public final class FileCursorStore: CursorStoring { public init(url: URL); public static func defaultURL(fileManager: FileManager = .default) -> URL }
public final class InMemoryCursorStore: CursorStoring { public init(_ initial: [String: FileCursor] = [:]) }
public final class UsageIndexer {
    public init(fileSystem: FileSystemReading, store: UsageEventStoring, cursors: CursorStoring,
                claudeProjectsDir: String, codexSessionsDir: String,
                horizon: TimeInterval = 8*24*3600, maxBytesPerFilePerTick: Int = 16*1024*1024,
                now: @escaping () -> Date = { Date() })
    public func tick()
    public static func defaultClaudeProjectsDir() -> String
    public static func defaultCodexSessionsDir() -> String
}

// Task 8
public struct ModelPrice: Equatable { public let input, output, cacheWrite, cacheRead: Double } // USD per token
public enum ModelPriceTable {
    public static let pricesAsOf: String
    public static func price(for model: String) -> ModelPrice?
    public static func notionalCost(_ tokens: TokenCounts, model: String) -> Double?
}

// Task 9
public enum UsageWindow: String, CaseIterable, Equatable {
    case fiveHour, sevenDay
    public var length: TimeInterval { self == .fiveHour ? 5*3600 : 7*24*3600 }
    public var bucketCount: Int { self == .fiveHour ? 5 : 7 }
    public var shortLabel: String { self == .fiveHour ? "5h" : "7d" }
}
public struct ProjectUsage: Equatable { public let project: String; public let tokens: Int; public let share: Double }
public struct ModelUsage: Equatable { public let model: String; public let tokens: Int; public let share: Double }
public struct UsageBucket: Equatable { public let index: Int; public let tokens: Int }
public struct UsageBreakdown: Equatable {
    public let provider: UsageProvider
    public let window: UsageWindow
    public let totalTokens: Int
    public let notionalCost: Double?
    public let projects: [ProjectUsage]
    public let models: [ModelUsage]
    public let buckets: [UsageBucket]
}
public enum UsageBreakdownBuilder {
    public static func build(events: [UsageEvent], provider: UsageProvider, window: UsageWindow, windowStart: Date, now: Date) -> UsageBreakdown
}

// Task 10
@MainActor public final class UsageDetailViewModel: ObservableObject {
    @Published public var provider: UsageProvider
    @Published public var window: UsageWindow
    @Published public private(set) var breakdown: UsageBreakdown?
    @Published public private(set) var hasIndexed: Bool          // false until first index pass finishes
    public init(store: UsageEventStoring,
                resetsAt: @escaping (UsageProvider, UsageWindow) -> Date?,
                indexerTick: @escaping () -> Void,               // synchronous; the VM runs it off-main
                logsPresent: @escaping (UsageProvider) -> Bool = { _ in true },
                now: @escaping () -> Date = { Date() })
    public func recompute()
    public func refreshInBackground()                            // recompute now, index off-main, recompute again
    public func onAppear()
    public func logsPresent(_ provider: UsageProvider) -> Bool
}
```

---

### Task 1: `UsageEvent` and `TokenCounts` value types

**Files:**
- Create: `Sources/CCMeterCore/UsageEvent.swift`
- Test: `Tests/CCMeterCoreTests/UsageEventTests.swift`

**Interfaces:**
- Consumes: `UsageProvider` (from `Provider.swift`).
- Produces: `TokenCounts`, `UsageEvent` (see Global Interfaces).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CCMeterCore

final class UsageEventTests: XCTestCase {
    func testTotalExcludesReasoningWhichIsASubsetOfOutput() {
        // Codex reasoning_output_tokens is already inside output_tokens, so summing it double-counts.
        let t = TokenCounts(input: 100, output: 20, cacheCreation: 5, cacheRead: 200, reasoning: 3)
        XCTAssertEqual(t.total, 325)
    }

    func testAdditionIsElementwise() {
        let a = TokenCounts(input: 1, output: 2, cacheCreation: 3, cacheRead: 4, reasoning: 5)
        let b = TokenCounts(input: 10, output: 20, cacheCreation: 30, cacheRead: 40, reasoning: 50)
        XCTAssertEqual(a + b, TokenCounts(input: 11, output: 22, cacheCreation: 33, cacheRead: 44, reasoning: 55))
    }

    func testEventRoundTripsThroughCodable() throws {
        let event = UsageEvent(provider: .claude, at: Date(timeIntervalSince1970: 1_000_000),
                               project: "cc-meter", model: "claude-opus-4-8",
                               tokens: TokenCounts(input: 10, output: 2), dedupKey: "claude:r1:m1")
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(UsageEvent.self, from: data), event)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UsageEventTests 2>&1 | tail -20`
Expected: FAIL - compile error, `TokenCounts`/`UsageEvent` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Token counts for one model turn. `reasoning` is Codex-only; Claude leaves it 0.
public struct TokenCounts: Equatable, Codable {
    public var input: Int
    public var output: Int
    public var cacheCreation: Int
    public var cacheRead: Int
    public var reasoning: Int

    public init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0,
                cacheRead: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.reasoning = reasoning
    }

    public var total: Int { input + output + cacheCreation + cacheRead } // reasoning excluded (subset of output)

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input,
                    output: lhs.output + rhs.output,
                    cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
                    cacheRead: lhs.cacheRead + rhs.cacheRead,
                    reasoning: lhs.reasoning + rhs.reasoning)
    }
}

/// One deduplicated model turn parsed from a local log, attributed to a project and model.
public struct UsageEvent: Equatable, Codable {
    public let provider: UsageProvider
    public let at: Date
    public let project: String
    public let model: String
    public let tokens: TokenCounts
    /// Stable identity used to drop the ~2x duplicates Claude writes and to survive re-parses.
    public let dedupKey: String

    public init(provider: UsageProvider, at: Date, project: String,
                model: String, tokens: TokenCounts, dedupKey: String) {
        self.provider = provider
        self.at = at
        self.project = project
        self.model = model
        self.tokens = tokens
        self.dedupKey = dedupKey
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter UsageEventTests 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CCMeterCore/UsageEvent.swift Tests/CCMeterCoreTests/UsageEventTests.swift
git commit -m "feat: UsageEvent and TokenCounts value types"
```

---

### Task 2: `FileSystemReading` seam + real and fake implementations

**Files:**
- Create: `Sources/CCMeterCore/FileSystemReading.swift`
- Test: `Tests/CCMeterCoreTests/FileSystemReadingTests.swift`

**Interfaces:**
- Produces: `FileEntry`, `FileSystemReading`, `SystemFileSystem`, `InMemoryFileSystem` (see Global Interfaces). `InMemoryFileSystem` also exposes `func addFile(path: String, contents: Data, modified: Date)` for tests.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CCMeterCore

final class FileSystemReadingTests: XCTestCase {
    func testInMemoryListsBySuffixAndReadsRanges() {
        let fs = InMemoryFileSystem()
        fs.addFile(path: "/logs/a.jsonl", contents: Data("hello\nworld".utf8),
                   modified: Date(timeIntervalSince1970: 100))
        fs.addFile(path: "/logs/b.txt", contents: Data("nope".utf8),
                   modified: Date(timeIntervalSince1970: 100))

        let entries = fs.recursiveFiles(inDirectory: "/logs", withSuffix: ".jsonl")
        XCTAssertEqual(entries.map(\.path), ["/logs/a.jsonl"])
        XCTAssertEqual(entries.first?.size, 11)

        XCTAssertEqual(fs.read(path: "/logs/a.jsonl", fromOffset: 6, length: 5), Data("world".utf8))
        XCTAssertEqual(fs.read(path: "/logs/a.jsonl", fromOffset: 6, length: 999), Data("world".utf8))
        XCTAssertNil(fs.read(path: "/missing", fromOffset: 0, length: 1))
    }

    func testSystemFileSystemReadsARealFileRange() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccm-fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.jsonl")
        try Data("0123456789".utf8).write(to: file)

        let fs = SystemFileSystem()
        let entries = fs.recursiveFiles(inDirectory: dir.path, withSuffix: ".jsonl")
        XCTAssertEqual(entries.map { ($0.path as NSString).lastPathComponent }, ["x.jsonl"])
        XCTAssertEqual(fs.read(path: file.path, fromOffset: 3, length: 4), Data("3456".utf8))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FileSystemReadingTests 2>&1 | tail -20`
Expected: FAIL - types undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// One file the indexer might read: enough to decide whether it changed and where to resume.
public struct FileEntry: Equatable {
    public let path: String
    public let modified: Date
    public let size: Int
    public init(path: String, modified: Date, size: Int) {
        self.path = path; self.modified = modified; self.size = size
    }
}

/// The one seam over the filesystem, so parsing/indexing is testable without touching real logs.
public protocol FileSystemReading {
    /// Every file under `dir` (recursively) whose path ends in `suffix`.
    func recursiveFiles(inDirectory dir: String, withSuffix suffix: String) -> [FileEntry]
    /// `length` bytes starting at `offset`. Returns fewer bytes at EOF; nil if the file is unreadable.
    func read(path: String, fromOffset offset: Int, length: Int) -> Data?
}

/// Real Foundation-backed implementation. Pure Foundation, so it lives in Core and stays testable.
public struct SystemFileSystem: FileSystemReading {
    public init() {}

    public func recursiveFiles(inDirectory dir: String, withSuffix suffix: String) -> [FileEntry] {
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys) else {
            return []
        }
        var out: [FileEntry] = []
        for case let url as URL in en where url.path.hasSuffix(suffix) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            out.append(FileEntry(path: url.path,
                                 modified: values?.contentModificationDate ?? .distantPast,
                                 size: values?.fileSize ?? 0))
        }
        return out
    }

    public func read(path: String, fromOffset offset: Int, length: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return try handle.read(upToCount: max(0, length)) ?? Data()
        } catch {
            return nil
        }
    }
}

/// In-memory filesystem for tests.
public final class InMemoryFileSystem: FileSystemReading {
    private var files: [String: (data: Data, modified: Date)] = [:]
    public init() {}

    public func addFile(path: String, contents: Data, modified: Date) {
        files[path] = (contents, modified)
    }

    public func recursiveFiles(inDirectory dir: String, withSuffix suffix: String) -> [FileEntry] {
        files.filter { $0.key.hasPrefix(dir) && $0.key.hasSuffix(suffix) }
            .map { FileEntry(path: $0.key, modified: $0.value.modified, size: $0.value.data.count) }
            .sorted { $0.path < $1.path }
    }

    public func read(path: String, fromOffset offset: Int, length: Int) -> Data? {
        guard let data = files[path]?.data, offset <= data.count else {
            return files[path] == nil ? nil : Data()
        }
        let end = min(data.count, offset + length)
        return data.subdata(in: offset..<end)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FileSystemReadingTests 2>&1 | tail -20`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CCMeterCore/FileSystemReading.swift Tests/CCMeterCoreTests/FileSystemReadingTests.swift
git commit -m "feat: FileSystemReading seam with real and in-memory implementations"
```

---

### Task 3: `ProjectName` (cwd -> display name, worktree normalization)

**Files:**
- Create: `Sources/CCMeterCore/ProjectName.swift`
- Test: `Tests/CCMeterCoreTests/ProjectNameTests.swift`

**Interfaces:**
- Produces: `ProjectName.from(cwd:)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CCMeterCore

final class ProjectNameTests: XCTestCase {
    func testPlainCwdUsesLeafDirectory() {
        XCTAssertEqual(ProjectName.from(cwd: "/Users/x/Desktop/Speechify/cc-meter"), "cc-meter")
    }

    func testTrailingSlashIsIgnored() {
        XCTAssertEqual(ProjectName.from(cwd: "/Users/x/web/"), "web")
    }

    func testClaudeWorktreeMapsToParentProject() {
        XCTAssertEqual(
            ProjectName.from(cwd: "/Users/x/MacApp/mac-speechify-ai-assistant/.claude-worktrees/dictation"),
            "mac-speechify-ai-assistant")
    }

    func testCodexWorktreeLeafIsProject() {
        XCTAssertEqual(
            ProjectName.from(cwd: "/Users/x/.codex/worktrees/79e6/mac-speechify-ai-assistant"),
            "mac-speechify-ai-assistant")
    }

    func testEmptyFallsBackToWholeString() {
        XCTAssertEqual(ProjectName.from(cwd: ""), "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProjectNameTests 2>&1 | tail -20`
Expected: FAIL - `ProjectName` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Maps a working-directory path to the project name shown in the Usage tab.
///
/// Worktree checkouts would otherwise appear as separate projects; a `.claude-worktrees`
/// segment is mapped back to its parent project. Codex worktrees already end in the project
/// name (`.codex/worktrees/<hash>/<project>`), so the leaf is correct there.
public enum ProjectName {
    public static func from(cwd: String) -> String {
        let parts = cwd.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return cwd }
        if let i = parts.firstIndex(of: ".claude-worktrees"), i > 0 {
            return parts[i - 1]
        }
        return parts.last ?? cwd
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProjectNameTests 2>&1 | tail -20`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CCMeterCore/ProjectName.swift Tests/CCMeterCoreTests/ProjectNameTests.swift
git commit -m "feat: ProjectName cwd normalization with worktree handling"
```

---

### Task 4: `ClaudeUsageLogParser`

**Files:**
- Create: `Sources/CCMeterCore/ClaudeUsageLogParser.swift`
- Test: `Tests/CCMeterCoreTests/ClaudeUsageLogParserTests.swift`

**Interfaces:**
- Consumes: `UsageEvent`, `TokenCounts`, `ProjectName`, `ISODate` (from `ISODate.swift`).
- Produces: `ClaudeUsageLogParser.parse(lines:)`. Each `assistant` record with `message.usage` becomes one `UsageEvent`; `dedupKey = "claude:\(requestId):\(message.id)"`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CCMeterCore

final class ClaudeUsageLogParserTests: XCTestCase {
    private func line(_ json: String) -> Data { Data((json + "\n").utf8) }

    func testParsesAssistantUsageRecord() {
        let data = line("""
        {"type":"assistant","timestamp":"2026-07-03T16:16:46.300Z","cwd":"/Users/x/cc-meter",\
        "requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-4-8",\
        "usage":{"input_tokens":29224,"output_tokens":810,"cache_creation_input_tokens":2555,"cache_read_input_tokens":18258}}}
        """)
        let events = ClaudeUsageLogParser.parse(lines: data)
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e.provider, .claude)
        XCTAssertEqual(e.project, "cc-meter")
        XCTAssertEqual(e.model, "claude-opus-4-8")
        XCTAssertEqual(e.tokens, TokenCounts(input: 29224, output: 810, cacheCreation: 2555, cacheRead: 18258))
        XCTAssertEqual(e.dedupKey, "claude:req_1:msg_1")
        XCTAssertEqual(e.at, ISODate.parse("2026-07-03T16:16:46.300Z"))
    }

    func testSkipsSyntheticModel() {
        let data = line("""
        {"type":"assistant","timestamp":"2026-07-03T16:16:46.300Z","cwd":"/Users/x/cc-meter",\
        "requestId":"r","message":{"id":"m","model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":1}}}
        """)
        XCTAssertTrue(ClaudeUsageLogParser.parse(lines: data).isEmpty)
    }

    func testIgnoresNonAssistantAndUsagelessAndMalformedLines() {
        let data = line("{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}")
            + line("{\"type\":\"assistant\",\"message\":{\"id\":\"m\",\"model\":\"claude-opus-4-8\"}}")
            + line("{ not json")
        XCTAssertTrue(ClaudeUsageLogParser.parse(lines: data).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeUsageLogParserTests 2>&1 | tail -20`
Expected: FAIL - `ClaudeUsageLogParser` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Parses `~/.claude/projects/**/**.jsonl` lines into usage events.
///
/// Only `assistant` records carrying `message.usage` count. Each is self-contained (cwd, model,
/// requestId, message.id all present), so a byte-range chunk of whole lines parses without any
/// carried state. `<synthetic>` model records are injected, not real usage, and are dropped.
public enum ClaudeUsageLogParser {
    public static func parse(lines: Data) -> [UsageEvent] {
        var events: [UsageEvent] = []
        for lineData in lines.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String, model != "<synthetic>",
                  let messageId = message["id"] as? String,
                  let cwd = obj["cwd"] as? String,
                  let timestamp = obj["timestamp"] as? String,
                  let at = ISODate.parse(timestamp)
            else { continue }

            let requestId = obj["requestId"] as? String ?? messageId
            let tokens = TokenCounts(
                input: int(usage["input_tokens"]),
                output: int(usage["output_tokens"]),
                cacheCreation: int(usage["cache_creation_input_tokens"]),
                cacheRead: int(usage["cache_read_input_tokens"]))

            events.append(UsageEvent(provider: .claude, at: at,
                                     project: ProjectName.from(cwd: cwd), model: model,
                                     tokens: tokens, dedupKey: "claude:\(requestId):\(messageId)"))
        }
        return events
    }

    private static func int(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return 0
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClaudeUsageLogParserTests 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CCMeterCore/ClaudeUsageLogParser.swift Tests/CCMeterCoreTests/ClaudeUsageLogParserTests.swift
git commit -m "feat: Claude usage log parser"
```

---

### Task 5: `CodexUsageLogParser` (with carried state)

**Files:**
- Create: `Sources/CCMeterCore/CodexUsageLogParser.swift`
- Test: `Tests/CCMeterCoreTests/CodexUsageLogParserTests.swift`

**Interfaces:**
- Consumes: `UsageEvent`, `TokenCounts`, `ProjectName`, `ISODate`.
- Produces: `CodexParseState`, `CodexUsageLogParser.parse(lines:state:)`. Uses `last_token_usage` deltas; model comes from the most recent `turn_context.model`, cwd from `session_meta.cwd` (or `turn_context.cwd`). `dedupKey = "codex:\(sessionId):\(timestamp)"`. Carried state lets an incremental chunk resume with the model/cwd seen before the cursor.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CCMeterCore

final class CodexUsageLogParserTests: XCTestCase {
    private func line(_ json: String) -> Data { Data((json + "\n").utf8) }

    func testParsesTokenCountUsingLastDeltaWithModelFromTurnContext() {
        let data =
            line("""
            {"type":"session_meta","payload":{"id":"sess_1","cwd":"/Users/x/cc-meter","timestamp":"2026-07-15T01:11:09.000Z"}}
            """) +
            line("""
            {"type":"turn_context","payload":{"model":"gpt-5.6-sol","cwd":"/Users/x/cc-meter"}}
            """) +
            line("""
            {"timestamp":"2026-07-15T01:11:10.074Z","type":"event_msg","payload":{"type":"token_count",\
            "info":{"total_token_usage":{"input_tokens":99999,"cached_input_tokens":8,"output_tokens":9,"reasoning_output_tokens":9,"total_tokens":99999},\
            "last_token_usage":{"input_tokens":21256,"cached_input_tokens":9984,"output_tokens":512,"reasoning_output_tokens":105,"total_tokens":21768}}}}
            """)
        let (events, state) = CodexUsageLogParser.parse(lines: data, state: CodexParseState())
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e.provider, .codex)
        XCTAssertEqual(e.project, "cc-meter")
        XCTAssertEqual(e.model, "gpt-5.6-sol")
        // input is the non-cached remainder; cacheRead is cached_input_tokens.
        XCTAssertEqual(e.tokens, TokenCounts(input: 21256 - 9984, output: 512, cacheRead: 9984, reasoning: 105))
        XCTAssertEqual(e.dedupKey, "codex:sess_1:2026-07-15T01:11:10.074Z")
        XCTAssertEqual(state.model, "gpt-5.6-sol")
        XCTAssertEqual(state.cwd, "/Users/x/cc-meter")
        XCTAssertEqual(state.sessionId, "sess_1")
    }

    func testResumesFromSeededStateWhenChunkHasNoMetaOrTurnContext() {
        // Real token_count records carry NO session_id; model, cwd, and session id all come from
        // earlier records (session_meta/turn_context) and are seeded from the cursor's carried state.
        let seeded = CodexParseState(model: "gpt-5.6-sol", cwd: "/Users/x/web", sessionId: "sess_2")
        let data = line("""
        {"timestamp":"2026-07-15T02:00:00.000Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":15}}}}
        """)
        let (events, _) = CodexUsageLogParser.parse(lines: data, state: seeded)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].model, "gpt-5.6-sol")
        XCTAssertEqual(events[0].project, "web")
        XCTAssertEqual(events[0].dedupKey, "codex:sess_2:2026-07-15T02:00:00.000Z")
        XCTAssertEqual(events[0].tokens, TokenCounts(input: 10, output: 5, cacheRead: 0, reasoning: 0))
    }

    func testSkipsTokenCountWithNoKnownModel() {
        let data = line("""
        {"timestamp":"2026-07-15T02:00:00.000Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}
        """)
        let (events, _) = CodexUsageLogParser.parse(lines: data, state: CodexParseState())
        XCTAssertTrue(events.isEmpty, "no model context yet -> cannot attribute, so skip")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CodexUsageLogParserTests 2>&1 | tail -20`
Expected: FAIL - `CodexUsageLogParser` / `CodexParseState` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Model + cwd carried across incremental chunks of one Codex rollout file.
///
/// A `token_count` event carries neither: model comes from the most recent `turn_context`,
/// cwd from `session_meta`. Both usually precede the cursor once a session is underway, so the
/// indexer persists this state per file and seeds the next chunk with it.
public struct CodexParseState: Equatable {
    public var model: String?
    public var cwd: String?
    public var sessionId: String?
    public init(model: String? = nil, cwd: String? = nil, sessionId: String? = nil) {
        self.model = model; self.cwd = cwd; self.sessionId = sessionId
    }
}

/// Parses `~/.codex/sessions/**/rollout-*.jsonl` lines into usage events.
///
/// Sums `last_token_usage` (per-turn delta); `total_token_usage` is cumulative and must not be
/// summed. `cached_input_tokens` is folded into `cacheRead`, and `input` is the non-cached
/// remainder so `tokens.total` matches the reported `total_tokens`.
public enum CodexUsageLogParser {
    public static func parse(lines: Data, state: CodexParseState) -> (events: [UsageEvent], state: CodexParseState) {
        var state = state
        var events: [UsageEvent] = []

        for lineData in lines.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any]

            switch type {
            case "session_meta":
                if let p = payload {
                    if let cwd = p["cwd"] as? String { state.cwd = cwd }
                    if let id = p["id"] as? String { state.sessionId = id }
                    if let id = p["session_id"] as? String { state.sessionId = id }
                }
            case "turn_context":
                if let p = payload {
                    if let model = p["model"] as? String { state.model = model }
                    if let cwd = p["cwd"] as? String { state.cwd = cwd }
                }
            case "event_msg":
                guard let p = payload, p["type"] as? String == "token_count",
                      let info = p["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any],
                      let model = state.model,
                      let timestamp = obj["timestamp"] as? String,
                      let at = ISODate.parse(timestamp)
                else { continue }

                let sid = state.sessionId ?? "unknown"
                let cached = int(last["cached_input_tokens"])
                let tokens = TokenCounts(
                    input: max(0, int(last["input_tokens"]) - cached),
                    output: int(last["output_tokens"]),
                    cacheRead: cached,
                    reasoning: int(last["reasoning_output_tokens"]))

                events.append(UsageEvent(provider: .codex, at: at,
                                         project: ProjectName.from(cwd: state.cwd ?? ""),
                                         model: model, tokens: tokens,
                                         dedupKey: "codex:\(sid):\(timestamp)"))
            default:
                continue
            }
        }
        return (events, state)
    }

    private static func int(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return 0
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CodexUsageLogParserTests 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CCMeterCore/CodexUsageLogParser.swift Tests/CCMeterCoreTests/CodexUsageLogParserTests.swift
git commit -m "feat: Codex usage log parser with carried model/cwd state"
```

---

### Task 6: `UsageEventStore` (deduped, thread-safe, JSON-Lines)

**Files:**
- Create: `Sources/CCMeterCore/UsageEventStore.swift`
- Test: `Tests/CCMeterCoreTests/UsageEventStoreTests.swift`

**Interfaces:**
- Consumes: `UsageEvent`.
- Produces: `UsageEventStoring`, `FileUsageEventStore`, `InMemoryUsageEventStore` (see Global Interfaces). `append` drops any event whose `dedupKey` is already retained. `events(since:)` returns a thread-safe snapshot (indexer appends off-main; view-model reads on main). Retention + compaction mirror `FileHistoryStore`.

- [ ] **Step 1: Write the failing test**

```swift
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UsageEventStoreTests 2>&1 | tail -20`
Expected: FAIL - types undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public protocol UsageEventStoring: AnyObject {
    /// Appends events whose dedupKey is not already retained. Safe to call off the main thread.
    func append(_ events: [UsageEvent])
    /// Snapshot of retained events at or after `since`. Safe to call from any thread.
    func events(since: Date) -> [UsageEvent]
    /// Blocks until queued disk writes land (tests, clean shutdown).
    func flush()
}

private enum EventMath {
    static func pruned(_ events: [UsageEvent], now: Date, retention: TimeInterval) -> [UsageEvent] {
        let cutoff = now.addingTimeInterval(-retention)
        return events.filter { $0.at >= cutoff }
    }
}

/// Deduplicated JSON-Lines store of usage events, mirroring `FileHistoryStore`: append cheaply,
/// compact occasionally, prune to a retention window. Unlike `FileHistoryStore` it is guarded by
/// a lock, because the indexer appends from a background queue while the view-model reads on main.
public final class FileUsageEventStore: UsageEventStoring {
    private let url: URL
    private let retention: TimeInterval
    private let compactEvery: Int
    private let now: () -> Date
    private let lock = NSLock()
    private var events: [UsageEvent]
    private var keys: Set<String>
    private var recordsSinceCompact = 0
    private static let io = DispatchQueue(label: "cc-meter.usage-events.io", qos: .utility)

    public init(url: URL, retention: TimeInterval = 7*24*3600,
                compactEvery: Int = 500, now: @escaping () -> Date = { Date() }) {
        self.url = url
        self.retention = retention
        self.compactEvery = compactEvery
        self.now = now
        let loaded = Self.load(url)
        self.events = EventMath.pruned(loaded, now: now(), retention: retention)
        self.keys = Set(self.events.map(\.dedupKey))
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("cc-meter", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-events.json")
    }

    private static func load(_ url: URL) -> [UsageEvent] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(UsageEvent.self, from: Data($0)) }
    }

    public func flush() { Self.io.sync {} }

    public func append(_ incoming: [UsageEvent]) {
        lock.lock()
        let clock = now()
        var fresh: [UsageEvent] = []
        for event in incoming where !keys.contains(event.dedupKey) {
            keys.insert(event.dedupKey)
            fresh.append(event)
        }
        guard !fresh.isEmpty else { lock.unlock(); return }
        events.append(contentsOf: fresh)
        events = EventMath.pruned(events, now: clock, retention: retention)
        keys = Set(events.map(\.dedupKey))
        recordsSinceCompact += fresh.count
        let shouldCompact = recordsSinceCompact >= compactEvery
        let snapshot = events
        lock.unlock()

        if shouldCompact { compact(snapshot) } else { appendToDisk(fresh) }
    }

    public func events(since: Date) -> [UsageEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.at >= since }
    }

    private func appendToDisk(_ fresh: [UsageEvent]) {
        let payload = Self.encode(fresh)
        guard !payload.isEmpty else { return }
        let url = self.url
        Self.io.async {
            guard FileManager.default.fileExists(atPath: url.path) else {
                try? payload.write(to: url, options: .atomic); return
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        }
    }

    private func compact(_ snapshot: [UsageEvent]) {
        lock.lock(); recordsSinceCompact = 0; lock.unlock()
        let payload = Self.encode(snapshot)
        let url = self.url
        Self.io.async { try? payload.write(to: url, options: .atomic) }
    }

    private static func encode(_ events: [UsageEvent]) -> Data {
        let encoder = JSONEncoder()
        var payload = Data()
        for event in events {
            guard let line = try? encoder.encode(event) else { continue }
            payload.append(line); payload.append(UInt8(ascii: "\n"))
        }
        return payload
    }
}

/// In-memory event store for tests and previews.
public final class InMemoryUsageEventStore: UsageEventStoring {
    private let retention: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var events: [UsageEvent]
    private var keys: Set<String>

    public init(events: [UsageEvent] = [], retention: TimeInterval = 7*24*3600,
                now: @escaping () -> Date = { Date() }) {
        self.events = events
        self.retention = retention
        self.now = now
        self.keys = Set(events.map(\.dedupKey))
    }

    public func append(_ incoming: [UsageEvent]) {
        lock.lock(); defer { lock.unlock() }
        let clock = now()
        for event in incoming where !keys.contains(event.dedupKey) {
            keys.insert(event.dedupKey)
            events.append(event)
        }
        events = EventMath.pruned(events, now: clock, retention: retention)
        keys = Set(events.map(\.dedupKey))
    }

    public func events(since: Date) -> [UsageEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.at >= since }
    }

    public func flush() {}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter UsageEventStoreTests 2>&1 | tail -20`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CCMeterCore/UsageEventStore.swift Tests/CCMeterCoreTests/UsageEventStoreTests.swift
git commit -m "feat: deduplicated thread-safe usage event store"
```

---

### Task 7: `UsageIndexer` (incremental, cursor-tracked)

**Files:**
- Create: `Sources/CCMeterCore/UsageIndexer.swift`
- Test: `Tests/CCMeterCoreTests/UsageIndexerTests.swift`

**Interfaces:**
- Consumes: `FileSystemReading`, `UsageEventStoring`, `ClaudeUsageLogParser`, `CodexUsageLogParser`, `CodexParseState`, `UsageEvent`.
- Produces: `FileCursor`, `CursorStoring`, `FileCursorStore`, `InMemoryCursorStore`, `UsageIndexer` (see Global Interfaces). A file under `claudeProjectsDir` uses the Claude parser; under `codexSessionsDir`, the Codex parser (seeded from the cursor's carried state). `tick()` reads only bytes past the cursor up to the last newline; a shrunk file resets the cursor to 0. Correctness never depends on the cursor - the store dedups by key - so a re-read cannot double-count.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UsageIndexerTests 2>&1 | tail -20`
Expected: FAIL - types undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Where we last stopped reading a file, plus the Codex model/cwd in effect there.
public struct FileCursor: Codable, Equatable {
    public var offset: Int
    public var size: Int
    public var codexModel: String?
    public var codexCwd: String?
    public var codexSessionId: String?
    public init(offset: Int = 0, size: Int = 0, codexModel: String? = nil,
                codexCwd: String? = nil, codexSessionId: String? = nil) {
        self.offset = offset; self.size = size; self.codexModel = codexModel
        self.codexCwd = codexCwd; self.codexSessionId = codexSessionId
    }
}

public protocol CursorStoring: AnyObject {
    func load() -> [String: FileCursor]
    func save(_ cursors: [String: FileCursor])
}

/// Persists cursors as one JSON blob (small: one entry per recently-touched file).
public final class FileCursorStore: CursorStoring {
    private let url: URL
    public init(url: URL) { self.url = url }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("cc-meter", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-index-cursors.json")
    }

    public func load() -> [String: FileCursor] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: FileCursor].self, from: data)) ?? [:]
    }

    public func save(_ cursors: [String: FileCursor]) {
        guard let data = try? JSONEncoder().encode(cursors) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

public final class InMemoryCursorStore: CursorStoring {
    private var cursors: [String: FileCursor]
    public init(_ initial: [String: FileCursor] = [:]) { self.cursors = initial }
    public func load() -> [String: FileCursor] { cursors }
    public func save(_ cursors: [String: FileCursor]) { self.cursors = cursors }
}

/// Reads only the new bytes of recently-touched Claude and Codex log files each tick and folds
/// them into the store. Runs off the main thread. The store dedups by key, so cursor drift or a
/// re-read is a performance issue, never a correctness one.
public final class UsageIndexer {
    private let fileSystem: FileSystemReading
    private let store: UsageEventStoring
    private let cursors: CursorStoring
    private let claudeProjectsDir: String
    private let codexSessionsDir: String
    private let horizon: TimeInterval
    private let maxBytesPerFilePerTick: Int
    private let now: () -> Date

    public init(fileSystem: FileSystemReading, store: UsageEventStoring, cursors: CursorStoring,
                claudeProjectsDir: String, codexSessionsDir: String,
                horizon: TimeInterval = 8*24*3600, maxBytesPerFilePerTick: Int = 16*1024*1024,
                now: @escaping () -> Date = { Date() }) {
        self.fileSystem = fileSystem
        self.store = store
        self.cursors = cursors
        self.claudeProjectsDir = claudeProjectsDir
        self.codexSessionsDir = codexSessionsDir
        self.horizon = horizon
        self.maxBytesPerFilePerTick = maxBytesPerFilePerTick
        self.now = now
    }

    public static func defaultClaudeProjectsDir() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    }

    public static func defaultCodexSessionsDir() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions")
    }

    public func tick() {
        var state = cursors.load()
        let cutoff = now().addingTimeInterval(-horizon)

        let claude = fileSystem.recursiveFiles(inDirectory: claudeProjectsDir, withSuffix: ".jsonl")
        let codex = fileSystem.recursiveFiles(inDirectory: codexSessionsDir, withSuffix: ".jsonl")

        for entry in (claude + codex) where entry.modified >= cutoff {
            let isCodex = entry.path.hasPrefix(codexSessionsDir)
            var cursor = state[entry.path] ?? FileCursor()
            if entry.size < cursor.offset {
                cursor = FileCursor()   // rotated/truncated: re-read from the top
            }
            guard entry.size > cursor.offset else { state[entry.path] = cursor; continue }

            let length = min(maxBytesPerFilePerTick, entry.size - cursor.offset)
            guard let chunk = fileSystem.read(path: entry.path, fromOffset: cursor.offset, length: length),
                  !chunk.isEmpty else { continue }

            // Only parse up to the last complete line; a partial trailing line is re-read next tick.
            guard let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) else {
                // No newline in the chunk. If the read filled the cap, one line is larger than the
                // cap (e.g. a base64 image pasted into a single JSON record): skip past it so the
                // next tick makes progress - the oversized line is dropped. Otherwise it is a partial
                // trailing line still being written, so leave the cursor and wait for more.
                if length == maxBytesPerFilePerTick {
                    cursor.offset += chunk.count
                    cursor.size = entry.size
                    state[entry.path] = cursor
                }
                continue
            }
            let complete = chunk.prefix(upTo: chunk.index(after: lastNewline))

            if isCodex {
                let seed = CodexParseState(model: cursor.codexModel, cwd: cursor.codexCwd,
                                           sessionId: cursor.codexSessionId)
                let (events, newState) = CodexUsageLogParser.parse(lines: Data(complete), state: seed)
                store.append(events)
                cursor.codexModel = newState.model
                cursor.codexCwd = newState.cwd
                cursor.codexSessionId = newState.sessionId
            } else {
                store.append(ClaudeUsageLogParser.parse(lines: Data(complete)))
            }

            cursor.offset += complete.count
            cursor.size = entry.size
            state[entry.path] = cursor
        }

        cursors.save(state)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter UsageIndexerTests 2>&1 | tail -20`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CCMeterCore/UsageIndexer.swift Tests/CCMeterCoreTests/UsageIndexerTests.swift
git commit -m "feat: incremental cursor-tracked usage indexer"
```

---

### Task 8: `ModelPriceTable` (notional $)

**Files:**
- Create: `Sources/CCMeterCore/ModelPriceTable.swift`
- Test: `Tests/CCMeterCoreTests/ModelPriceTableTests.swift`

**Interfaces:**
- Consumes: `TokenCounts`.
- Produces: `ModelPrice`, `ModelPriceTable` (see Global Interfaces). Prices are USD per single token. Unknown model returns nil so the UI shows no `$` rather than a wrong one.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CCMeterCore

final class ModelPriceTableTests: XCTestCase {
    func testKnownModelCostsSumPerTokenClass() {
        // Opus: $15/M input, $75/M output, $18.75/M cache write, $1.50/M cache read.
        let tokens = TokenCounts(input: 1_000_000, output: 1_000_000,
                                 cacheCreation: 1_000_000, cacheRead: 1_000_000)
        let cost = ModelPriceTable.notionalCost(tokens, model: "claude-opus-4-8")
        XCTAssertNotNil(cost)
        XCTAssertEqual(cost!, 15 + 75 + 18.75 + 1.50, accuracy: 0.0001)
    }

    func testUnknownModelHasNoPrice() {
        XCTAssertNil(ModelPriceTable.price(for: "gpt-5.6-sol"))
        XCTAssertNil(ModelPriceTable.notionalCost(TokenCounts(input: 10), model: "gpt-5.6-sol"))
    }

    func testPricesAsOfIsStamped() {
        XCTAssertFalse(ModelPriceTable.pricesAsOf.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ModelPriceTableTests 2>&1 | tail -20`
Expected: FAIL - `ModelPriceTable` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// USD per single token, by token class.
public struct ModelPrice: Equatable {
    public let input: Double
    public let output: Double
    public let cacheWrite: Double
    public let cacheRead: Double
    public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }
}

/// Embedded, approximate public list prices used only for the "≈ $X on API rates" estimate.
/// These are notional for subscription users. Update the values and `pricesAsOf` when rates change.
/// Codex model names (e.g. gpt-5.6-sol) are intentionally absent - unknown => no dollar figure.
public enum ModelPriceTable {
    public static let pricesAsOf = "2026-07-15"

    private static let perMillion: [(match: String, price: ModelPrice)] = [
        ("opus",   ModelPrice(input: 15.0, output: 75.0, cacheWrite: 18.75, cacheRead: 1.50)),
        ("sonnet", ModelPrice(input: 3.0,  output: 15.0, cacheWrite: 3.75,  cacheRead: 0.30)),
        ("haiku",  ModelPrice(input: 0.80, output: 4.0,  cacheWrite: 1.0,   cacheRead: 0.08)),
    ]

    public static func price(for model: String) -> ModelPrice? {
        let lower = model.lowercased()
        guard let entry = perMillion.first(where: { lower.contains($0.match) }) else { return nil }
        // Convert per-million to per-token.
        let p = entry.price
        return ModelPrice(input: p.input / 1_000_000, output: p.output / 1_000_000,
                          cacheWrite: p.cacheWrite / 1_000_000, cacheRead: p.cacheRead / 1_000_000)
    }

    public static func notionalCost(_ tokens: TokenCounts, model: String) -> Double? {
        guard let p = price(for: model) else { return nil }
        return Double(tokens.input) * p.input
            + Double(tokens.output) * p.output
            + Double(tokens.cacheCreation) * p.cacheWrite
            + Double(tokens.cacheRead) * p.cacheRead
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ModelPriceTableTests 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CCMeterCore/ModelPriceTable.swift Tests/CCMeterCoreTests/ModelPriceTableTests.swift
git commit -m "feat: embedded model price table for notional cost"
```

---

### Task 9: `UsageBreakdown` rollup

**Files:**
- Create: `Sources/CCMeterCore/UsageBreakdown.swift`
- Test: `Tests/CCMeterCoreTests/UsageBreakdownTests.swift`

**Interfaces:**
- Consumes: `UsageEvent`, `UsageProvider`, `ModelPriceTable`.
- Produces: `UsageWindow`, `ProjectUsage`, `ModelUsage`, `UsageBucket`, `UsageBreakdown`, `UsageBreakdownBuilder.build(...)` (see Global Interfaces). Only events for `provider` with `at` in `[windowStart, now]` count. Projects and models are sorted by tokens descending; `share` is a 0...1 fraction of the window total. `buckets` has exactly `window.bucketCount` entries (0 for empty buckets). `notionalCost` is the sum over priced events; nil if no event's model is priced.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CCMeterCore

final class UsageBreakdownTests: XCTestCase {
    private let windowStart = Date(timeIntervalSince1970: 1_000_000)
    private var now: Date { windowStart.addingTimeInterval(5 * 3600) }

    private func event(_ project: String, _ model: String, input: Int, at: Date) -> UsageEvent {
        UsageEvent(provider: .claude, at: at, project: project, model: model,
                   tokens: TokenCounts(input: input), dedupKey: "\(project)-\(model)-\(at.timeIntervalSince1970)")
    }

    func testRollsUpProjectsAndModelsSortedByTokens() {
        let events = [
            event("cc-meter", "claude-opus-4-8", input: 300, at: windowStart.addingTimeInterval(60)),
            event("web", "claude-opus-4-8", input: 100, at: windowStart.addingTimeInterval(120)),
            event("cc-meter", "claude-sonnet", input: 100, at: windowStart.addingTimeInterval(180)),
        ]
        let b = UsageBreakdownBuilder.build(events: events, provider: .claude, window: .fiveHour,
                                            windowStart: windowStart, now: now)
        XCTAssertEqual(b.totalTokens, 500)
        XCTAssertEqual(b.projects.map(\.project), ["cc-meter", "web"])
        XCTAssertEqual(b.projects.map(\.tokens), [400, 100])
        XCTAssertEqual(b.projects[0].share, 0.8, accuracy: 0.0001)
        XCTAssertEqual(b.models.map(\.model), ["claude-opus-4-8", "claude-sonnet"])
        XCTAssertEqual(b.models.map(\.tokens), [400, 100])
    }

    func testExcludesEventsBeforeWindowStartAndOtherProviders() {
        let events = [
            event("cc-meter", "claude-opus-4-8", input: 50, at: windowStart.addingTimeInterval(-10)), // too old
            event("cc-meter", "claude-opus-4-8", input: 70, at: windowStart.addingTimeInterval(60)),
            UsageEvent(provider: .codex, at: windowStart.addingTimeInterval(60), project: "cc-meter",
                       model: "gpt-5.6-sol", tokens: TokenCounts(input: 999), dedupKey: "cx"),
        ]
        let b = UsageBreakdownBuilder.build(events: events, provider: .claude, window: .fiveHour,
                                            windowStart: windowStart, now: now)
        XCTAssertEqual(b.totalTokens, 70)
    }

    func testBucketsSpanTheWindow() {
        let events = [
            event("p", "claude-opus-4-8", input: 10, at: windowStart.addingTimeInterval(30)),        // bucket 0
            event("p", "claude-opus-4-8", input: 20, at: windowStart.addingTimeInterval(2*3600 + 5)), // bucket 2
        ]
        let b = UsageBreakdownBuilder.build(events: events, provider: .claude, window: .fiveHour,
                                            windowStart: windowStart, now: now)
        XCTAssertEqual(b.buckets.count, 5)
        XCTAssertEqual(b.buckets.map(\.tokens), [10, 0, 20, 0, 0])
    }

    func testNotionalCostNilWhenNoModelPriced() {
        let events = [UsageEvent(provider: .codex, at: windowStart.addingTimeInterval(60), project: "p",
                                 model: "gpt-5.6-sol", tokens: TokenCounts(input: 100), dedupKey: "x")]
        let b = UsageBreakdownBuilder.build(events: events, provider: .codex, window: .fiveHour,
                                            windowStart: windowStart, now: now)
        XCTAssertNil(b.notionalCost)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UsageBreakdownTests 2>&1 | tail -20`
Expected: FAIL - types undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public enum UsageWindow: String, CaseIterable, Equatable {
    case fiveHour, sevenDay
    public var length: TimeInterval { self == .fiveHour ? 5 * 3600 : 7 * 24 * 3600 }
    public var bucketCount: Int { self == .fiveHour ? 5 : 7 }
    public var shortLabel: String { self == .fiveHour ? "5h" : "7d" }
}

public struct ProjectUsage: Equatable {
    public let project: String; public let tokens: Int; public let share: Double
    public init(project: String, tokens: Int, share: Double) {
        self.project = project; self.tokens = tokens; self.share = share
    }
}

public struct ModelUsage: Equatable {
    public let model: String; public let tokens: Int; public let share: Double
    public init(model: String, tokens: Int, share: Double) {
        self.model = model; self.tokens = tokens; self.share = share
    }
}

public struct UsageBucket: Equatable {
    public let index: Int; public let tokens: Int
    public init(index: Int, tokens: Int) { self.index = index; self.tokens = tokens }
}

public struct UsageBreakdown: Equatable {
    public let provider: UsageProvider
    public let window: UsageWindow
    public let totalTokens: Int
    public let notionalCost: Double?
    public let projects: [ProjectUsage]
    public let models: [ModelUsage]
    public let buckets: [UsageBucket]
    public init(provider: UsageProvider, window: UsageWindow, totalTokens: Int, notionalCost: Double?,
                projects: [ProjectUsage], models: [ModelUsage], buckets: [UsageBucket]) {
        self.provider = provider; self.window = window; self.totalTokens = totalTokens
        self.notionalCost = notionalCost; self.projects = projects; self.models = models; self.buckets = buckets
    }
}

public enum UsageBreakdownBuilder {
    public static func build(events: [UsageEvent], provider: UsageProvider, window: UsageWindow,
                             windowStart: Date, now: Date) -> UsageBreakdown {
        let inWindow = events.filter {
            $0.provider == provider && $0.at >= windowStart && $0.at <= now
        }
        let total = inWindow.reduce(0) { $0 + $1.tokens.total }

        var projectTokens: [String: Int] = [:]
        var modelTokens: [String: Int] = [:]
        var cost = 0.0
        var anyPriced = false
        for e in inWindow {
            projectTokens[e.project, default: 0] += e.tokens.total
            modelTokens[e.model, default: 0] += e.tokens.total
            if let c = ModelPriceTable.notionalCost(e.tokens, model: e.model) {
                cost += c; anyPriced = true
            }
        }

        let denom = Double(max(total, 1))
        let projects = projectTokens.sorted { $0.value > $1.value }
            .map { ProjectUsage(project: $0.key, tokens: $0.value, share: Double($0.value) / denom) }
        let models = modelTokens.sorted { $0.value > $1.value }
            .map { ModelUsage(model: $0.key, tokens: $0.value, share: Double($0.value) / denom) }

        let bucketSize = window.length / Double(window.bucketCount)
        var bucketTokens = Array(repeating: 0, count: window.bucketCount)
        for e in inWindow {
            let offset = e.at.timeIntervalSince(windowStart)
            let idx = min(window.bucketCount - 1, max(0, Int(offset / bucketSize)))
            bucketTokens[idx] += e.tokens.total
        }
        let buckets = bucketTokens.enumerated().map { UsageBucket(index: $0.offset, tokens: $0.element) }

        return UsageBreakdown(provider: provider, window: window, totalTokens: total,
                              notionalCost: anyPriced ? cost : nil,
                              projects: projects, models: models, buckets: buckets)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter UsageBreakdownTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CCMeterCore/UsageBreakdown.swift Tests/CCMeterCoreTests/UsageBreakdownTests.swift
git commit -m "feat: usage breakdown rollup by project, model, and time bucket"
```

---

### Task 10: `UsageDetailViewModel`

**Files:**
- Create: `Sources/CCMeterCore/UsageDetailViewModel.swift`
- Test: `Tests/CCMeterCoreTests/UsageDetailViewModelTests.swift`

**Interfaces:**
- Consumes: `UsageEventStoring`, `UsageBreakdownBuilder`, `UsageWindow`, `UsageProvider`, `UsageBreakdown`.
- Produces: `UsageDetailViewModel` (see Global Interfaces). `resetsAt(provider, window)` returns the live reset time so `windowStart = resetsAt - window.length`; if nil, falls back to `now - window.length`. Changing `provider` or `window` recomputes. `onAppear()` triggers `indexerTick()` (background) then recomputes.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UsageDetailViewModelTests 2>&1 | tail -20`
Expected: FAIL - `UsageDetailViewModel` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
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
```

Note: `indexerTick` is synchronous (the live app passes `{ indexer.tick() }`); the view-model dispatches it on its own utility queue in `refreshInBackground`, so nothing runs the file enumeration on the main thread. `recompute()` alone is cheap and main-safe.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter UsageDetailViewModelTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CCMeterCore/UsageDetailViewModel.swift Tests/CCMeterCoreTests/UsageDetailViewModelTests.swift
git commit -m "feat: usage detail view-model bounded by live reset window"
```

---

### Task 11: `usageBreakdownEnabled` preference

**Files:**
- Modify: `Sources/CCMeterCore/Preferences.swift` (add field, CodingKeys, lenient decode)
- Test: `Tests/CCMeterCoreTests/PreferencesTests.swift` (add cases)

**Interfaces:**
- Produces: `Preferences.usageBreakdownEnabled: Bool` (default `true`).

- [ ] **Step 1: Write the failing test** (append these methods to `PreferencesTests`)

```swift
    func testUsageBreakdownEnabledDefaultsTrue() {
        XCTAssertTrue(Preferences().usageBreakdownEnabled)
    }

    func testUsageBreakdownEnabledAbsentDecodesToDefault() throws {
        let json = "{\"pollInterval\":180}".data(using: .utf8)!
        let prefs = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertTrue(prefs.usageBreakdownEnabled)
    }

    func testUsageBreakdownEnabledRoundTrips() throws {
        var prefs = Preferences()
        prefs.usageBreakdownEnabled = false
        let data = try JSONEncoder().encode(prefs)
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: data).usageBreakdownEnabled)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PreferencesTests 2>&1 | tail -20`
Expected: FAIL - `usageBreakdownEnabled` undefined.

- [ ] **Step 3: Modify `Preferences.swift`** (four edits)

Add the stored property after `automaticUpdatesEnabled` (around line 21):
```swift
    /// Whether the Usage tab parses local Claude/Codex logs for the token breakdown.
    public var usageBreakdownEnabled: Bool
```

Add the initializer parameter and assignment (in `init`, around lines 34 and 42):
```swift
                automaticUpdatesEnabled: Bool = true,
                usageBreakdownEnabled: Bool = true) {
```
```swift
        self.automaticUpdatesEnabled = automaticUpdatesEnabled
        self.usageBreakdownEnabled = usageBreakdownEnabled
```

Add to `CodingKeys` (around line 48):
```swift
        case automaticUpdatesEnabled, usageBreakdownEnabled
```

Add to the lenient decoder (in `init(from:)`, after the `automaticUpdatesEnabled` line):
```swift
        usageBreakdownEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .usageBreakdownEnabled) ?? d.usageBreakdownEnabled
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PreferencesTests 2>&1 | tail -20`
Expected: PASS (all PreferencesTests including 3 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/CCMeterCore/Preferences.swift Tests/CCMeterCoreTests/PreferencesTests.swift
git commit -m "feat: add usageBreakdownEnabled preference (default on)"
```

---

### Task 12: `UsageTabView` and the Limits/Usage segmented tab

**Files:**
- Create: `Sources/cc-meter/UsageTabView.swift`
- Modify: `Sources/cc-meter/PopoverView.swift` (add a tab picker; render `UsageTabView` for the Usage tab)

**Interfaces:**
- Consumes: `UsageDetailViewModel`, `UsageBreakdown`, `UsageWindow`, `UsageProvider`, `ModelPriceTable`.
- This is view code; logic already lives in the tested view-model. Verified by build + launch, not a unit test.

- [ ] **Step 1: Create `UsageTabView.swift`**

```swift
import SwiftUI
import CCMeterCore

/// The Usage tab: tokens consumed in the current window, by project and model, with a small
/// hand-drawn bar chart and a notional dollar estimate. Provider- and window-scoped.
struct UsageTabView: View {
    @ObservedObject var model: UsageDetailViewModel
    let showsCodex: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            if !model.logsPresent(model.provider) {
                Text("No \(model.provider.displayName) usage logs found.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !model.hasIndexed {
                Text("Reading usage logs…").font(.caption).foregroundStyle(.secondary)
            } else if let b = model.breakdown {
                chart(b)
                if b.totalTokens == 0 {
                    Text("No usage recorded in this window yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    projectTable(b)
                    modelSplit(b)
                    costLine(b)
                }
            }
        }
        .onAppear { model.onAppear() }
    }

    private var controls: some View {
        HStack {
            if showsCodex {
                Picker("", selection: $model.provider) {
                    Text("Claude").tag(UsageProvider.claude)
                    Text("Codex").tag(UsageProvider.codex)
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            Spacer()
            Picker("", selection: $model.window) {
                Text("5h").tag(UsageWindow.fiveHour)
                Text("7d").tag(UsageWindow.sevenDay)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private func chart(_ b: UsageBreakdown) -> some View {
        let peak = max(1, b.buckets.map(\.tokens).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(b.buckets, id: \.index) { bucket in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: .systemBlue).opacity(0.55))
                    .frame(height: max(2, 34 * CGFloat(bucket.tokens) / CGFloat(peak)))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 34)
        .accessibilityLabel("\(Self.compact(b.totalTokens)) tokens this window")
    }

    private func projectTable(_ b: UsageBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(b.projects.prefix(5), id: \.project) { row in
                HStack {
                    Text(row.project).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Self.compact(row.tokens)).font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("\(Int((row.share * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    private func modelSplit(_ b: UsageBreakdown) -> some View {
        HStack(spacing: 8) {
            ForEach(b.models.prefix(3), id: \.model) { m in
                Text("\(shortModelToken(m.model)) \(Int((m.share * 100).rounded()))%")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func costLine(_ b: UsageBreakdown) -> some View {
        Text(b.notionalCost.map { "≈ \(Self.money($0)) on API rates" } ?? "≈ cost n/a (unpriced model)")
            .font(.caption2).foregroundStyle(.tertiary)
            .help("Estimate at public API prices as of \(ModelPriceTable.pricesAsOf). Notional on a subscription; token share approximates quota share. Unpriced models (e.g. Codex) show n/a.")
    }

    private static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private static func money(_ amount: Double) -> String { String(format: "$%.2f", amount) }
}
```

- [ ] **Step 2: Modify `PopoverView.swift` to add the tab**

Add the usage view-model property **between `dashboard` and `onOpenSettings`**. Declaration order sets the synthesized memberwise-init label order, and Task 14 constructs it as `PopoverView(dashboard:usageModel:onOpenSettings:)` - Swift forbids passing labeled args out of declaration order, so `usageModel` MUST come before `onOpenSettings`. Place immediately after `@ObservedObject var dashboard: DashboardViewModel` (around line 11):
```swift
    var usageModel: UsageDetailViewModel? = nil
```
Then add the tab state and enum immediately after `var onOpenSettings: () -> Void = {}`:
```swift
    @State private var tab: Tab = .limits
    private enum Tab { case limits, usage }
```
(The existing `PopoverView(dashboard:onOpenSettings:)` site in `MenuBarController` still compiles because `usageModel` keeps its `= nil` default.)

Replace the `header` computed property's `HStack` content so the title area hosts a Limits/Usage picker when a usage model is present. Change `header` (lines 52-67) to:
```swift
    private var header: some View {
        HStack {
            if usageModel != nil {
                Picker("", selection: $tab) {
                    Text("Limits").tag(Tab.limits)
                    Text("Usage").tag(Tab.usage)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            } else {
                Text("Usage").font(.headline)
            }
            Spacer()
            if tab == .limits {
                Picker("", selection: modeBinding) {
                    Text("Used").tag(DisplayMode.used)
                    Text("Left").tag(DisplayMode.remaining)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().help("Show used or remaining")
            }
        }
    }
```

In `body` (lines 23-50), swap the middle (alert + ScrollView) for a tab switch. Replace the block between `header` and `footer` with:
```swift
            if tab == .usage, let usageModel {
                UsageTabView(model: usageModel, showsCodex: dashboard.showsCodex)
            } else {
                if let alert = dashboard.alert { alertView(alert) }
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        providerBlock(provider: .claude, viewModel: dashboard.claude)
                        if dashboard.showsCodex {
                            providerBlock(provider: .codex, viewModel: dashboard.codex)
                        }
                    }
                }
                .frame(maxHeight: Metrics.maxListHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds (no errors). Warnings acceptable.

- [ ] **Step 4: Verify the existing tests still pass**

Run: `swift test 2>&1 | tail -15`
Expected: All tests pass (the app-target UI change does not break CCMeterCore tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/cc-meter/UsageTabView.swift Sources/cc-meter/PopoverView.swift
git commit -m "feat: Usage tab in the popover with project/model breakdown chart"
```

---

### Task 13: Settings toggle for the Usage breakdown

**Files:**
- Modify: `Sources/cc-meter/SettingsView.swift` (add a toggle to the Display card)

**Interfaces:**
- Consumes: `Preferences.usageBreakdownEnabled` (Task 11).
- View code; verified by build. The toggle is bound to `$prefs.usageBreakdownEnabled`, and `SettingsView`'s existing `onChange(of: prefs)` already propagates the whole value up.

- [ ] **Step 1: Add the toggle** in the `Display` card (inside `card("Display")`, after the history toggle, around line 86):
```swift
                    Toggle("Show usage & cost breakdown (reads local logs)",
                           isOn: $prefs.usageBreakdownEnabled)
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/cc-meter/SettingsView.swift
git commit -m "feat: settings toggle for usage & cost breakdown"
```

---

### Task 14: Wire the indexer, store, and view-model in `AppDelegate`

**Files:**
- Modify: `Sources/cc-meter/AppDelegate.swift` (construct the store/indexer/view-model; schedule background ticks; gate on the preference; pass the view-model to `MenuBarController`/`PopoverView`)
- Modify: `Sources/cc-meter/MenuBarController.swift` (accept and forward an optional `UsageDetailViewModel` to `PopoverView`)

**Interfaces:**
- Consumes: everything from Tasks 1-11. `resetsAt(provider, window)` reads the live limit from the corresponding `MeterViewModel.state`.
- Verified by build + launch (Task 15). No unit test (glue), consistent with the existing Timer-based wiring in `MeterViewModel`.

- [ ] **Step 1: Add a reset-time helper** to `AppDelegate` (a private static func near `makeAutoUpdateController`):
```swift
    /// Live reset time for a provider's window, read from its meter, so the Usage tab's window
    /// lines up with the Limits tab. 5h -> the session window; 7d -> the first weekly window.
    static func resetsAt(_ dashboard: DashboardViewModel,
                         provider: UsageProvider, window: UsageWindow) -> Date? {
        let meter = provider == .claude ? dashboard.claude : dashboard.codex
        guard case .ok(let usage) = meter.state else { return nil }
        switch window {
        case .fiveHour:
            return usage.limits.first(where: { $0.kind.isSessionWindow })?.resetsAt
        case .sevenDay:
            return usage.limits.first(where: { !$0.kind.isSessionWindow })?.resetsAt
        }
    }
```

- [ ] **Step 2: Construct the store, indexer, and view-model** in `applicationDidFinishLaunching`, after `self.dashboard = dashboard` (around line 95), gated on the preference:
```swift
        var usageModel: UsageDetailViewModel?
        if preferences.usageBreakdownEnabled {
            let claudeDir = UsageIndexer.defaultClaudeProjectsDir()
            let codexDir = UsageIndexer.defaultCodexSessionsDir()
            let eventStore = FileUsageEventStore(url: FileUsageEventStore.defaultURL())
            let indexer = UsageIndexer(
                fileSystem: SystemFileSystem(),
                store: eventStore,
                cursors: FileCursorStore(url: FileCursorStore.defaultURL()),
                claudeProjectsDir: claudeDir,
                codexSessionsDir: codexDir)
            self.usageIndexer = indexer

            let model = UsageDetailViewModel(
                store: eventStore,
                resetsAt: { [weak dashboard] provider, window in
                    guard let dashboard else { return nil }
                    return Self.resetsAt(dashboard, provider: provider, window: window)
                },
                indexerTick: { indexer.tick() },   // synchronous; the view-model runs it off-main
                logsPresent: { provider in
                    FileManager.default.fileExists(atPath: provider == .claude ? claudeDir : codexDir)
                })
            usageModel = model
            self.usageModel = model

            // First index build (off-main; flips hasIndexed when done) + periodic refresh.
            // refreshInBackground never blocks the main thread (the #16 lesson).
            model.refreshInBackground()
            let timer = Timer.scheduledTimer(withTimeInterval: preferences.pollInterval, repeats: true) { _ in
                Task { @MainActor in model.refreshInBackground() }
            }
            self.usageIndexTimer = timer
        }
```

Add the stored properties near the top of `AppDelegate` (after `private var dashboard`):
```swift
    private var usageModel: UsageDetailViewModel?
    private var usageIndexer: UsageIndexer?
    private var usageIndexTimer: Timer?
```

- [ ] **Step 3: Pass the view-model to the menu bar** - change the `MenuBarController` construction (around line 110) to include it:
```swift
        let controller = MenuBarController(dashboard: dashboard, usageModel: usageModel) { [weak self] in
            self?.settingsWindow?.show()
        }
```

- [ ] **Step 4: Thread the view-model through `MenuBarController`** into `PopoverView`. Open `Sources/cc-meter/MenuBarController.swift`, add a stored `private let usageModel: UsageDetailViewModel?`, accept it in `init` (default `nil`), and pass it to `PopoverView(dashboard:usageModel:onOpenSettings:)` wherever `PopoverView` is constructed. (Read the file first; mirror how `dashboard` is already stored and forwarded.)

- [ ] **Step 4b: Make the runtime toggle stop the indexer**

In `applyPreferences` (`AppDelegate.swift:122`), stop the index timer when the feature is turned off at runtime so the indexer goes idle immediately. (The Usage tab itself is shown/hidden based on whether `usageModel` was built at launch, so its visibility updates on the next launch - acceptable for v1; the spec's "Off => indexer idle" is honored live, tab-hide is relaunch-gated.)
```swift
        if !preferences.usageBreakdownEnabled {
            usageIndexTimer?.invalidate()
            usageIndexTimer = nil
        }
```

- [ ] **Step 5: Build**

Run: `swift build 2>&1 | tail -25`
Expected: Build succeeds. If `PopoverView` is constructed with a positional/labeled initializer, ensure `usageModel:` is supplied there.

- [ ] **Step 6: Run the full suite**

Run: `swift test 2>&1 | tail -15`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/cc-meter/AppDelegate.swift Sources/cc-meter/MenuBarController.swift
git commit -m "feat: wire usage indexer, store, and view-model into the app"
```

---

### Task 15: End-to-end verification against real logs

**Files:** none (verification only)

**Interfaces:** exercises the whole feature against the user's real `~/.claude` and `~/.codex` logs.

- [ ] **Step 1: Build and run the app**

Run: `swift build 2>&1 | tail -5 && swift run cc-meter &` (or launch the built binary). Give it a few seconds to index.

- [ ] **Step 2: Open the popover, switch to the Usage tab**

Confirm: the "Limits | Usage" segmented control appears; selecting Usage shows a bar chart, a project table with real project names (e.g. `cc-meter`, `web`), a model split, and (for Claude) a "≈ $X on API rates" line. Switch 5h/7d and Claude/Codex.

- [ ] **Step 3: Sanity-check the numbers**

Run a quick reference count and compare orders of magnitude (not exact - the app dedups and window-bounds):
```bash
python3 - <<'PY'
import json, glob, os, time
from datetime import datetime, timezone
cutoff = time.time() - 5*3600
tot = 0
for f in glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl')):
    if os.path.getmtime(f) < time.time()-8*24*3600: continue
    with open(f) as fh:
        for line in fh:
            try: r = json.loads(line)
            except: continue
            m = r.get('message') or {}
            u = m.get('usage')
            if r.get('type')=='assistant' and u and m.get('model')!='<synthetic>':
                ts = r.get('timestamp','')
                try: t = datetime.fromisoformat(ts.replace('Z','+00:00')).timestamp()
                except: continue
                if t >= cutoff:
                    tot += u.get('input_tokens',0)+u.get('output_tokens',0)+u.get('cache_creation_input_tokens',0)+u.get('cache_read_input_tokens',0)
print("rough Claude tokens (last 5h, NOT deduped):", tot)
PY
```
Expected: the app's 5h Claude total is in the same ballpark (the app is lower after dedup and exact window bounding). Confirm it is non-zero and not wildly larger than this reference.

- [ ] **Step 4: Verify the settings toggle hides the feature**

Open Settings, turn off "Show usage & cost breakdown", quit and relaunch. Confirm the Usage tab no longer appears and the app behaves exactly as before. Turn it back on.

- [ ] **Step 5: Kill the app and commit any final tweaks**

```bash
pkill -f "cc-meter" 2>/dev/null || true
```
If Steps 1-4 surfaced a fix, make it as a focused commit. Otherwise this task is verification-only.

---

## Self-Review

**Spec coverage** (each spec section maps to a task):
- Tokens-first metric + notional $ secondary -> Tasks 8 (pricing), 9 (breakdown), 12 (cost line, secondary).
- Rate-limit window alignment (5h/7d) -> Task 9 (`UsageWindow`), Task 10 (`resetsAt` -> windowStart), Task 14 (live reset lookup).
- Per-project + per-model breakdowns -> Task 9, rendered in Task 12.
- Limits/Usage popover tab -> Task 12.
- Tokens-over-window chart -> Task 9 (buckets) + Task 12 (bars).
- Hybrid incremental index -> Tasks 6 (store), 7 (indexer), 14 (scheduling).
- Claude data source + dedup + `<synthetic>` skip -> Task 4, dedup enforced in Task 6/7.
- Codex data source + `last_token_usage` deltas + turn_context model + session_meta cwd -> Task 5.
- Worktree normalization -> Task 3.
- Scope boundary (feeds only the Usage tab) -> Tasks 12/14 touch nothing in the menu-bar title, forecast, or notifications.
- Settings toggle (default on) -> Tasks 11 + 13.
- Error handling: absent logs (Task 10 `logsPresent` + Task 14 `FileManager.fileExists` -> Task 12 "No usage logs found" copy), first-launch progress (Task 10 `hasIndexed` -> Task 12 "Reading usage logs…"), partial trailing line (Task 7 last-newline + Task 7 test), oversized-single-line stall (Task 7 cap-hit branch), overcount (Task 5 deltas, reasoning excluded from total), Codex sessionId dedup stability (Tasks 5/7 carried state), Claude ~2x dedup (Task 6), price staleness/unpriced model n/a (Tasks 8/12), main-thread safety (Task 10 off-main index; Task 6 store lock).
- Testing matches the spec's list -> Tasks 1-11 each ship the named tests.

**Placeholder scan:** No TBD/TODO; every code step shows complete code. Task 14 Step 4 asks the implementer to read `MenuBarController.swift` and mirror an existing pattern rather than pasting code, because that file was not read during planning - this is a deliberate "follow the existing pattern" instruction, not a placeholder.

**Type consistency:** `UsageEventStoring.events(since:)`, `UsageBreakdownBuilder.build(events:provider:window:windowStart:now:)`, `UsageDetailViewModel(store:resetsAt:indexerTick:now:)`, `UsageWindow.length/bucketCount/shortLabel`, and `TokenCounts` field names are used identically across Tasks 6-14 and match the Global Interfaces block.

**Deferred (not in this plan, per spec):** per-session breakdown, calendar/trend view, driving menu-bar/notifications from tokens, model-weighted quota share, full worktree->parent mapping, the CLI companion.
