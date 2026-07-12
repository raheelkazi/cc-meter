# Codex Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automatically detected Codex rate-limit meters beside the existing Claude Code meters without exposing Codex credentials or coupling provider failures.

**Architecture:** Keep one `MeterViewModel` per provider and add a dashboard model that aggregates them for the menu bar and popover. Fetch Codex limits through a short-lived `codex app-server --stdio` process using the stable `account/rateLimits/read` RPC, with decoding and process transport isolated behind testable interfaces.

**Tech Stack:** Swift 5.9, Foundation, Combine, SwiftUI, AppKit, XCTest, Swift Package Manager.

## Global Constraints

- Retain macOS 13 and Swift tools 5.9 compatibility.
- Add no third-party Swift dependencies.
- Preserve the existing Claude cache and history locations and Claude-only behavior.
- Never read, display, persist, modify, or log Codex OAuth tokens.
- Codex absence or signed-out state stays hidden; one provider's failure never blanks the other.
- Use test-first red/green cycles for every behavior change.

## File Structure

- Create `Sources/CCMeterCore/Provider.swift`: stable provider identity and display metadata.
- Create `Sources/CCMeterCore/CodexUsageResponse.swift`: app-server response types and deterministic rate-limit mapping.
- Create `Sources/CCMeterCore/CodexUsageClient.swift`: request construction, executable resolution, process transport interface, and error mapping.
- Create `Sources/CCMeterCore/DashboardViewModel.swift`: dual-meter visibility, aggregation, and action fan-out.
- Modify `Sources/CCMeterCore/Models.swift`: dynamic Codex window labels and Codex-specific error cases.
- Modify `Sources/CCMeterCore/MeterViewModel.swift`: provider metadata and provider-scoped history/notifications.
- Modify `Sources/CCMeterCore/UsageHistory.swift`: provider-scoped sample identity with backward-compatible decoding.
- Modify `Sources/CCMeterCore/UsageStore.swift`: provider-specific standard cache URLs while preserving Claude's filename.
- Modify `Sources/CCMeterCore/Notifications.swift`: provider-scoped IDs and provider-qualified copy.
- Create `Sources/cc-meter/CodexAppServerProcess.swift`: bounded `Process`-based JSONL exchange.
- Modify `Sources/cc-meter/AppDelegate.swift`: build both meters and the dashboard.
- Modify `Sources/cc-meter/MenuBarController.swift`: observe dashboard aggregation.
- Modify `Sources/cc-meter/PopoverView.swift`: reusable provider section and shared dashboard controls.
- Create matching focused XCTest files and update README documentation.

---

### Task 1: Provider-Aware Core Identity, Storage, and Notifications

**Files:**
- Create: `Sources/CCMeterCore/Provider.swift`
- Modify: `Sources/CCMeterCore/Models.swift`
- Modify: `Sources/CCMeterCore/MeterViewModel.swift`
- Modify: `Sources/CCMeterCore/UsageHistory.swift`
- Modify: `Sources/CCMeterCore/UsageStore.swift`
- Modify: `Sources/CCMeterCore/Notifications.swift`
- Create: `Tests/CCMeterCoreTests/ProviderTests.swift`
- Modify: `Tests/CCMeterCoreTests/UsageHistoryTests.swift`
- Modify: `Tests/CCMeterCoreTests/UsageStoreTests.swift`
- Modify: `Tests/CCMeterCoreTests/NotificationsTests.swift`

**Interfaces:**
- Produces: `UsageProvider`, `WindowKind.named(label:isSession:)`, `WindowKind.isSessionWindow`, provider-aware `MeterViewModel.init`, `DiskUsageStore.standard(provider:)`, and provider-aware history/notification APIs.
- Consumes: Existing `Usage`, `UsageLimit`, `HistoryStoring`, `ThresholdNotifier`, and `Preferences` behavior.

- [ ] **Step 1: Write failing provider/model tests**

```swift
func testProviderDisplayNamesAreStable() {
    XCTAssertEqual(UsageProvider.claude.displayName, "Claude Code")
    XCTAssertEqual(UsageProvider.codex.displayName, "Codex")
}

func testNamedWindowPreservesLabelAndSessionMeaning() {
    let kind = WindowKind.named(label: "5-hour", isSession: true)
    XCTAssertEqual(kind.label, "5-hour")
    XCTAssertTrue(kind.isSessionWindow)
}

func testCodexStandardCacheDoesNotReplaceClaudeCache() {
    XCTAssertTrue(DiskUsageStore.standard(provider: .claude).fileURL.path.hasSuffix("last-usage.json"))
    XCTAssertTrue(DiskUsageStore.standard(provider: .codex).fileURL.path.hasSuffix("last-usage-codex.json"))
}
```

Add history coverage that new samples retain `.codex`, old JSON without a provider decodes as `.claude`, and `recent(provider:kindLabel:since:)` does not mix providers. Add notification coverage asserting an event ID starts with `codex#` and its title/body name Codex.

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter 'ProviderTests|UsageHistoryTests|UsageStoreTests|NotificationsTests'`

Expected: compilation failures because the provider types and provider-aware APIs do not exist.

- [ ] **Step 3: Implement the minimal provider-aware core**

```swift
public enum UsageProvider: String, Codable, CaseIterable, Equatable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}
```

Add `WindowKind.named(label:isSession:)`, return its supplied label, and expose `isSessionWindow`. Add `provider` to `MeterViewModel` with default `.claude`; pass it into history recording/lookups and notification evaluation. Add provider to `HistorySample` with custom decoding defaulting missing values to `.claude`. Change history APIs to:

```swift
func record(_ usage: Usage, provider: UsageProvider)
func recent(provider: UsageProvider, kindLabel: String, since: Date) -> [HistorySample]
```

Preserve source compatibility with extension helpers defaulting to `.claude`. Add `DiskUsageStore.standard(provider:)` so Claude retains `last-usage.json` and Codex uses `last-usage-codex.json`; make `fileURL` public for deterministic tests. Change notifier evaluation to accept `provider: UsageProvider = .claude`, prefix internal keys/IDs with `provider.rawValue`, use `isSessionWindow`, and qualify notification copy with `provider.displayName`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `swift test --filter 'ProviderTests|UsageHistoryTests|UsageStoreTests|NotificationsTests'`

Expected: all selected tests pass.

- [ ] **Step 5: Run all tests and commit**

Run: `swift test`

Expected: the full existing suite passes.

```bash
git add Sources/CCMeterCore Tests/CCMeterCoreTests
git commit -m "feat: scope meter data by provider"
```

### Task 2: Codex Rate-Limit Response Mapping

**Files:**
- Create: `Sources/CCMeterCore/CodexUsageResponse.swift`
- Create: `Tests/CCMeterCoreTests/CodexUsageResponseTests.swift`
- Modify: `Tests/CCMeterCoreTests/Fixtures.swift`

**Interfaces:**
- Produces: `CodexRateLimitsResponse.toUsage(now:) throws -> Usage` and `CodexProtocolError` decoding.
- Consumes: `Usage`, `UsageLimit`, and `WindowKind.named(label:isSession:)` from Task 1.

- [ ] **Step 1: Add failing response fixtures and mapping tests**

Use fixtures containing top-level `rateLimits`, a non-empty `rateLimitsByLimitId`, unrelated notification JSON, and RPC errors. Assert:

```swift
let response = try JSONDecoder().decode(CodexRateLimitsResponse.self,
                                        from: Fixtures.codexMultiLimitJSON)
let usage = try response.toUsage(now: now)
XCTAssertEqual(usage.limits.map(\.kind.label), [
    "5-hour", "7-day", "7-day (GPT-5.3-Codex-Spark)"
])
XCTAssertEqual(usage.limits.map(\.percent), [25, 40, 10])
```

Also assert the dictionary prevents duplicate top-level rows, durations map to `1-day`/`90-minute`, reset timestamps use Unix seconds, nil windows are ignored, empty success returns zero limits, and duplicate display labels gain a stable limit-ID suffix.

- [ ] **Step 2: Run the mapping tests and verify RED**

Run: `swift test --filter CodexUsageResponseTests`

Expected: compilation failure because `CodexRateLimitsResponse` does not exist.

- [ ] **Step 3: Implement strict RPC decoding and deterministic mapping**

Define Decodable wire types for `id`, `result`, `error`, `rateLimits`, `rateLimitsByLimitId`, `limitId`, `limitName`, `primary`, `secondary`, `usedPercent`, `windowDurationMins`, and `resetsAt`. Sort dictionary keys, prefer a non-empty dictionary, calculate labels from exact week/day/hour divisibility, mark 300-minute windows as session windows, disambiguate duplicates, and set every returned Codex limit active.

```swift
public func toUsage(now: Date) throws -> Usage {
    if let error { throw error }
    guard let result else { throw CodexResponseError.missingResult }
    let groups = result.orderedRateLimits
    return Usage(limits: Self.map(groups), fetchedAt: now)
}
```

- [ ] **Step 4: Run mapping tests and verify GREEN**

Run: `swift test --filter CodexUsageResponseTests`

Expected: all mapping tests pass.

- [ ] **Step 5: Run all tests and commit**

Run: `swift test`

Expected: full suite passes.

```bash
git add Sources/CCMeterCore/CodexUsageResponse.swift Tests/CCMeterCoreTests
git commit -m "feat: decode Codex rate limits"
```

### Task 3: Codex App-Server Client and Process Boundary

**Files:**
- Create: `Sources/CCMeterCore/CodexUsageClient.swift`
- Create: `Sources/cc-meter/CodexAppServerProcess.swift`
- Create: `Tests/CCMeterCoreTests/CodexUsageClientTests.swift`

**Interfaces:**
- Produces: `CodexExecutableResolving`, `CodexAppServerTransport`, `CodexUsageClient`, `CodexTransportError`, and production `CodexAppServerProcess`.
- Consumes: `CodexRateLimitsResponse.toUsage(now:)` from Task 2 and existing `UsageFetching`.

- [ ] **Step 1: Write failing executable, request, and error-mapping tests**

Create fakes that capture executable URL, JSONL input, response ID, and timeout. Assert the input consists of initialize, initialized, and `account/rateLimits/read` messages; the client requests response ID `2`; missing executable maps to `.noCredentials`; authentication RPC errors map to `.unauthorized`; launch/timeout/EOF/overload map to `.network`; and method-not-found maps to a `.badResponse` message containing `update Codex`.

- [ ] **Step 2: Run client tests and verify RED**

Run: `swift test --filter CodexUsageClientTests`

Expected: compilation failure because the client interfaces do not exist.

- [ ] **Step 3: Implement the core client and resolver**

```swift
public protocol CodexExecutableResolving {
    func resolve() -> URL?
}

public protocol CodexAppServerTransport {
    func exchange(executable: URL, input: Data,
                  responseID: Int, timeout: TimeInterval) async throws -> Data
}

public struct CodexUsageClient: UsageFetching {
    public func fetch() async -> Result<Usage, UsageError> {
        guard let executable = resolver.resolve() else { return .failure(.noCredentials) }
        do {
            let data = try await transport.exchange(executable: executable,
                                                    input: requestData,
                                                    responseID: 2,
                                                    timeout: timeout)
            return .success(try JSONDecoder().decode(CodexRateLimitsResponse.self,
                                                     from: data).toUsage(now: now()))
        } catch {
            return .failure(map(error))
        }
    }
}
```

The production resolver checks the approved candidate order and validates executability. It uses injected candidates in tests.

- [ ] **Step 4: Run client tests and verify GREEN**

Run: `swift test --filter CodexUsageClientTests`

Expected: all client tests pass.

- [ ] **Step 5: Implement the production subprocess exchange**

Use `Process`, stdin/stdout/stderr `Pipe`s, `FileHandle.readabilityHandler`, and a one-shot timeout work item. Buffer stdout by newline; ignore lines that are not JSON objects with the requested integer `id`; resume exactly once under a lock; terminate the child and clear handlers after success or failure. Drain stderr into a capped 4 KiB buffer and sanitize bearer-token-like text before including diagnostics. Map nonzero exit before a matching response to premature EOF.

- [ ] **Step 6: Build the executable target and commit**

Run: `swift build && swift test`

Expected: build succeeds and the full test suite passes.

```bash
git add Sources/CCMeterCore/CodexUsageClient.swift Sources/cc-meter/CodexAppServerProcess.swift Tests/CCMeterCoreTests/CodexUsageClientTests.swift
git commit -m "feat: fetch limits through Codex app server"
```

### Task 4: Dual-Provider Dashboard Model

**Files:**
- Create: `Sources/CCMeterCore/DashboardViewModel.swift`
- Create: `Tests/CCMeterCoreTests/DashboardViewModelTests.swift`
- Modify: `Tests/CCMeterCoreTests/MeterViewModelTests.swift`

**Interfaces:**
- Produces: `DashboardViewModel` with `claude`, `codex`, `showsCodex`, `compact`, `isLoading`, `hasError`, `start()`, `refreshNow()`, `toggleMode()`, and `apply(_:)`.
- Consumes: two provider-configured `MeterViewModel` instances.

- [ ] **Step 1: Write failing aggregation and visibility tests**

Assert Codex starts hidden, becomes visible after success, hides for `.noCredentials`/`.unauthorized`, stays visible with stale data after a transient failure, and a malformed response is visible only after prior detection. Assert compact picks the higher used percentage, Claude errors do not override valid Codex compact data, and toggle/preferences/refresh fan out to both meters.

- [ ] **Step 2: Run dashboard tests and verify RED**

Run: `swift test --filter DashboardViewModelTests`

Expected: compilation failure because `DashboardViewModel` does not exist.

- [ ] **Step 3: Implement minimal Combine-based aggregation**

```swift
@MainActor
public final class DashboardViewModel: ObservableObject {
    public let claude: MeterViewModel
    public let codex: MeterViewModel
    @Published public private(set) var showsCodex = false

    public var compact: (percent: Int, color: MeterColor)? {
        [claude.compact, showsCodex ? codex.compact : nil]
            .compactMap { $0 }
            .max { $0.percent < $1.percent }
    }
}
```

Subscribe to Codex's published state to reconcile visibility and to both child `objectWillChange` publishers to relay dashboard changes. Fan out actions without sharing provider state.

- [ ] **Step 4: Run dashboard and full tests, then commit**

Run: `swift test --filter DashboardViewModelTests && swift test`

Expected: dashboard tests and full suite pass.

```bash
git add Sources/CCMeterCore/DashboardViewModel.swift Tests/CCMeterCoreTests
git commit -m "feat: aggregate Claude and Codex meters"
```

### Task 5: App Wiring and Dual-Provider Popover

**Files:**
- Modify: `Sources/cc-meter/AppDelegate.swift`
- Modify: `Sources/cc-meter/MenuBarController.swift`
- Modify: `Sources/cc-meter/PopoverView.swift`
- Modify: `Sources/cc-meter/NotificationClient.swift` only if provider-qualified content requires no platform change.

**Interfaces:**
- Consumes: `DashboardViewModel`, `CodexUsageClient`, `CodexAppServerProcess`, provider-specific cache/history paths.
- Produces: a running macOS app with both provider sections and one set of shared controls.

- [ ] **Step 1: Wire both meters in AppDelegate**

Keep the existing Claude client unchanged. Build a Codex client with the production resolver/process transport, a Codex `MeterViewModel` with separate cache/history, then construct `DashboardViewModel(claude:codex:)`. Store and pass the dashboard everywhere the single meter was previously used. Apply settings and start through the dashboard.

- [ ] **Step 2: Update menu-bar aggregation**

Change `MenuBarController` to observe `DashboardViewModel`. Preserve `CC ...`, `CC !`, and colored percentage rendering, but return the dashboard compact percentage whenever either visible provider has valid data.

- [ ] **Step 3: Refactor PopoverView into provider sections**

Use a shared top header `Usage`, one Used/Left toggle bound to dashboard fan-out, explicit Claude and conditional Codex sections, provider-local stale/error/hero/rows/spend/updated cues, and one footer with Refresh/Settings/Quit. Parameterize authentication copy: Claude says run `claude`; Codex says open Codex or run `codex login`.

- [ ] **Step 4: Build and run all tests**

Run: `swift build && swift test`

Expected: the app target builds and all unit tests pass.

- [ ] **Step 5: Commit UI wiring**

```bash
git add Sources/cc-meter
git commit -m "feat: show Claude and Codex usage together"
```

### Task 6: Documentation and End-to-End Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/plans/2026-07-12-codex-support.md` only to check completed boxes during execution.

**Interfaces:**
- Consumes: the completed dual-provider implementation.
- Produces: user-facing installation/behavior documentation and fresh verification evidence.

- [ ] **Step 1: Update README**

Describe Claude Code plus Codex support, auto-detection, Codex app/CLI sign-in requirement, stacked provider sections, most-constrained menu badge, separate provider failures, and the app-server boundary. State explicitly that cc-meter never reads or stores Codex OAuth tokens.

- [ ] **Step 2: Run formatting and test verification**

Run: `git diff --check && swift test && swift build`

Expected: no whitespace errors, all tests pass with zero failures, and the package builds successfully.

- [ ] **Step 3: Run a real Codex protocol smoke test**

With the installed signed-in Codex executable, initialize `codex app-server`, call `account/rateLimits/read`, and verify the decoder accepts the returned response without printing credentials. Launch `swift run cc-meter`, verify Claude and Codex sections appear, Refresh updates both, the highest visible limit drives the badge, and quitting leaves no `codex app-server` child owned by cc-meter.

- [ ] **Step 4: Commit documentation**

```bash
git add README.md docs/superpowers/plans/2026-07-12-codex-support.md
git commit -m "docs: explain Codex usage support"
```

- [ ] **Step 5: Review requirements against the design**

Re-read `docs/superpowers/specs/2026-07-12-codex-support-design.md` and confirm every product behavior, integration boundary, mapping rule, compatibility constraint, error outcome, test category, and out-of-scope item matches the implementation. Record any gap as a failing test before changing production code.
