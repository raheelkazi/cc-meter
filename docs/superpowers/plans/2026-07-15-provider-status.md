# Provider Incident/Status Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a passive incident indicator - a ⚠ glyph in the menu bar and a banner in the popover - when Claude or Codex is degraded, by polling the official Statuspage APIs and filtering to the components each provider depends on.

**Architecture:** Logic in `CCMeterCore` behind the existing HTTP `Transport` seam. A `StatusMonitor` (`@MainActor`) polls both providers on a slow timer, keeps last-known status on a failed fetch (never fabricates an outage), and publishes per-provider `ProviderStatus`. `MenuBarPresentation` renders the ⚠; `PopoverView` renders a banner; `DashboardViewModel`/`AppDelegate` wire it in.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit + SwiftUI, XCTest, macOS 13+. No new dependencies. Reuses `Transport`/`HTTPResponse` from `UsageClient.swift`.

## Global Constraints

- Platform floor **macOS 13**; all logic in `CCMeterCore`, only SwiftUI/AppKit + wiring in `cc-meter`.
- Reuse the existing `Transport` protocol (`func send(_ request: URLRequest) async throws -> HTTPResponse`) and `HTTPResponse` from `Sources/CCMeterCore/UsageClient.swift` - do NOT add a second HTTP abstraction.
- Inject `now: () -> Date = { Date() }` and the client into anything time/network dependent; tests use fakes.
- **False-alarm rule (critical):** a status fetch/parse failure must return `nil` and keep last-known status; it must NEVER produce a ⚠. We only ever surface degradation the status page itself reports.
- Lenient decoding: unknown component-status / incident-impact strings map to the safe (`ok`/`none`) bucket; missing `components`/`incidents` arrays default to empty.
- Status URLs: Claude `https://status.claude.com/api/v2/summary.json`; Codex/OpenAI `https://status.openai.com/api/v2/summary.json`.
- Component filters (case-insensitive substring): Claude → `["claude code", "claude api"]`; Codex → `["codex"]`. No match → fall back to top-level `status.indicator`.
- No em dashes in code/comments (hyphens).
- Run suite: `swift test 2>&1 | tail -20`; one class: `swift test --filter <Class> 2>&1 | tail -20`. Commit after each task.
- Branch is `feat/provider-status`.

## Global Interfaces (authoritative signatures)

```swift
// Task 1
public enum StatusLevel: Int, Comparable {
    case ok = 0, degraded = 1, major = 2
    public static func < (lhs: StatusLevel, rhs: StatusLevel) -> Bool { lhs.rawValue < rhs.rawValue }
    public var color: MeterColor? { switch self { case .ok: return nil; case .degraded: return .amber; case .major: return .red } }
}
public struct ProviderStatus: Equatable {
    public let provider: UsageProvider
    public let level: StatusLevel
    public let headline: String?
    public let detail: String?
    public let url: URL?
    public init(provider: UsageProvider, level: StatusLevel, headline: String? = nil, detail: String? = nil, url: URL? = nil)
}

// Task 2
public struct StatusSummary: Decodable, Equatable {
    public struct Indicator: Decodable, Equatable { public let indicator: String; public let description: String? }
    public struct Component: Decodable, Equatable { public let name: String; public let status: String }
    public struct Incident: Decodable, Equatable { public let name: String; public let impact: String; public let status: String; public let shortlink: String? }
    public let status: Indicator
    public let components: [Component]
    public let incidents: [Incident]
}

// Task 3
public enum ProviderStatusEvaluator {
    public static func evaluate(_ summary: StatusSummary, provider: UsageProvider, statusURL: URL) -> ProviderStatus
}

// Task 4
public protocol StatusFetching { func fetch(_ provider: UsageProvider) async -> ProviderStatus? }
public struct HTTPStatusClient: StatusFetching {
    public init(transport: Transport)
    public static func statusURL(for provider: UsageProvider) -> URL
    public func fetch(_ provider: UsageProvider) async -> ProviderStatus?
}

// Task 5
@MainActor public final class StatusMonitor: ObservableObject {
    @Published public private(set) var statuses: [UsageProvider: ProviderStatus]
    public init(client: StatusFetching, providers: [UsageProvider] = [.claude, .codex], interval: TimeInterval = 300, now: @escaping () -> Date = { Date() })
    public func start()
    public func refresh() async
    public func status(for provider: UsageProvider) -> ProviderStatus?
    public func level(for provider: UsageProvider) -> StatusLevel
}

// Task 6 - MenuBarPresentation.make gains a defaulted statuses param:
//   public static func make(summaries:isLoading:hasError:statuses: [UsageProvider: StatusLevel] = [:]) -> MenuBarPresentation
```

---

### Task 1: `StatusLevel` and `ProviderStatus`

**Files:** Create `Sources/CCMeterCore/ProviderStatus.swift`; Test `Tests/CCMeterCoreTests/ProviderStatusTests.swift`.

**Interfaces:** Consumes `UsageProvider`, `MeterColor`. Produces `StatusLevel`, `ProviderStatus`.

- [ ] **Step 1: Write the failing test**
```swift
import XCTest
@testable import CCMeterCore

final class ProviderStatusTests: XCTestCase {
    func testLevelOrdersAndColors() {
        XCTAssertTrue(StatusLevel.ok < .degraded)
        XCTAssertTrue(StatusLevel.degraded < .major)
        XCTAssertNil(StatusLevel.ok.color)
        XCTAssertEqual(StatusLevel.degraded.color, .amber)
        XCTAssertEqual(StatusLevel.major.color, .red)
    }

    func testProviderStatusStoresFields() {
        let s = ProviderStatus(provider: .claude, level: .major, headline: "API outage",
                               detail: "Elevated errors", url: URL(string: "https://status.claude.com"))
        XCTAssertEqual(s.level, .major)
        XCTAssertEqual(s.headline, "API outage")
    }
}
```
- [ ] **Step 2: Run** `swift test --filter ProviderStatusTests 2>&1 | tail -20` - expect FAIL (undefined).
- [ ] **Step 3: Implement**
```swift
import Foundation

/// Severity of a provider's reported status. `ok` shows no cue.
public enum StatusLevel: Int, Comparable {
    case ok = 0, degraded = 1, major = 2
    public static func < (lhs: StatusLevel, rhs: StatusLevel) -> Bool { lhs.rawValue < rhs.rawValue }
    /// The menu-bar / banner color; nil when there is nothing to show.
    public var color: MeterColor? {
        switch self {
        case .ok: return nil
        case .degraded: return .amber
        case .major: return .red
        }
    }
}

/// A provider's current incident/status, derived from its status page.
public struct ProviderStatus: Equatable {
    public let provider: UsageProvider
    public let level: StatusLevel
    public let headline: String?
    public let detail: String?
    public let url: URL?
    public init(provider: UsageProvider, level: StatusLevel,
                headline: String? = nil, detail: String? = nil, url: URL? = nil) {
        self.provider = provider
        self.level = level
        self.headline = headline
        self.detail = detail
        self.url = url
    }
}
```
- [ ] **Step 4: Run** - expect PASS (2 tests).
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat: StatusLevel and ProviderStatus types"`

---

### Task 2: `StatusSummary` lenient decoding

**Files:** Create `Sources/CCMeterCore/StatusSummary.swift`; Test `Tests/CCMeterCoreTests/StatusSummaryTests.swift`.

**Interfaces:** Produces `StatusSummary` (+ nested `Indicator`/`Component`/`Incident`). Missing `components`/`incidents` default to `[]`.

- [ ] **Step 1: Write the failing test**
```swift
import XCTest
@testable import CCMeterCore

final class StatusSummaryTests: XCTestCase {
    func testDecodesOperationalWithComponentsAndIncidents() throws {
        let json = """
        {"status":{"indicator":"none","description":"All Systems Operational"},
         "components":[{"name":"Claude Code","status":"operational"},
                       {"name":"Claude API (api.anthropic.com)","status":"degraded_performance"}],
         "incidents":[{"name":"Elevated errors","impact":"minor","status":"investigating","shortlink":"https://stspg.io/x"}]}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(StatusSummary.self, from: json)
        XCTAssertEqual(s.status.indicator, "none")
        XCTAssertEqual(s.components.map(\.name), ["Claude Code", "Claude API (api.anthropic.com)"])
        XCTAssertEqual(s.components[1].status, "degraded_performance")
        XCTAssertEqual(s.incidents.first?.impact, "minor")
        XCTAssertEqual(s.incidents.first?.shortlink, "https://stspg.io/x")
    }

    func testMissingArraysDefaultToEmpty() throws {
        let json = """
        {"status":{"indicator":"none","description":null}}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(StatusSummary.self, from: json)
        XCTAssertTrue(s.components.isEmpty)
        XCTAssertTrue(s.incidents.isEmpty)
        XCTAssertNil(s.status.description)
    }
}
```
- [ ] **Step 2: Run** `swift test --filter StatusSummaryTests 2>&1 | tail -20` - expect FAIL.
- [ ] **Step 3: Implement**
```swift
import Foundation

/// The subset of an Atlassian Statuspage `summary.json` we use. Lenient: absent `components`
/// or `incidents` decode to empty arrays, and unknown status/impact strings are just carried
/// as-is (the evaluator maps unknown values to the safe bucket).
public struct StatusSummary: Decodable, Equatable {
    public struct Indicator: Decodable, Equatable {
        public let indicator: String
        public let description: String?
    }
    public struct Component: Decodable, Equatable {
        public let name: String
        public let status: String
    }
    public struct Incident: Decodable, Equatable {
        public let name: String
        public let impact: String
        public let status: String
        public let shortlink: String?
    }

    public let status: Indicator
    public let components: [Component]
    public let incidents: [Incident]

    private enum CodingKeys: String, CodingKey { case status, components, incidents }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(Indicator.self, forKey: .status)
        components = try c.decodeIfPresent([Component].self, forKey: .components) ?? []
        incidents = try c.decodeIfPresent([Incident].self, forKey: .incidents) ?? []
    }
}
```
- [ ] **Step 4: Run** - expect PASS (2 tests).
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat: lenient Statuspage summary.json decoding"`

---

### Task 3: `ProviderStatusEvaluator`

**Files:** Create `Sources/CCMeterCore/ProviderStatusEvaluator.swift`; Test `Tests/CCMeterCoreTests/ProviderStatusEvaluatorTests.swift`.

**Interfaces:** Consumes `StatusSummary`, `UsageProvider`, `StatusLevel`, `ProviderStatus`. Produces `ProviderStatusEvaluator.evaluate(_:provider:statusURL:)`. Claude matches components whose lowercased name contains "claude code" or "claude api"; Codex matches "codex". No match → use `status.indicator`. Level = worst of matched-component statuses and active incident impacts. Headline/url come from the highest-impact incident when present.

- [ ] **Step 1: Write the failing test**
```swift
import XCTest
@testable import CCMeterCore

final class ProviderStatusEvaluatorTests: XCTestCase {
    private let url = URL(string: "https://status.claude.com")!
    private func summary(indicator: String = "none", comps: [(String,String)] = [], incidents: [(String,String)] = []) -> StatusSummary {
        let comp = comps.map { "{\"name\":\"\($0.0)\",\"status\":\"\($0.1)\"}" }.joined(separator: ",")
        let inc = incidents.map { "{\"name\":\"\($0.0)\",\"impact\":\"\($0.1)\",\"status\":\"investigating\",\"shortlink\":\"https://stspg.io/x\"}" }.joined(separator: ",")
        let json = "{\"status\":{\"indicator\":\"\(indicator)\",\"description\":\"desc\"},\"components\":[\(comp)],\"incidents\":[\(inc)]}"
        return try! JSONDecoder().decode(StatusSummary.self, from: json.data(using: .utf8)!)
    }

    func testAllOperationalIsOk() {
        let s = summary(comps: [("Claude Code","operational"), ("claude.ai","major_outage")])
        // claude.ai is NOT a relevant component for the Claude provider, so its outage is ignored.
        let r = ProviderStatusEvaluator.evaluate(s, provider: .claude, statusURL: url)
        XCTAssertEqual(r.level, .ok)
    }

    func testDegradedRelevantComponent() {
        let s = summary(comps: [("Claude API (api.anthropic.com)","degraded_performance")])
        XCTAssertEqual(ProviderStatusEvaluator.evaluate(s, provider: .claude, statusURL: url).level, .degraded)
    }

    func testMajorOutageComponent() {
        let s = summary(comps: [("Claude Code","major_outage")])
        XCTAssertEqual(ProviderStatusEvaluator.evaluate(s, provider: .claude, statusURL: url).level, .major)
    }

    func testActiveIncidentDrivesLevelAndHeadline() {
        let s = summary(comps: [("Claude Code","operational")], incidents: [("Elevated errors","major")])
        let r = ProviderStatusEvaluator.evaluate(s, provider: .claude, statusURL: url)
        XCTAssertEqual(r.level, .major)
        XCTAssertEqual(r.headline, "Elevated errors")
        XCTAssertEqual(r.url?.absoluteString, "https://stspg.io/x")
    }

    func testCodexMatchesCodexApi() {
        let s = summary(comps: [("Codex API","partial_outage"), ("Batch","major_outage")])
        XCTAssertEqual(ProviderStatusEvaluator.evaluate(s, provider: .codex, statusURL: url).level, .degraded)
    }

    func testFallsBackToIndicatorWhenNoComponentMatches() {
        let s = summary(indicator: "major", comps: [("Unrelated","operational")])
        XCTAssertEqual(ProviderStatusEvaluator.evaluate(s, provider: .codex, statusURL: url).level, .major)
    }

    func testUnknownStatusStringsAreSafe() {
        let s = summary(comps: [("Claude Code","brand_new_status")])
        XCTAssertEqual(ProviderStatusEvaluator.evaluate(s, provider: .claude, statusURL: url).level, .ok)
    }
}
```
- [ ] **Step 2: Run** `swift test --filter ProviderStatusEvaluatorTests 2>&1 | tail -25` - expect FAIL.
- [ ] **Step 3: Implement**
```swift
import Foundation

/// Derives a single `ProviderStatus` from a provider's Statuspage summary, filtered to the
/// components that provider actually depends on. Conservative: any active incident with impact
/// >= minor counts, and component status gives the precise signal when no incident is present.
public enum ProviderStatusEvaluator {
    private static func relevantSubstrings(for provider: UsageProvider) -> [String] {
        switch provider {
        case .claude: return ["claude code", "claude api"]
        case .codex: return ["codex"]
        }
    }

    private static func level(componentStatus: String) -> StatusLevel {
        switch componentStatus {
        case "degraded_performance", "partial_outage": return .degraded
        case "major_outage": return .major
        default: return .ok   // operational, under_maintenance, or anything unknown
        }
    }

    private static func level(impact: String) -> StatusLevel {
        switch impact {
        case "minor": return .degraded
        case "major", "critical": return .major
        default: return .ok   // none, or anything unknown
        }
    }

    public static func evaluate(_ summary: StatusSummary, provider: UsageProvider, statusURL: URL) -> ProviderStatus {
        let needles = relevantSubstrings(for: provider)
        let matched = summary.components.filter { comp in
            let lower = comp.name.lowercased()
            return needles.contains { lower.contains($0) }
        }

        // Component signal: worst matched component, or - if nothing matched - the overall indicator.
        let componentLevel: StatusLevel
        if matched.isEmpty {
            componentLevel = level(impact: summary.status.indicator)   // indicator vocab == impact vocab
        } else {
            componentLevel = matched.map { level(componentStatus: $0.status) }.max() ?? .ok
        }

        // Incident signal: worst active incident (summary.json only lists unresolved incidents).
        let worstIncident = summary.incidents.max { level(impact: $0.impact) < level(impact: $1.impact) }
        let incidentLevel = worstIncident.map { level(impact: $0.impact) } ?? .ok

        let overall = max(componentLevel, incidentLevel)
        guard overall > .ok else {
            return ProviderStatus(provider: provider, level: .ok, url: statusURL)
        }

        if let incident = worstIncident, level(impact: incident.impact) > .ok {
            let link = incident.shortlink.flatMap(URL.init(string:)) ?? statusURL
            return ProviderStatus(provider: provider, level: overall, headline: incident.name,
                                  detail: summary.status.description, url: link)
        }
        // Degraded via component status, no incident object.
        let worstComp = matched.max { level(componentStatus: $0.status) < level(componentStatus: $1.status) }
        return ProviderStatus(provider: provider, level: overall,
                              headline: worstComp.map { "\($0.name) \($0.status.replacingOccurrences(of: "_", with: " "))" },
                              detail: summary.status.description, url: statusURL)
    }
}
```
- [ ] **Step 4: Run** - expect PASS (7 tests).
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat: provider status evaluator (component filter + worst-of)"`

---

### Task 4: `StatusClient`

**Files:** Create `Sources/CCMeterCore/StatusClient.swift`; Test `Tests/CCMeterCoreTests/StatusClientTests.swift`.

**Interfaces:** Consumes `Transport`, `HTTPResponse`, `StatusSummary`, `ProviderStatusEvaluator`, `ProviderStatus`. Produces `StatusFetching`, `HTTPStatusClient`. Returns `nil` on any transport throw, non-200, or decode failure. `statusURL(for:)`: claude → status.claude.com, codex → status.openai.com.

- [ ] **Step 1: Write the failing test**
```swift
import XCTest
@testable import CCMeterCore

final class StatusClientTests: XCTestCase {
    private struct StubTransport: Transport {
        let result: Result<HTTPResponse, Error>
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            switch result { case .success(let r): return r; case .failure(let e): throw e }
        }
    }
    private func ok(_ body: String) -> StubTransport {
        StubTransport(result: .success(HTTPResponse(status: 200, data: body.data(using: .utf8)!)))
    }

    func testFetchSuccessProducesStatus() async {
        let body = "{\"status\":{\"indicator\":\"major\",\"description\":\"Partial outage\"},\"components\":[{\"name\":\"Codex API\",\"status\":\"major_outage\"}],\"incidents\":[]}"
        let status = await HTTPStatusClient(transport: ok(body)).fetch(.codex)
        XCTAssertEqual(status?.level, .major)
        XCTAssertEqual(status?.provider, .codex)
    }

    func testTransportFailureReturnsNil() async {
        let client = HTTPStatusClient(transport: StubTransport(result: .failure(URLError(.notConnectedToInternet))))
        let status = await client.fetch(.claude)
        XCTAssertNil(status, "our own network failure must never fabricate a status")
    }

    func testNon200ReturnsNil() async {
        let client = HTTPStatusClient(transport: StubTransport(result: .success(HTTPResponse(status: 503, data: Data()))))
        XCTAssertNil(await client.fetch(.claude))
    }

    func testGarbageBodyReturnsNil() async {
        XCTAssertNil(await HTTPStatusClient(transport: ok("not json")).fetch(.claude))
    }

    func testStatusURLsPerProvider() {
        XCTAssertEqual(HTTPStatusClient.statusURL(for: .claude).absoluteString, "https://status.claude.com/api/v2/summary.json")
        XCTAssertEqual(HTTPStatusClient.statusURL(for: .codex).absoluteString, "https://status.openai.com/api/v2/summary.json")
    }
}
```
- [ ] **Step 2: Run** `swift test --filter StatusClientTests 2>&1 | tail -20` - expect FAIL.
- [ ] **Step 3: Implement**
```swift
import Foundation

public protocol StatusFetching {
    /// Current status for a provider, or nil on any fetch/parse failure (never a fabricated outage).
    func fetch(_ provider: UsageProvider) async -> ProviderStatus?
}

/// Fetches a provider's Statuspage `summary.json` over the shared `Transport` and evaluates it.
public struct HTTPStatusClient: StatusFetching {
    private let transport: Transport
    public init(transport: Transport) { self.transport = transport }

    public static func statusURL(for provider: UsageProvider) -> URL {
        switch provider {
        case .claude: return URL(string: "https://status.claude.com/api/v2/summary.json")!
        case .codex: return URL(string: "https://status.openai.com/api/v2/summary.json")!
        }
    }

    public func fetch(_ provider: UsageProvider) async -> ProviderStatus? {
        let url = Self.statusURL(for: provider)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: HTTPResponse
        do { response = try await transport.send(request) } catch { return nil }
        guard response.status == 200 else { return nil }
        guard let summary = try? JSONDecoder().decode(StatusSummary.self, from: response.data) else { return nil }
        return ProviderStatusEvaluator.evaluate(summary, provider: provider, statusURL: URL(string: "https://\(url.host ?? "")")!)
    }
}
```
- [ ] **Step 4: Run** - expect PASS (5 tests).
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat: HTTP status client over the shared transport"`

---

### Task 5: `StatusMonitor`

**Files:** Create `Sources/CCMeterCore/StatusMonitor.swift`; Test `Tests/CCMeterCoreTests/StatusMonitorTests.swift`.

**Interfaces:** Consumes `StatusFetching`, `ProviderStatus`, `StatusLevel`, `UsageProvider`. Produces `StatusMonitor`. `refresh()` fetches each provider; a `nil` result keeps the last-known status (does not clear it). `start()` fires an immediate refresh and schedules a repeating timer.

- [ ] **Step 1: Write the failing test**
```swift
import XCTest
@testable import CCMeterCore

@MainActor
final class StatusMonitorTests: XCTestCase {
    private final class FakeClient: StatusFetching {
        var results: [UsageProvider: ProviderStatus?] = [:]
        func fetch(_ provider: UsageProvider) async -> ProviderStatus? { results[provider] ?? nil }
    }

    func testRefreshPublishesPerProviderStatus() async {
        let client = FakeClient()
        client.results[.claude] = ProviderStatus(provider: .claude, level: .major, headline: "Outage")
        client.results[.codex] = ProviderStatus(provider: .codex, level: .ok)
        let monitor = StatusMonitor(client: client, interval: 300)
        await monitor.refresh()
        XCTAssertEqual(monitor.level(for: .claude), .major)
        XCTAssertEqual(monitor.level(for: .codex), .ok)
        XCTAssertEqual(monitor.status(for: .claude)?.headline, "Outage")
    }

    func testFailedFetchKeepsLastKnown() async {
        let client = FakeClient()
        client.results[.claude] = ProviderStatus(provider: .claude, level: .major, headline: "Outage")
        let monitor = StatusMonitor(client: client, interval: 300)
        await monitor.refresh()
        XCTAssertEqual(monitor.level(for: .claude), .major)

        client.results[.claude] = .some(nil)   // next fetch fails
        await monitor.refresh()
        XCTAssertEqual(monitor.level(for: .claude), .major, "a failed fetch must not clear a known outage")
    }

    func testUnknownProviderLevelIsOk() {
        let monitor = StatusMonitor(client: FakeClient(), interval: 300)
        XCTAssertEqual(monitor.level(for: .codex), .ok)
    }
}
```
- [ ] **Step 2: Run** `swift test --filter StatusMonitorTests 2>&1 | tail -20` - expect FAIL.
- [ ] **Step 3: Implement**
```swift
import Foundation
import Combine

/// Polls each provider's status on a slow timer and publishes the latest per-provider status.
/// A failed fetch keeps the last-known status - it never clears a known outage or invents one.
@MainActor
public final class StatusMonitor: ObservableObject {
    @Published public private(set) var statuses: [UsageProvider: ProviderStatus] = [:]

    private let client: StatusFetching
    private let providers: [UsageProvider]
    private let interval: TimeInterval
    private let now: () -> Date
    private var timer: Timer?

    public init(client: StatusFetching,
                providers: [UsageProvider] = [.claude, .codex],
                interval: TimeInterval = 300,
                now: @escaping () -> Date = { Date() }) {
        self.client = client
        self.providers = providers
        self.interval = interval
        self.now = now
    }

    public func start() {
        Task { @MainActor in await self.refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    public func refresh() async {
        for provider in providers {
            if let status = await client.fetch(provider) {
                statuses[provider] = status
            }
            // nil -> keep last-known; never clear or fabricate.
        }
    }

    public func status(for provider: UsageProvider) -> ProviderStatus? { statuses[provider] }
    public func level(for provider: UsageProvider) -> StatusLevel { statuses[provider]?.level ?? .ok }
}
```
- [ ] **Step 4: Run** - expect PASS (3 tests).
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat: StatusMonitor polling with last-known retention"`

---

### Task 6: `MenuBarPresentation` ⚠ glyph

**Files:** Modify `Sources/CCMeterCore/MenuBarPresentation.swift`; Test add to `Tests/CCMeterCoreTests/MenuBarPresentationTests.swift`.

**Interfaces:** `make` gains `statuses: [UsageProvider: StatusLevel] = [:]`. For a provider whose level is `.degraded`/`.major`, the dot segment (`●`) is replaced by `⚠` colored by `level.color`; the percentage stays. Existing callers (no statuses) are unchanged.

- [ ] **Step 1: Write the failing test** (append to `MenuBarPresentationTests`)
```swift
    func testDegradedProviderShowsWarningGlyph() {
        let summaries = [ProviderCompactSummary(provider: .claude, percent: 42, color: .green),
                         ProviderCompactSummary(provider: .codex, percent: 30, color: .green)]
        let p = MenuBarPresentation.make(summaries: summaries, isLoading: false, hasError: false,
                                         statuses: [.claude: .major])
        XCTAssertTrue(p.segments.contains { $0.text == "⚠" && $0.color == .red },
                      "a degraded provider shows a colored warning glyph")
        XCTAssertFalse(p.plainTitle.contains("●⚠"))
        XCTAssertTrue(p.plainTitle.contains("42%"))
    }

    func testNoStatusesKeepsDots() {
        let summaries = [ProviderCompactSummary(provider: .claude, percent: 42, color: .green)]
        let p = MenuBarPresentation.make(summaries: summaries, isLoading: false, hasError: false)
        XCTAssertTrue(p.segments.contains { $0.text.contains("●") })
        XCTAssertFalse(p.segments.contains { $0.text == "⚠" })
    }
```
- [ ] **Step 2: Run** `swift test --filter MenuBarPresentationTests 2>&1 | tail -20` - expect FAIL (extra arg).
- [ ] **Step 3: Implement** - change `make`'s signature and the two dot-emitting sites. Replace the whole `make` function body so it threads `statuses`:
```swift
    public static func make(summaries: [ProviderCompactSummary],
                            isLoading: Bool,
                            hasError: Bool,
                            statuses: [UsageProvider: StatusLevel] = [:]) -> MenuBarPresentation {
        guard !summaries.isEmpty else {
            let title = isLoading ? "CC ..." : (hasError ? "CC !" : "CC")
            return MenuBarPresentation(segments: [MenuBarTitleSegment(text: title)], tooltip: nil)
        }

        let tooltip = summaries
            .map { "\($0.provider.displayName) \($0.percent)% used" }
            .joined(separator: " · ")

        // The status glyph replaces the usage dot when a provider is degraded: green dot -> colored ⚠.
        func mark(for summary: ProviderCompactSummary) -> MenuBarTitleSegment {
            let level = statuses[summary.provider] ?? .ok
            if let color = level.color {
                return MenuBarTitleSegment(text: "⚠", color: color)
            }
            return MenuBarTitleSegment(text: "●", color: summary.color)
        }

        if summaries.count == 1, let summary = summaries.first {
            let dot = mark(for: summary)
            return MenuBarPresentation(segments: [
                MenuBarTitleSegment(text: dot.text + " ", color: dot.color),
                MenuBarTitleSegment(text: "\(summary.percent)%")
            ], tooltip: tooltip)
        }

        var segments: [MenuBarTitleSegment] = []
        for (index, summary) in summaries.enumerated() {
            if index > 0 { segments.append(MenuBarTitleSegment(text: " · ")) }
            segments.append(MenuBarTitleSegment(text: "\(abbreviation(for: summary.provider)) "))
            segments.append(mark(for: summary))
            segments.append(MenuBarTitleSegment(text: " \(summary.percent)%"))
        }
        return MenuBarPresentation(segments: segments, tooltip: tooltip)
    }
```
- [ ] **Step 4: Run** - expect PASS (all MenuBarPresentationTests, including 2 new).
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat: warning glyph in the menu bar for a degraded provider"`

---

### Task 7: Wire status into `DashboardViewModel`

**Files:** Modify `Sources/CCMeterCore/DashboardViewModel.swift`; Test add to `Tests/CCMeterCoreTests/DashboardViewModelTests.swift`.

**Interfaces:** `DashboardViewModel` gains an optional `StatusMonitor` and exposes `statusLevels: [UsageProvider: StatusLevel]` and `providerStatuses: [UsageProvider: ProviderStatus]`, forwarding `objectWillChange` so the menu bar re-renders on status change. Constructor gets a new defaulted parameter to preserve existing callers/tests.

- [ ] **Step 1: Write the failing test** (append to `DashboardViewModelTests`; this is a `@MainActor` suite)
```swift
    func testForwardsStatusLevelsFromMonitor() async {
        final class FakeClient: StatusFetching {
            func fetch(_ provider: UsageProvider) async -> ProviderStatus? {
                provider == .claude ? ProviderStatus(provider: .claude, level: .degraded, headline: "x") : nil
            }
        }
        let monitor = StatusMonitor(client: FakeClient(), interval: 300)
        await monitor.refresh()
        // Mirror this file's existing meter construction (DashboardStubClient + usage(_:) helpers).
        let claudeMeter = MeterViewModel(provider: .claude, client: DashboardStubClient(.success(usage(20))), now: { self.now })
        let codexMeter = MeterViewModel(provider: .codex, client: DashboardStubClient(.success(usage(20))), now: { self.now })
        let dashboard = DashboardViewModel(claude: claudeMeter, codex: codexMeter, statusMonitor: monitor)
        XCTAssertEqual(dashboard.statusLevels[.claude], .degraded)
        XCTAssertEqual(dashboard.providerStatuses[.claude]?.headline, "x")
    }
```

- [ ] **Step 2: Run** `swift test --filter DashboardViewModelTests 2>&1 | tail -20` - expect FAIL.
- [ ] **Step 3: Implement** - add to `DashboardViewModel`:
  - stored `private let statusMonitor: StatusMonitor?`
  - new init param `statusMonitor: StatusMonitor? = nil` (assign it; subscribe to its `objectWillChange` and forward, mirroring how `claude`/`codex` are forwarded via `cancellables`)
  - computed `public var statusLevels: [UsageProvider: StatusLevel] { statusMonitor?.statuses.mapValues(\.level) ?? [:] }`
  - computed `public var providerStatuses: [UsageProvider: ProviderStatus] { statusMonitor?.statuses ?? [:] }`
  Read the existing `init` and `cancellables` wiring first and follow the same `objectWillChange.sink { [weak self] in self?.objectWillChange.send() }` pattern.
- [ ] **Step 4: Run** - expect PASS.
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat: forward provider status through the dashboard view-model"`

---

### Task 8: Popover banner + menu-bar wiring

**Files:** Modify `Sources/cc-meter/PopoverView.swift` and `Sources/cc-meter/MenuBarController.swift`. UI - build-verified (no unit test).

**Interfaces:** Consumes `DashboardViewModel.providerStatuses` / `.statusLevels`.

- [ ] **Step 1: Menu bar** - in `MenuBarController.updateTitle()`, pass the statuses to `MenuBarPresentation.make`:
```swift
        let presentation = MenuBarPresentation.make(
            summaries: dashboard.compactProviders,
            isLoading: dashboard.isLoading,
            hasError: dashboard.hasError,
            statuses: dashboard.statusLevels
        )
```
- [ ] **Step 2: Popover banner** - in `PopoverView.body`, above the provider list (after the existing `dashboard.alert` banner), add status banners for any degraded provider. Add this into the `body`'s VStack (before the `ScrollView`/limits, both in the Limits and Usage branches - simplest is to place it right after `header`):
```swift
            ForEach(statusBanners, id: \.provider) { status in
                statusBanner(status)
            }
```
and add these members to `PopoverView`:
```swift
    private var statusBanners: [ProviderStatus] {
        // Gate Codex on visibility: the monitor polls OpenAI's status unauthenticated, so a
        // signed-out Codex user must not see a banner for a provider whose block is hidden.
        var providers: [UsageProvider] = [.claude]
        if dashboard.showsCodex { providers.append(.codex) }
        return providers.compactMap { dashboard.providerStatuses[$0] }.filter { $0.level != .ok }
    }

    @ViewBuilder private func statusBanner(_ status: ProviderStatus) -> some View {
        Button {
            if let url = status.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(status.level.color?.swiftUIColor ?? .secondary)
                    .font(.system(size: 11, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(status.provider.displayName) - \(status.level == .major ? "major outage" : "degraded")")
                        .font(.caption2.weight(.semibold))
                    if let headline = status.headline {
                        Text(headline).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((status.level.color?.swiftUIColor ?? .secondary).opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(status.url?.absoluteString ?? "")
    }
```
(`MeterColor.swiftUIColor` already exists - it is used elsewhere in this file. `NSWorkspace` needs `import AppKit`, already imported in PopoverView.)
- [ ] **Step 3: Build** `swift build 2>&1 | tail -20` - fix any error against the real file structure.
- [ ] **Step 4: Full suite** `swift test 2>&1 | tail -15` - all pass.
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat: popover incident banner and menu-bar status wiring"`

---

### Task 9: `AppDelegate` wiring

**Files:** Modify `Sources/cc-meter/AppDelegate.swift`. Build-verified.

**Interfaces:** Constructs `StatusMonitor` with an `HTTPStatusClient` over a `URLSessionTransport`, passes it to `DashboardViewModel`, and starts it.

- [ ] **Step 1: Construct + wire** - in `applicationDidFinishLaunching`, before building `DashboardViewModel`:
```swift
        let statusMonitor = StatusMonitor(client: HTTPStatusClient(transport: URLSessionTransport(session: .shared)))
```
Change the `DashboardViewModel(...)` construction to pass `statusMonitor: statusMonitor`. After `dashboard.start()`, add:
```swift
        statusMonitor.start()
```
Store it on the delegate if needed to keep it alive: add `private var statusMonitor: StatusMonitor?` and assign `self.statusMonitor = statusMonitor` (mirror how `dashboard` is retained).
- [ ] **Step 2: Build** `swift build 2>&1 | tail -20`.
- [ ] **Step 3: Full suite** `swift test 2>&1 | tail -15`.
- [ ] **Step 4: Commit** `git add -A && git commit -m "feat: wire StatusMonitor into the app"`

---

### Task 10: End-to-end verification against live status APIs

**Files:** none (verification only).

- [ ] **Step 1** Build: `swift build 2>&1 | tail -5`.
- [ ] **Step 2** Confirm the evaluator against LIVE data with a throwaway test (create `Tests/CCMeterCoreTests/ManualStatusE2E.swift`, run it, then DELETE it - do not commit):
```swift
import XCTest
@testable import CCMeterCore
final class ManualStatusE2E: XCTestCase {
    func testLiveStatus() async throws {
        let client = HTTPStatusClient(transport: URLSessionTransport(session: .shared))
        for p in [UsageProvider.claude, .codex] {
            let s = await client.fetch(p)
            print("E2E \(p.rawValue): level=\(s?.level.rawValue ?? -1) headline=\(s?.headline ?? "nil") url=\(s?.url?.absoluteString ?? "nil")")
            XCTAssertNotNil(s, "live status fetch should succeed for \(p.rawValue)")
        }
    }
}
```
Run `swift test --filter ManualStatusE2E 2>&1 | grep -E 'E2E|passed|failed'`. Expect both providers fetch successfully (level 0 = ok when all operational). Then `rm Tests/CCMeterCoreTests/ManualStatusE2E.swift`.
- [ ] **Step 3** Final `swift test 2>&1 | tail -5` (whole suite green), confirm working tree clean.

## Self-Review
- Spec coverage: data sources (Tasks 4), component filter + derivation (Task 3), StatusMonitor slow poll + last-known (Task 5), menu-bar ⚠ (Task 6), popover banner (Task 8), false-alarm rule (Tasks 4/5 return nil / keep last-known), lenient decoding (Task 2), no notifications / scope boundary (nothing touches the notifier or usage path).
- Placeholder scan: every code step is complete; Tasks 7-9 name the exact existing patterns to mirror and are build/test-gated.
- Type consistency: `StatusLevel`, `ProviderStatus`, `StatusSummary`, `ProviderStatusEvaluator.evaluate`, `StatusFetching`/`HTTPStatusClient`, `StatusMonitor` signatures match the Global Interfaces block across tasks.
