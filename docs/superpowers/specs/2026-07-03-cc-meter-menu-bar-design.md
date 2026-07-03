# cc-meter: macOS menu bar usage meter for Claude Code

- **Date:** 2026-07-03
- **Status:** Approved design, pending spec review
- **Author:** Raheel Kazi (with Claude Code)

## Overview

`cc-meter` is a native macOS menu bar app that shows your Claude Code usage
limits in real time. It reads the OAuth token that the `claude` CLI stores in
the macOS Keychain, calls Anthropic's OAuth usage endpoint, and renders a live,
color-coded meter of how close you are to your rolling usage limits.

It is inspired by [claude-code-meter](https://github.com/gxjansen/claude-code-meter),
an Ubersicht desktop widget, but takes a different form factor (menu bar app,
no host framework) and uses the richer modern shape of the usage endpoint.

## Goals

- See at a glance, from the menu bar, how close you are to being throttled.
- Show all rolling windows the endpoint reports: 5-hour session, 7-day all
  models, and 7-day per-model scoped limits.
- Color-code each window by burn rate (are you spending faster than
  sustainable?), plus a reset countdown for each.
- Be a self-contained standalone app: no Ubersicht, no SwiftBar, no host
  framework. Build from the command line with Swift Package Manager.

## Non-goals (v1)

Deferred to keep v1 focused:

- Spend / extra-credits row (the endpoint returns it; we just do not render it
  yet).
- Threshold notifications (e.g. alert at 80%).
- Launch-at-login.
- Preferences UI (interval, theme, etc. are constants in v1).
- Historical graphs / trend tracking.

## Data source

- **Token:** macOS Keychain, generic password, service `Claude Code-credentials`,
  account = the macOS username. The secret is a JSON blob of the form
  `{"claudeAiOauth":{"accessToken":"...","refreshToken":"...","expiresAt":<ms>,...}}`.
- **Endpoint:** `GET https://api.anthropic.com/api/oauth/usage`
- **Headers:** `Authorization: Bearer <accessToken>`,
  `anthropic-beta: oauth-2025-04-20`, `Content-Type: application/json`
- **Response shape** (verified live on 2026-07-03), fields we use:
  - `five_hour`: `{ utilization: Int (percent), resets_at: ISO8601 }`
  - `seven_day`: `{ utilization: Int (percent), resets_at: ISO8601 }`
  - `limits: [ { kind, group, percent, severity, resets_at, is_active,
    scope: { model: { display_name } } | null } ]`
    - `kind` is one of `session`, `weekly_all`, `weekly_scoped`.
    - `weekly_scoped` entries carry `scope.model.display_name` (e.g. "Fable")
      and are the per-model weekly limits.
  - Other fields (`extra_usage`, `spend`, etc.) are ignored in v1.

## Architecture

Three units with clear boundaries. Units 1 and 2 have no UIKit/AppKit
dependency and are unit-testable in isolation.

### 1. `UsageClient` (data core)

- **Does:** returns a decoded `Usage` value, or a typed error.
- **How:** reads the Keychain blob, extracts `accessToken`, calls the endpoint,
  decodes the JSON into a typed `Usage` model. On HTTP 401 it attempts one token
  refresh (see below) and retries once.
- **Depends on:** `Security.framework` (Keychain), `URLSession`. Nothing else.
- **Interface:** `func fetch() async -> Result<Usage, UsageError>`

### 2. `MeterViewModel` (state + logic)

- **Does:** owns the polling timer, current state, and derived display values.
- **How:** every `refreshInterval` (default 30s) calls `UsageClient.fetch()` and
  publishes a `MeterState` (`.loading`, `.ok(Usage)`, `.error(UsageError)`).
  Computes burn-rate color per window and holds the Remaining/Used toggle.
- **Depends on:** `UsageClient` only.
- **Interface:** observable `state`, `displayMode` (`.remaining`/`.used`),
  `func refreshNow()`, `func toggleMode()`.

### 3. `MenuBarController` (UI)

- **Does:** owns the `NSStatusItem` and an `NSPopover` hosting a SwiftUI view.
- **How:** the status item shows a colored dot + the percent of the most
  constrained *active* limit. Clicking opens the popover with the full
  breakdown. Subscribes to `MeterViewModel.state`.
- **Depends on:** `AppKit`, `SwiftUI`, `MeterViewModel`.

## Display spec

### Menu bar (compact)

- Text: `<dot> NN%` where `NN` is the percent of the most constrained limit that
  is currently `is_active` (falls back to the max of all windows if none are
  active). `<dot>` is a filled circle in the burn-rate color.

### Popover (full breakdown)

One row per window, ordered: 5-hour, 7-day all, then each 7-day scoped model.

- Each row: label, a horizontal progress bar in the burn-rate color, the percent
  (remaining or used per the toggle), and `resets in Xh Ym`.
- Footer controls: **Remaining / Used** toggle, **Refresh** button, **Quit**.
- A small "updated Xs ago" / "stale" indicator when data is old.

## Burn-rate color logic

Mirrors the reference project's philosophy: compare how much you have used to how
far you are through the window.

- `elapsed_fraction = (window_length - time_until_reset) / window_length`
  - `window_length` is 5h for the session window and 7d for weekly windows.
  - `time_until_reset = resets_at - now`.
- Let `used = utilization / 100`.
- Color:
  - `used <= elapsed_fraction * GREEN_FACTOR` -> **green** (at or under a
    sustainable pace)
  - `used <= elapsed_fraction * AMBER_FACTOR` -> **amber** (elevated pace)
  - else -> **red** (burning too fast)
- **Override:** if remaining (`100 - utilization`) is below 10%, force **red**
  regardless of pace.
- `GREEN_FACTOR` / `AMBER_FACTOR` are tunable constants (start ~1.0 and ~1.5);
  final values chosen during implementation against real data.

## Token refresh

- The `claude` CLI normally keeps the Keychain token fresh, so most polls
  succeed with the stored `accessToken`.
- On HTTP 401, `UsageClient` attempts one refresh using the `refreshToken` and
  `expiresAt` from the blob, writes the new token back to the Keychain, and
  retries the request once.
- **Known unknown:** the exact OAuth refresh endpoint and client_id used by
  Claude Code must be confirmed during implementation (by inspecting how the
  `claude` CLI refreshes). If refresh cannot be implemented reliably in v1, the
  fallback is to skip auto-refresh and surface the re-authenticate error state
  below, telling the user to run `claude` to re-auth. Either way v1 never
  silently shows stale/blank data.

## Error states

Each maps to a distinct, friendly popover state (never a crash or blank bar):

- **No credentials:** Keychain item missing or blob unparseable -> "Not signed
  in. Run `claude` to authenticate."
- **Expired / invalid token:** refresh failed or 401 persists -> "Session
  expired. Run `claude` to re-authenticate."
- **Rate limited (429):** back off (skip to the next interval), show last-known
  data marked stale.
- **Network error:** show last-known data marked stale with a retry affordance.

## Polling

- Default interval: **30s**. Manual **Refresh** available. On 429, back off to
  the next scheduled tick rather than hammering. The menu bar always reflects the
  most recent successful fetch.

## Build and tooling

- **Language:** Swift. **UI:** AppKit `NSStatusItem` + `NSPopover` hosting a
  SwiftUI view.
- **Target:** macOS 13+.
- **Build system:** Swift Package Manager, executable target, buildable from the
  command line (`swift build`). No Xcode project file required; runs as a menu
  bar accessory app (`LSUIElement`, no dock icon).
- **Tests:** unit tests for `UsageClient` JSON decoding and for the burn-rate
  color function, using recorded sample responses. No live-network tests in CI.

## Open questions

1. Exact OAuth refresh endpoint / client_id (see Token refresh). Resolve during
   implementation; fallback defined above.
2. Final `GREEN_FACTOR` / `AMBER_FACTOR` values, tuned against real usage.
