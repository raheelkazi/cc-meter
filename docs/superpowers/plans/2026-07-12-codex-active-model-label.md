# Codex Active Model Label Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Label Codex's unnamed default quota with the active model display name, such as `7-day (GPT-5.6-Sol)`, without changing quota identity.

**Architecture:** Ask the existing Codex app-server process for rate limits, configuration, and the model catalog in one newline-delimited JSON-RPC exchange. Resolve `config.model` through the catalog and pass that display name to rate-limit mapping as a fallback only for the unnamed `codex` group; explicit server-provided names remain authoritative.

**Tech Stack:** Swift 6, Foundation `Process`, XCTest, Codex app-server JSON-RPC.

## Global Constraints

- Do not hardcode GPT-5.6 Sol as the current model.
- Keep limit identities such as `codex:codex:primary` unchanged.
- Treat model metadata as optional and retain the generic duration label when it is unavailable.
- Keep explicit `limitName` values authoritative.

---

### Task 1: Collect all app-server responses

**Files:**
- Modify: `Sources/CCMeterCore/CodexUsageClient.swift`
- Modify: `Sources/CCMeterCore/CodexAppServerProcess.swift`
- Test: `Tests/CCMeterCoreTests/CodexUsageClientTests.swift`

**Interfaces:**
- Consumes: a Codex executable, newline-delimited JSON-RPC input, expected response IDs, and a timeout.
- Produces: `CodexAppServerTransport.exchange(executable:input:responseIDs:timeout:) async throws -> [Int: Data]`.

- [x] **Step 1: Write failing client and process transport tests**

Assert that the client sends `account/rateLimits/read` as ID 2, `config/read` as ID 3, and `model/list` as ID 4, requests all three response IDs, and that the process transport waits for and returns multiple matching JSON-RPC response lines while ignoring notifications.

- [x] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter CodexUsageClientTests`

Expected: compilation or assertion failure because the transport supports only one response ID.

- [x] **Step 3: Implement minimal multi-response collection**

Change the transport protocol and process session to collect expected IDs in a dictionary. Complete successfully only after every expected ID has arrived, retaining existing timeout, EOF, stderr sanitization, and process cleanup behavior.

- [x] **Step 4: Run the focused tests and verify GREEN**

Run: `swift test --filter CodexUsageClientTests`

Expected: all `CodexUsageClientTests` pass.

### Task 2: Resolve and display the active model

**Files:**
- Modify: `Sources/CCMeterCore/CodexUsageResponse.swift`
- Modify: `Sources/CCMeterCore/CodexUsageClient.swift`
- Test: `Tests/CCMeterCoreTests/CodexUsageResponseTests.swift`
- Test: `Tests/CCMeterCoreTests/CodexUsageClientTests.swift`

**Interfaces:**
- Consumes: rate-limit response, optional `config.model`, and optional model-list entries containing `model` and `displayName`.
- Produces: `CodexRateLimitsResponse.toUsage(now:unnamedCodexModelName:)` with unchanged stable limit identities.

- [x] **Step 1: Write failing model-label tests**

Cover active model catalog resolution, `7-day (GPT-5.6-Sol)` fallback for an unnamed `codex` group, explicit Spark-name precedence, missing metadata fallback, and unchanged `codex:codex:primary` identity.

- [x] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter 'CodexUsage(Response|Client)Tests'`

Expected: compilation or assertion failure because model metadata is not decoded or applied.

- [x] **Step 3: Implement minimal decoding and fallback labeling**

Decode the optional configuration and model catalog responses, resolve the active model to its display name, and use it only when `groupID == "codex"` and `limitName` is blank. Ignore malformed or error-bearing metadata responses while continuing to require a valid rate-limit response.

- [x] **Step 4: Run focused tests and verify GREEN**

Run: `swift test --filter 'CodexUsage(Response|Client)Tests'`

Expected: all focused tests pass.

### Task 3: Verify and commit

**Files:**
- Modify: `docs/superpowers/plans/2026-07-12-codex-active-model-label.md`

**Interfaces:**
- Consumes: completed implementation and regression tests.
- Produces: a verified feature commit ready to merge.

- [x] **Step 1: Run the full test suite**

Run: `swift test`

Expected: all tests pass with zero failures.

- [x] **Step 2: Review the diff and repository state**

Run: `git diff --check && git diff --stat && git status --short`

Expected: no whitespace errors and only intended source, test, and plan changes.

- [ ] **Step 3: Commit**

Run: `git add Sources/CCMeterCore/CodexUsageClient.swift Sources/CCMeterCore/CodexAppServerProcess.swift Sources/CCMeterCore/CodexUsageResponse.swift Tests/CCMeterCoreTests/CodexUsageClientTests.swift Tests/CCMeterCoreTests/CodexUsageResponseTests.swift docs/superpowers/plans/2026-07-12-codex-active-model-label.md && git commit -m "feat: label Codex usage with active model"`

Expected: one commit on `codex/sol-model-label`.
