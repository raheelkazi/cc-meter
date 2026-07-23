# ChatGPT-Bundled Codex Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow the Homebrew service to detect and query the Codex CLI bundled with `ChatGPT.app`.

**Architecture:** Keep `CodexExecutableResolver` as the single discovery boundary. Make its static candidates deterministically testable with an injected home directory, then add system and per-user ChatGPT bundle paths before CLI and login-shell fallbacks.

**Tech Stack:** Swift 5.9, Foundation, XCTest, Swift Package Manager, Homebrew.

## Global Constraints

- Preserve macOS 13 and Swift tools 5.9 support.
- Preserve the dedicated Codex app, Homebrew, Intel Homebrew, `~/.local/bin`, and login-shell PATH candidates.
- Do not access, persist, or log Codex credentials.
- Prefer dedicated `Codex.app` over the ChatGPT-bundled CLI when both are installed.
- Release the patch as `v0.8.4` through `raheelkazi/homebrew-tap`.

---

### Task 1: Discover ChatGPT-bundled Codex

**Files:**
- Modify: `Tests/CCMeterCoreTests/CodexExecutableResolverTests.swift`
- Modify: `Sources/CCMeterCore/CodexUsageClient.swift`

**Interfaces:**
- Produces: `CodexExecutableResolver.defaultCandidates(home:) -> [URL]` for deterministic candidate testing.
- Consumes: existing `CodexExecutableResolver.resolve() -> CodexExecutable?` behavior.

- [ ] **Step 1: Write the failing test**

```swift
func testDefaultCandidatesIncludeSystemAndUserChatGPTBundles() {
    let home = URL(fileURLWithPath: "/Users/tester")
    let candidates = CodexExecutableResolver.defaultCandidates(home: home)

    XCTAssertTrue(candidates.contains(
        URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
    ))
    XCTAssertTrue(candidates.contains(
        home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex")
    ))
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --filter CodexExecutableResolverTests/testDefaultCandidatesIncludeSystemAndUserChatGPTBundles`

Expected: FAIL because the default candidate API is private and omits `ChatGPT.app` paths.

- [ ] **Step 3: Implement minimal discovery support**

```swift
static func defaultCandidates(home: URL) -> [URL] {
    [
        URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
        home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex"),
        URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
        home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
        URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        URL(fileURLWithPath: "/usr/local/bin/codex"),
        home.appendingPathComponent(".local/bin/codex")
    ]
}
```

Have the production helper call it with `FileManager.default.homeDirectoryForCurrentUser`.

- [ ] **Step 4: Verify GREEN and regressions**

Run: `swift test --filter CodexExecutableResolverTests`

Expected: all resolver tests pass.

Run: `swift test && swift build -c release`

Expected: the full suite and release build pass.

### Task 2: Publish and install the patch release

**Files:**
- Modify: `Sources/CCMeterCore/CodexUsageClient.swift`
- Modify: `Tests/CCMeterCoreTests/CodexExecutableResolverTests.swift`
- Modify: `docs/superpowers/plans/2026-07-22-chatgpt-codex-discovery.md`
- Modify: `Formula/cc-meter.rb` in `raheelkazi/homebrew-tap`

**Interfaces:**
- Produces: source tag `v0.8.4` and a formula pinned to its checksum.
- Consumes: the verified `main` commit and the GitHub tag archive.

- [ ] **Step 1: Commit and publish source**

Run: `git add Sources/CCMeterCore/CodexUsageClient.swift Tests/CCMeterCoreTests/CodexExecutableResolverTests.swift docs/superpowers/plans/2026-07-22-chatgpt-codex-discovery.md`

Run: `git commit -m "fix: discover Codex in ChatGPT app"`

Run: `git push origin main && git tag v0.8.4 && git push origin v0.8.4`

- [ ] **Step 2: Bump and publish the Homebrew formula**

Set the formula URL to `https://github.com/raheelkazi/cc-meter/archive/refs/tags/v0.8.4.tar.gz`, calculate its SHA-256 with `shasum -a 256`, update the version, then commit and push the tap.

- [ ] **Step 3: Install and validate**

Run: `brew update && brew upgrade cc-meter && brew services restart cc-meter`

Expected: Homebrew reports version `0.8.4` and the service is `started`.
