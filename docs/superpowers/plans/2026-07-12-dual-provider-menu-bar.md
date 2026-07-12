# Dual-Provider Menu-Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Claude Code and Codex usage together in the macOS menu bar as `Cl ● 62% · Cx ● 18%` whenever both providers have usable compact summaries.

**Architecture:** `DashboardViewModel` exposes ordered provider-aware compact summaries while retaining its existing highest-percentage compatibility property. A pure core formatter converts summaries and dashboard state into colored text segments and tooltip copy; `MenuBarController` only bridges those segments to `NSAttributedString` and the status button.

**Tech Stack:** Swift 5.9, Foundation, Combine, AppKit, XCTest, Swift Package Manager, macOS 13.

## Global Constraints

- Retain macOS 13 and Swift tools 5.9 compatibility.
- Add no third-party dependencies.
- Keep fixed provider order: Claude Code, then Codex.
- Use `Cl` for Claude Code and `Cx` for Codex only when both providers are shown.
- Preserve the current unlabeled `● 62%` form when only one provider is shown.
- Keep the existing used-percentage semantics, severity colors, and `CC ...` / `CC !` / `CC` fallbacks.
- Do not change provider fetching, storage, history, notifications, burn forecasts, polling, or popover layout.
- Do not add a preference or custom `NSStatusItem` view.

---

### Task 1: Expose ordered provider compact summaries

**Files:**
- Modify: `Sources/CCMeterCore/DashboardViewModel.swift`
- Modify: `Tests/CCMeterCoreTests/DashboardViewModelTests.swift`

**Interfaces:**
- Consumes: `MeterViewModel.compact`, `DashboardViewModel.showsCodex`, and `UsageProvider`.
- Produces: `ProviderCompactSummary` and `DashboardViewModel.compactProviders: [ProviderCompactSummary]`; retains `DashboardViewModel.compact: (percent: Int, color: MeterColor)?`.

- [ ] **Step 1: Write failing dashboard summary tests**

Add these tests to `DashboardViewModelTests`:

```swift
func testCompactProvidersExposeClaudeThenCodexWithIndependentValues() async {
    let (dashboard, _, _) = makeDashboard(claude: .success(usage(20)),
                                           codex: .success(usage(70)))
    await dashboard.refresh()

    XCTAssertEqual(dashboard.compactProviders, [
        ProviderCompactSummary(provider: .claude, percent: 20, color: .green),
        ProviderCompactSummary(provider: .codex, percent: 70, color: .amber)
    ])
}

func testCompactProvidersOmitHiddenCodex() async {
    let (dashboard, _, _) = makeDashboard(claude: .success(usage(20)),
                                           codex: .failure(.unauthorized))
    await dashboard.refresh()

    XCTAssertEqual(dashboard.compactProviders, [
        ProviderCompactSummary(provider: .claude, percent: 20, color: .green)
    ])
}

func testCompactProvidersCanShowCodexAlone() async {
    let (dashboard, _, _) = makeDashboard(claude: .failure(.unauthorized),
                                           codex: .success(usage(55)))
    await dashboard.refresh()

    XCTAssertEqual(dashboard.compactProviders, [
        ProviderCompactSummary(provider: .codex, percent: 55, color: .amber)
    ])
    XCTAssertEqual(dashboard.compact?.percent, 55)
    XCTAssertFalse(dashboard.hasError)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter DashboardViewModelTests
```

Expected: compilation fails because `ProviderCompactSummary` and `compactProviders` do not exist.

- [ ] **Step 3: Implement the provider-aware summaries**

Add above `DashboardViewModel` in `DashboardViewModel.swift`:

```swift
public struct ProviderCompactSummary: Equatable {
    public let provider: UsageProvider
    public let percent: Int
    public let color: MeterColor

    public init(provider: UsageProvider, percent: Int, color: MeterColor) {
        self.provider = provider
        self.percent = percent
        self.color = color
    }
}
```

Replace the current `compact` implementation with:

```swift
public var compactProviders: [ProviderCompactSummary] {
    var summaries: [ProviderCompactSummary] = []
    if let compact = claude.compact {
        summaries.append(ProviderCompactSummary(provider: .claude,
                                                percent: compact.percent,
                                                color: compact.color))
    }
    if showsCodex, let compact = codex.compact {
        summaries.append(ProviderCompactSummary(provider: .codex,
                                                percent: compact.percent,
                                                color: compact.color))
    }
    return summaries
}

public var compact: (percent: Int, color: MeterColor)? {
    compactProviders
        .max { $0.percent < $1.percent }
        .map { (percent: $0.percent, color: $0.color) }
}
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run:

```bash
swift test --filter DashboardViewModelTests
```

Expected: all `DashboardViewModelTests` pass, including the existing highest-provider and error-state tests.

- [ ] **Step 5: Commit Task 1**

```bash
git add Sources/CCMeterCore/DashboardViewModel.swift Tests/CCMeterCoreTests/DashboardViewModelTests.swift
git commit -m "feat: expose provider menu summaries"
```

### Task 2: Format native-independent menu-bar presentations

**Files:**
- Create: `Sources/CCMeterCore/MenuBarPresentation.swift`
- Create: `Tests/CCMeterCoreTests/MenuBarPresentationTests.swift`

**Interfaces:**
- Consumes: `[ProviderCompactSummary]`, `isLoading: Bool`, and `hasError: Bool`.
- Produces: `MenuBarPresentation.make(summaries:isLoading:hasError:)`, `MenuBarTitleSegment`, ordered title segments, and optional tooltip copy.

- [ ] **Step 1: Write failing formatter tests**

Create `Tests/CCMeterCoreTests/MenuBarPresentationTests.swift`:

```swift
import XCTest
@testable import CCMeterCore

final class MenuBarPresentationTests: XCTestCase {
    func testDualProviderPresentationUsesLabelsOrderColorsAndTooltip() {
        let presentation = MenuBarPresentation.make(summaries: [
            ProviderCompactSummary(provider: .claude, percent: 62, color: .amber),
            ProviderCompactSummary(provider: .codex, percent: 18, color: .green)
        ], isLoading: false, hasError: false)

        XCTAssertEqual(presentation.segments, [
            MenuBarTitleSegment(text: "Cl "),
            MenuBarTitleSegment(text: "●", color: .amber),
            MenuBarTitleSegment(text: " 62%"),
            MenuBarTitleSegment(text: " · "),
            MenuBarTitleSegment(text: "Cx "),
            MenuBarTitleSegment(text: "●", color: .green),
            MenuBarTitleSegment(text: " 18%")
        ])
        XCTAssertEqual(presentation.plainTitle, "Cl ● 62% · Cx ● 18%")
        XCTAssertEqual(presentation.tooltip,
                       "Claude Code 62% used · Codex 18% used")
    }

    func testSingleProviderPresentationKeepsCurrentCompactTitle() {
        for summary in [
            ProviderCompactSummary(provider: .claude, percent: 62, color: .amber),
            ProviderCompactSummary(provider: .codex, percent: 18, color: .green)
        ] {
            let presentation = MenuBarPresentation.make(summaries: [summary],
                                                        isLoading: false,
                                                        hasError: false)
            XCTAssertEqual(presentation.segments, [
                MenuBarTitleSegment(text: "● ", color: summary.color),
                MenuBarTitleSegment(text: "\(summary.percent)%")
            ])
            XCTAssertEqual(presentation.tooltip,
                           "\(summary.provider.displayName) \(summary.percent)% used")
        }
    }

    func testEmptyPresentationPreservesLoadingErrorAndIdleFallbacks() {
        XCTAssertEqual(MenuBarPresentation.make(summaries: [], isLoading: true,
                                                hasError: true).plainTitle, "CC ...")
        XCTAssertEqual(MenuBarPresentation.make(summaries: [], isLoading: false,
                                                hasError: true).plainTitle, "CC !")
        XCTAssertEqual(MenuBarPresentation.make(summaries: [], isLoading: false,
                                                hasError: false).plainTitle, "CC")
    }
}
```

- [ ] **Step 2: Run formatter tests and verify RED**

Run:

```bash
swift test --filter MenuBarPresentationTests
```

Expected: compilation fails because the presentation types do not exist.

- [ ] **Step 3: Implement the pure presentation formatter**

Create `Sources/CCMeterCore/MenuBarPresentation.swift`:

```swift
import Foundation

public struct MenuBarTitleSegment: Equatable {
    public let text: String
    public let color: MeterColor?

    public init(text: String, color: MeterColor? = nil) {
        self.text = text
        self.color = color
    }
}

public struct MenuBarPresentation: Equatable {
    public let segments: [MenuBarTitleSegment]
    public let tooltip: String?

    public var plainTitle: String { segments.map(\.text).joined() }

    public static func make(summaries: [ProviderCompactSummary],
                            isLoading: Bool,
                            hasError: Bool) -> MenuBarPresentation {
        guard !summaries.isEmpty else {
            let title = isLoading ? "CC ..." : (hasError ? "CC !" : "CC")
            return MenuBarPresentation(segments: [MenuBarTitleSegment(text: title)],
                                       tooltip: nil)
        }

        let tooltip = summaries
            .map { "\($0.provider.displayName) \($0.percent)% used" }
            .joined(separator: " · ")
        if summaries.count == 1, let summary = summaries.first {
            return MenuBarPresentation(segments: [
                MenuBarTitleSegment(text: "● ", color: summary.color),
                MenuBarTitleSegment(text: "\(summary.percent)%")
            ], tooltip: tooltip)
        }

        var segments: [MenuBarTitleSegment] = []
        for (index, summary) in summaries.enumerated() {
            if index > 0 { segments.append(MenuBarTitleSegment(text: " · ")) }
            segments.append(MenuBarTitleSegment(text: "\(abbreviation(for: summary.provider)) "))
            segments.append(MenuBarTitleSegment(text: "●", color: summary.color))
            segments.append(MenuBarTitleSegment(text: " \(summary.percent)%"))
        }
        return MenuBarPresentation(segments: segments, tooltip: tooltip)
    }

    private static func abbreviation(for provider: UsageProvider) -> String {
        switch provider {
        case .claude: return "Cl"
        case .codex: return "Cx"
        }
    }
}
```

- [ ] **Step 4: Run formatter and dashboard tests and verify GREEN**

Run:

```bash
swift test --filter 'MenuBarPresentationTests|DashboardViewModelTests'
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 5: Commit Task 2**

```bash
git add Sources/CCMeterCore/MenuBarPresentation.swift Tests/CCMeterCoreTests/MenuBarPresentationTests.swift
git commit -m "feat: format dual-provider menu title"
```

### Task 3: Render the presentation in the AppKit status item

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/cc-meter/MenuBarController.swift`
- Create: `Tests/CCMeterAppTests/MenuBarControllerTests.swift`

**Interfaces:**
- Consumes: `MenuBarPresentation.make(summaries:isLoading:hasError:)` and `MeterColor.nsColor`.
- Produces: an attributed native status title and matching `NSStatusBarButton.toolTip`.

- [ ] **Step 1: Write a failing AppKit bridge test**

Add a `CCMeterAppTests` target depending on `cc-meter` and `CCMeterCore`. Create `MenuBarControllerTests.swift` and assert that `titleString(for: MenuBarPresentation)` returns `Cl ● 62% · Cx ● 18%` with system orange on the first dot and system green on the second dot.

Add to `Package.swift`:

```swift
.testTarget(
    name: "CCMeterAppTests",
    dependencies: ["cc-meter", "CCMeterCore"]
)
```

Create `Tests/CCMeterAppTests/MenuBarControllerTests.swift`:

```swift
import AppKit
import XCTest
@testable import CCMeterCore
@testable import cc_meter

@MainActor
final class MenuBarControllerTests: XCTestCase {
    func testTitleStringAppliesEachProviderColor() {
        let presentation = MenuBarPresentation.make(summaries: [
            ProviderCompactSummary(provider: .claude, percent: 62, color: .amber),
            ProviderCompactSummary(provider: .codex, percent: 18, color: .green)
        ], isLoading: false, hasError: false)

        let title = MenuBarController.titleString(for: presentation)
        let string = title.string as NSString
        let firstDot = string.range(of: "●")
        let secondSearch = NSRange(location: NSMaxRange(firstDot),
                                   length: string.length - NSMaxRange(firstDot))
        let secondDot = string.range(of: "●", range: secondSearch)

        XCTAssertEqual(title.string, "Cl ● 62% · Cx ● 18%")
        XCTAssertEqual(title.attribute(.foregroundColor, at: firstDot.location,
                                       effectiveRange: nil) as? NSColor,
                       NSColor.systemOrange)
        XCTAssertEqual(title.attribute(.foregroundColor, at: secondDot.location,
                                       effectiveRange: nil) as? NSColor,
                       NSColor.systemGreen)
    }
}
```

Run:

```bash
swift test --filter MenuBarControllerTests
```

Expected: compilation fails because `MenuBarController.titleString(for:)` still accepts `DashboardViewModel` instead of `MenuBarPresentation`.

- [ ] **Step 2: Replace direct highest-provider title rendering**

Change the dashboard observer so rendering occurs after the published values settle:

```swift
dashboard.objectWillChange
    .receive(on: RunLoop.main)
    .sink { [weak self] in
        DispatchQueue.main.async { [weak self] in self?.updateTitle() }
    }
    .store(in: &cancellables)
```

Replace `updateTitle()` and `titleString(for:)` with:

```swift
private func updateTitle() {
    guard let button = statusItem.button else { return }
    let presentation = MenuBarPresentation.make(
        summaries: dashboard.compactProviders,
        isLoading: dashboard.isLoading,
        hasError: dashboard.hasError
    )
    button.attributedTitle = Self.titleString(for: presentation)
    button.toolTip = presentation.tooltip
}

static func titleString(for presentation: MenuBarPresentation) -> NSAttributedString {
    let result = NSMutableAttributedString(string: "")
    for segment in presentation.segments {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let color = segment.color {
            attributes[.foregroundColor] = color.nsColor
        }
        result.append(NSAttributedString(string: segment.text, attributes: attributes))
    }
    return result
}
```

- [ ] **Step 3: Run the AppKit bridge test and verify GREEN**

Run:

```bash
swift test --filter MenuBarControllerTests
```

Expected: the AppKit bridge test passes with both dot colors applied to the correct ranges.

- [ ] **Step 4: Build the application**

Run:

```bash
swift build
```

Expected: build succeeds with no compiler errors.

- [ ] **Step 5: Run the full test suite**

Run:

```bash
swift test
```

Expected: all tests pass with zero failures.

- [ ] **Step 6: Commit Task 3**

```bash
git add Package.swift Sources/cc-meter/MenuBarController.swift Tests/CCMeterAppTests/MenuBarControllerTests.swift
git commit -m "feat: show both providers in menu bar"
```

### Task 4: Verify, review, and prepare integration

**Files:**
- Modify: `docs/superpowers/plans/2026-07-12-dual-provider-menu-bar.md` only to mark completed checkboxes.

**Interfaces:**
- Consumes: the complete feature branch.
- Produces: a reviewed, release-buildable branch ready for merge and Homebrew packaging.

- [ ] **Step 1: Run fresh full verification**

Run:

```bash
swift test
swift build -c release
git diff --check main...HEAD
```

Expected: all tests pass, the release build succeeds, and the diff has no whitespace errors.

- [ ] **Step 2: Check the exact feature diff**

Run:

```bash
git status --short --branch
git diff --stat main...HEAD
git log --oneline main..HEAD
```

Expected: only the approved spec, plan, ignore rule, core summary/formatter, dashboard tests, formatter tests, and AppKit bridge are present.

- [ ] **Step 3: Request independent code review**

Capture the review range:

```bash
BASE_SHA=$(git merge-base HEAD main)
HEAD_SHA=$(git rev-parse HEAD)
printf '%s\n' "$BASE_SHA" "$HEAD_SHA"
```

Dispatch an independent reviewer with those exact SHAs, the approved design in `docs/superpowers/specs/2026-07-12-dual-provider-menu-bar-design.md`, and this plan. Fix every Critical or Important finding before integration and rerun Step 1 after any code change. Expected reviewer verdict: no unresolved Critical or Important findings.

- [ ] **Step 4: Perform a local installed-app smoke test after integration**

After merging and upgrading the Homebrew formula, verify that the running status item shows both provider abbreviations when both live caches are usable and that the tooltip names both providers. Confirm `brew list --versions cc-meter`, `brew services list`, and the running process path point to the new release.

Run:

```bash
brew list --versions cc-meter
brew services list | rg '^cc-meter\s'
pgrep -af '/cc-meter($| )'
```

Expected: Homebrew reports the newly tagged patch version, the service is `started`, and the process runs from `/opt/homebrew/opt/cc-meter/bin/cc-meter`.
