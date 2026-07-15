# Provider Incident/Status Monitoring (Stream B)

- **Date:** 2026-07-15
- **Status:** Approved design, pre-planning
- **Branch:** `feat/provider-status`
- **Stream:** B of a two-stream effort (Stream A = usage/cost intelligence, merged as v0.7.0)

## 1. Motivation

cc-meter shows your rate-limit usage, but when Claude Code or Codex starts failing you can't tell from the menu bar whether it's you (network, quota) or the provider. This adds a passive **incident/status** indicator: poll the official status pages, and when the component you actually depend on is degraded, show a warning in the menu bar and a banner in the popover. Answers "is it me or is Anthropic/OpenAI down?" at a glance.

Inspired by `steipete/codexbar`'s incident badges, scoped to Claude + Codex.

## 2. Locked decisions

| Decision | Choice |
|---|---|
| Menu-bar cue | Replace the degraded provider's colored dot with a **⚠ glyph** (amber for degraded, red for major), keep the percentage. |
| Popover | A **banner per degraded provider**: provider · incident headline · impact, with a link to the status page. Reuses the critical-alert banner styling. |
| Notifications | **None in v1** - passive display only (menu bar + popover). |
| Detection | **Component-filtered** to the components each provider depends on, with fallback to the overall status indicator. |
| Poll cadence | **Dedicated slow poll (~5 min)**, separate from usage polling. |
| Scope boundary | Read-only status display. Never affects usage fetching, notifications, or the burn forecast. |
| False-alarm rule | A status-*fetch* failure (our network) must NEVER show a ⚠ - we only ever report degradation the status page actually reports. |

## 3. Data sources (verified on-machine 2026-07-15)

Both are Atlassian **Statuspage v2** APIs returning `summary.json`:

- **Claude**: `https://status.claude.com/api/v2/summary.json`. (`https://status.anthropic.com/...` returns a 302 redirect here - follow redirects, or hit `status.claude.com` directly.)
- **OpenAI/Codex**: `https://status.openai.com/api/v2/summary.json`.

Relevant JSON subset:
```
{
  "status": { "indicator": "none|minor|major|critical", "description": "All Systems Operational" },
  "components": [ { "name": "Claude Code", "status": "operational|degraded_performance|partial_outage|major_outage|under_maintenance", "group": false }, ... ],
  "incidents": [ { "name": "...", "impact": "none|minor|major|critical", "status": "investigating|identified|monitoring|...", "shortlink": "https://stspg.io/..." }, ... ]
}
```

**Component filters (verified names):**
- **Claude** (`.claude` provider): components whose name contains **"Claude Code"** or **"Claude API"** (exact: `"Claude Code"`, `"Claude API (api.anthropic.com)"`).
- **Codex** (`.codex` provider): components whose name contains **"Codex"** (exact: `"Codex API"`; also `"Codex in ChatGPT Desktop"`).
- If no component name matches (name drift), fall back to the top-level `status.indicator`.

## 4. Status level derivation

A single `StatusLevel` per provider, worst-of across relevant components and active incidents:

- **Component status → level:** `operational`/`under_maintenance` → `ok`; `degraded_performance`/`partial_outage` → `degraded`; `major_outage` → `major`.
- **Active incident impact (only incidents that affect a relevant component, or - when we can't map components - any active incident) → level:** `none` → `ok`; `minor` → `degraded`; `major`/`critical` → `major`.
- The provider's level is the max of all the above. `ok` shows no cue.
- Carry, for the banner: the highest-impact active incident's `name` (headline) and `shortlink` (or the provider's status-page URL if no shortlink), plus the human `description`.

Statuspage doesn't always link incidents to components in `summary.json`; v1 treats any active incident with impact ≥ minor as affecting the provider (conservative - better a banner than a missed outage), while component status gives the precise signal when no incident object is present.

## 5. Architecture

Logic in `CCMeterCore` behind the existing HTTP `Transport` seam (the same one `UsageClient` uses); UI + wiring in the `cc-meter` executable.

### New in `CCMeterCore`
- **`StatusLevel`** enum `{ ok, degraded, major }` with a `MeterColor?` (nil / amber / red).
- **`ProviderStatus`** value type `{ provider: UsageProvider, level: StatusLevel, headline: String?, detail: String?, url: URL? }`.
- **`StatusSummary` decoding** - lenient Codable over the summary.json subset above (unknown fields ignored; unknown status/impact strings decode to a safe default).
- **`ProviderStatusEvaluator`** - pure function `evaluate(summary, provider) -> ProviderStatus` implementing the component filter + worst-of derivation. Fully unit-tested from fixtures.
- **`StatusClient`** (protocol + `HTTPStatusClient` impl) - `func fetch(_ provider) async -> ProviderStatus?` via `Transport` to the provider's status URL; returns `nil` on any fetch/decoding failure (never a fabricated degradation).
- **`StatusMonitor`** (`@MainActor ObservableObject`) - holds `@Published var status: [UsageProvider: ProviderStatus]`, polls both providers on a slow `Timer` (default 300s, injectable), keeps last-known status on a failed fetch, publishes on change. Injected clock + client for tests.

### New/changed in `cc-meter` executable
- **`MenuBarPresentation`** - accepts per-provider status and renders `⚠` (colored) in place of the dot for a degraded/major provider.
- **`PopoverView`** - an incident banner section (styled like the existing `alertView`) shown per degraded provider, with the headline, impact, and a clickable status-page link (`NSWorkspace.open`).
- **`DashboardViewModel`** - exposes the current `[UsageProvider: ProviderStatus]` (forwards `StatusMonitor`), so the menu bar and popover read one source.
- **`AppDelegate`** - constructs `StatusMonitor` (reusing the existing transport), starts it, wires it into the dashboard/menu bar.

## 6. Polling & threading
`StatusMonitor` runs its own `Timer` at ~300s (status changes slowly; be a good citizen to the status pages). Fetches are `async` on the URLSession; results publish on the main actor. Independent of the usage poll timer. No disk persistence needed (status is ephemeral; last-known kept in memory).

## 7. Error handling
- **Fetch/parse failure** → `StatusClient.fetch` returns `nil`; `StatusMonitor` keeps the last-known status (or "unknown" = no cue). **Never** renders a ⚠ from our own failure.
- **Redirect** (anthropic→claude.com) → follow redirects (URLSession default) or target `status.claude.com` directly.
- **Schema drift** → lenient decoding; unknown component-status / incident-impact strings map to the safe (`ok`/`none`) bucket, so a new Statuspage value can't crash or false-alarm.
- **Provider hidden** (e.g. Codex signed out) → no status cue for a provider that isn't shown.

## 8. Testing (CCMeterCore + fakes)
- `StatusSummary` decoding: operational; a degraded relevant component; an active major incident; unknown status/impact strings tolerated.
- `ProviderStatusEvaluator`: Claude filter matches "Claude Code"/"Claude API" and ignores "claude.ai"; Codex filter matches "Codex API"; worst-of across components + incidents; incident-impact → level; fallback to `status.indicator` when no component matches.
- `StatusLevel` → color/glyph mapping.
- `StatusClient`: fetch success → `ProviderStatus`; transport failure/garbage body → `nil`.
- `StatusMonitor`: polls, publishes on change, and a failed fetch keeps last-known (no false degrade); injected clock/client.
- `MenuBarPresentation`: renders ⚠ (colored) for a degraded provider, normal dot otherwise.

## 9. Scope: v1 vs deferred
**v1:** the above - passive menu-bar ⚠ + popover banner for Claude + Codex, component-filtered, slow poll.

**Deferred:** notifications on new incident, historical/past-incident list, scheduled-maintenance display, correlating status with cc-meter's own request failures (a "your calls are failing AND there's an incident" corroboration), and any provider beyond Claude/Codex.

## 10. Risks
- **Component-name drift** on the status pages would silently fall back to the overall indicator (less precise, still safe). Low-cost to re-pin later.
- **Incident/component linkage**: `summary.json` doesn't reliably link incidents to components, so an active minor incident anywhere on the provider shows a banner even if the specific component we care about is green. Conservative by design; can tighten later using the incidents API's `components` array if it proves noisy.
