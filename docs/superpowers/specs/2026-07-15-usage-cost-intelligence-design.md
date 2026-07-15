# Usage & Cost Intelligence (local-log token breakdown)

- **Date:** 2026-07-15
- **Status:** Approved design, pre-planning
- **Branch:** `feat/usage-breakdown`
- **Stream:** A of a two-stream effort (Stream B = provider incident/status, deferred to its own spec)

## 1. Motivation

cc-meter today only knows **"% of a rate-limit window used"**, pulled live from the Anthropic OAuth usage API (Claude) and the Codex app-server RPC (Codex). It never reads Claude Code's or Codex's local session logs, so it cannot answer:

- How many **tokens** have I actually burned in the current window?
- **Which project** is eating my quota right now?
- **Which model** is doing the damage (Opus vs Sonnet vs a Codex model)?

Inspired by `steipete/codexbar` (which does local cost scans and ships `codexbar cost`), but filtered hard for a **Claude Code + Codex** user on **subscriptions** (not per-token API billing). On a subscription, dollars are notional; tokens/quota are the real currency.

## 2. Locked decisions

| Decision | Choice |
|---|---|
| Headline metric | **Tokens/quota first.** Notional `$` shown only as a small "≈ $X on API rates" for-reference line, never a headline. |
| Time organization | **Rate-limit windows (5h / 7d)**, so numbers reconcile with the % already displayed. Not calendar periods. |
| Breakdowns (v1) | **Per-project** and **per-model** (+ window totals). Per-session deferred. |
| UI surface | A segmented **Limits / Usage** tab inside the existing popover, one provider at a time. |
| Chart | **Tokens consumed over the current window**, time-bucketed (per-hour for 5h, per-day for 7d). Not a `$` chart. |
| Parse strategy | **Hybrid incremental index** - background, offset+mtime cursors, cached aggregates; the tab reads the cache instantly. |
| Scope boundary | Parsed data feeds **only the Usage tab.** Menu-bar title, burn forecast, and notifications stay on the live rate-limit APIs. |

## 3. Data sources (verified on-machine 2026-07-15)

### 3.1 Claude Code
- **Location:** `~/.claude/projects/<sanitized-cwd>/<sessionId>.jsonl` (17 project dirs, 1475 files, 616 MB here).
- **Usage-bearing record:** `type == "assistant"` with `message.usage`:
  - `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` (nested `cache_creation.ephemeral_1h/5m` also present).
- **Attribution fields:** top-level `timestamp` (ISO-8601 UTC), `cwd` (real project path), `sessionId`, `requestId`; `message.model` (e.g. `claude-opus-4-8`), `message.id`.
- **⚠️ Dedup is MANDATORY.** Empirically the same logical message is written ~2× (2428 usage records → 1166 distinct `(requestId, message.id)` pairs; 770 pairs appear >1×). Without dedup we roughly double-count. **Dedup key = `(requestId, message.id)`** (mirrors ccusage). Every record carries `message.id`.
- **Skip:** `message.model == "<synthetic>"` records (injected, no real usage).

### 3.2 Codex
- **Location:** `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (7168 files, 16 GB here). Also a `session_index.jsonl` and a 168 MB `logs_2.sqlite` (not used - we parse rollout files directly for robustness).
- **Usage-bearing record:** `type == "event_msg"`, `payload.type == "token_count"`:
  - `payload.info.last_token_usage` = **per-turn delta** (`input_tokens`, `cached_input_tokens`, `output_tokens`, `reasoning_output_tokens`, `total_tokens`).
  - `payload.info.total_token_usage` = **cumulative** (do NOT sum this - overcounts).
  - Bonus: `payload.rate_limits` embeds `used_percent` / `window_minutes` / `resets_at` / `plan_type` - the same snapshot cc-meter fetches live. Not required for v1 but available.
- **⚠️ Delta gotcha:** sum `last_token_usage` only, never `total_token_usage`.
- **Attribution:**
  - `cwd`: in `session_meta.payload.cwd` **and** `turn_context.payload.cwd`.
  - `model`: in **`turn_context.payload.model`** (e.g. `gpt-5.6-sol`), **per-turn** - NOT in `session_meta` (which only has `model_provider`). The parser must track the most-recent `turn_context.model` as it walks the file and attach it to subsequent `token_count` events.
  - `timestamp`: top-level ISO-8601 UTC on each record.

### 3.3 Worktree normalization (both providers)
Worktree checkouts appear as separate projects: Claude `...--claude-worktrees-<name>` dirs and Codex `~/.codex/worktrees/<hash>/<project>` cwds. v1 groups by the **cwd leaf directory name** for display and applies a light normalization pass that maps known worktree path patterns back to the parent project name. If normalization is ambiguous, the raw leaf name is shown (worktrees may appear as siblings). Full worktree→parent mapping is a documented v1 simplification, refinable later.

## 4. Architecture

Follows cc-meter's existing split: **all logic in `CCMeterCore` behind injected fakes; only SwiftUI + real file I/O in the `cc-meter` executable.**

### 4.1 New in `CCMeterCore`
- **`FileSystemReading` (protocol)** - `listDirectory`, `attributes(path) -> (mtime, size)`, `read(path, fromOffset, length) -> Data`. Real impl lives in the executable; a fake feeds fixtures in tests so nothing touches real `~/.claude` / `~/.codex`.
- **`UsageLogLocator`** - resolves the Claude projects dir and Codex sessions dir; reports per-provider absence.
- **`ClaudeUsageLogParser`** - byte-range → `[UsageEvent]`. Extracts usage + `(requestId, message.id)`, `cwd`, `model`, `timestamp`; skips `<synthetic>`.
- **`CodexUsageLogParser`** - byte-range → `[UsageEvent]`. Sums `last_token_usage`; carries forward the latest `turn_context.model` + `session_meta.cwd` within the file.
- **`UsageEvent`** - `{ provider, timestamp, project, model, tokens: TokenCounts, dedupKey }`.
- **`TokenCounts`** - `{ input, output, cacheCreation, cacheRead, reasoning }` value type; helpers for total and for the pricing-billable split.
- **`ProjectNormalizer`** - cwd → display project name, with worktree normalization.
- **`UsageIndexer`** - the hybrid engine:
  - Per-file cursor `{ path, offset, mtime }` persisted to `usage-index-cursors.json`.
  - Each tick: enumerate files whose mtime is within the 7-day horizon; for each grown/changed file, read bytes past the stored offset; parse; fold into aggregates. **Never advance the cursor past a partial trailing line** (hold at last `\n`).
  - Dedup via a bounded LRU of recent `dedupKey`s.
  - Persists aggregates so tab opens are instant and survive restart.
- **`UsageAggregateStore`** - per-`(provider, project, model, hourBucket)` token sums, 7-day retention + compaction (mirrors `UsageHistory`). Current-window views are computed by summing buckets since `windowStart` (= live `resets_at` − window length), which is what makes them reconcile with the displayed %.
- **`ModelPriceTable`** - embedded `model → (inputPrice, outputPrice, cacheWritePrice, cacheReadPrice)` per-token map (Anthropic + OpenAI public rates), stamped with `pricesAsOf`. `notionalCost(TokenCounts, model)`. Unknown model ⇒ `$` shown as `n/a` (Codex internal names like `gpt-5.6-sol` may be unpriced).
- **`UsageDetailViewModel`** - observable; given store + live windows + selected provider + selected window, emits: total tokens, notional `$`, sorted project rows (with token-share %), model split, chart series.

### 4.2 New in `cc-meter` executable
- **`FileSystemReading` real impl** - Foundation `FileHandle`/`FileManager`; no sandbox concern (app is a non-sandboxed SPM binary).
- **`PopoverView`** additions - `Limits | Usage` segmented `Picker`; the Usage view renders window toggle (5h/7d), a lightweight hand-drawn SwiftUI bar chart (consistent with the app's hand-drawn ethos; Swift Charts is a possible swap-in), the project table, the model split, and the "≈ $X on API rates" line.
- **Settings** - `usageBreakdownEnabled` pref (default **on**) + a toggle in `SettingsView`. Off ⇒ indexer idle and the Usage tab hidden.

## 5. Data flow

```
background tick (poll cadence, background DispatchQueue like UsageHistory)
   └─ UsageIndexer.tick()
        ├─ enumerate recent files (mtime within 7d horizon)
        ├─ read bytes past each file cursor
        ├─ parse → [UsageEvent]  (dedup, Codex deltas, model carry-forward)
        ├─ fold into UsageAggregateStore  (per project/model/hour bucket)
        └─ persist aggregates + cursors

open popover → tap "Usage"
   └─ UsageDetailViewModel reads current aggregates + live windows → renders instantly
```

First-ever launch triggers one **background** index build with a small spinner in the tab; the main thread is never blocked (the #16 lesson).

## 6. UI (Usage tab)

Per the approved mock:
```
┌ [ Limits | Usage ]  Claude ▾ ┐
│ Window  ◉ 5h   ○ 7d          │
│ ▁▂▃▅▆▇  tokens this window   │
│ Project          tok    %win │
│  cc-meter       1.2M    38%  │
│  web            410k    13%  │
│ Model   opus 78%  sonnet 22% │
│ ≈ $3.10 on API rates         │
│ updated 1m · ↻  ⚙  ⏻         │
└──────────────────────────────┘
```
- **`%win`** = each project's **share of tokens** consumed in the window. UI copy notes it's an approximation (rate limits weight models differently, so token-share ≈ quota-share). Model-weighted quota-share is deferred.
- Provider picker reuses the existing dashboard provider selection; absent/signed-out providers are hidden (mirror existing Codex auto-hide).

## 7. Error handling & edge cases

- **Provider logs absent** → tab shows "No usage logs found" for that provider; provider hidden if entirely absent.
- **Partial/malformed lines** (file mid-write) → skip the bad line; hold cursor at last good newline; no double-count on next tick.
- **Codex overcount** → deltas only (`last_token_usage`), never cumulative. Covered by a test.
- **Claude ~2× duplication** → dedup on `(requestId, message.id)`. Covered by a test.
- **Bounded memory** → dedup LRU capped; aggregates are bucketed, not per-event, so memory stays flat across 616 MB / 16 GB of history.
- **First-parse cost** → horizon-limited to last-7-day files; background; progress state.
- **Clock / timezone** → UTC ISO-8601 in; window math keys off live `resets_at`; survive clock jumps like current code.
- **Price staleness / unknown model** → label "$ est." with a `pricesAsOf` tooltip; unknown model ⇒ `$ n/a`. Never authoritative.
- **Worktrees** → normalized where recognizable; otherwise shown as sibling projects (documented v1 limitation).

## 8. Testing (CCMeterCore + fakes)

- **Parsers:** fixture lines (Claude assistant record; Codex `token_count` + `session_meta` + `turn_context`) → expected `UsageEvent`s; `<synthetic>` skipped; Codex model carried from `turn_context`.
- **Dedup:** duplicated `(requestId, message.id)` across a resumed session → counted once.
- **Codex delta:** deltas vs cumulative → no overcount.
- **Window boundary:** events just before/after `windowStart` → correctly excluded/included.
- **Incremental:** append bytes to a file → only new events folded; cursor respected; partial trailing line not double-counted.
- **Pricing:** known tokens + model → expected notional `$`; unknown model → `n/a`.
- **View-model:** aggregates → correctly sorted project rows, share %, model split.
- **Retention/compaction:** buckets older than 7 days dropped.
- **Worktree normalization:** known worktree cwd → parent project name.
- Injected clock + fake `FileSystemReading` throughout; no test touches real logs.

## 9. Scope: v1 vs deferred

**v1:** everything above.

**Explicitly deferred:**
- Per-session breakdown.
- Calendar / trend (today / week / month) view.
- Driving the menu-bar title, notifications, or burn forecast from real tokens.
- Model-weighted quota-share (v1 uses token-share).
- Full worktree→parent mapping.
- The `cc-meter` CLI companion.
- Historical attribution beyond the live windows.

## 10. Risks / open questions

- **Codex `$` accuracy:** internal model names (`gpt-5.6-sol`) may be unpriced ⇒ `$ n/a`. Acceptable given tokens-first.
- **Log-format drift:** both CLIs may change their JSONL shape; parsers must fail soft (skip unrecognized records) and are the most likely maintenance point.
- **First-index latency on 16 GB:** mitigated by the 7-day horizon; worth measuring during implementation to confirm the tab's first-open spinner is brief.
