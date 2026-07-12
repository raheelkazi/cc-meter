# Codex Support Design

## Goal

Extend cc-meter into an automatically detected, dual-provider usage dashboard. When both Claude Code and Codex are available and signed in, the popover shows both. When Codex is absent, the current Claude-only experience remains unchanged.

## Product Behavior

- Keep the existing menu-bar app, settings, used/remaining toggle, refresh action, burn forecasts, caching, history, and notifications.
- Show provider sections stacked vertically in one popover: `Claude Code` followed by `Codex`.
- Show each detected provider's own hero and detail rows. A failure in one provider must not suppress valid data from the other.
- Derive the menu-bar badge from the highest used percentage among the most constrained visible limit for each provider.
- Refresh all detected providers concurrently on the configured polling interval and from the manual Refresh action.
- Hide Codex when no supported Codex executable is installed or Codex reports that no ChatGPT account is signed in.
- Once Codex has been detected successfully, show transient or compatibility errors in the Codex section while retaining its last good snapshot when the existing stale-data rules allow it.
- Prefix notifications with the provider name so equal window labels from different providers are unambiguous.

## Codex Integration Boundary

Use Codex's stable app-server protocol instead of reading OAuth credentials or calling an internal HTTP endpoint directly. On each refresh, cc-meter starts a short-lived `codex app-server --stdio` process, completes the required initialize handshake, requests `account/rateLimits/read`, decodes the matching response, and terminates the process.

The process invocation sends these newline-delimited messages in order:

```json
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"cc_meter","title":"cc-meter","version":"development"}}}
{"method":"initialized"}
{"method":"account/rateLimits/read","id":2}
```

The production client supplies the installed bundle version, with `development` as the fallback shown above. The reader ignores unrelated notifications and log lines and waits for response ID `2`. The subprocess has a bounded timeout. It is terminated on timeout, EOF before a matching response, or after a matching response has been decoded.

This boundary keeps Codex responsible for credential storage, account selection, and token refresh. cc-meter never reads, displays, persists, or modifies Codex OAuth tokens.

## Executable Discovery

Resolve the first executable Codex binary from these sources:

1. `/Applications/Codex.app/Contents/Resources/codex`
2. `~/Applications/Codex.app/Contents/Resources/codex`
3. The current process `PATH` via `/usr/bin/which codex`
4. `/opt/homebrew/bin/codex`
5. `/usr/local/bin/codex`
6. `~/.local/bin/codex`

The injected resolver used by core tests returns a URL and does no process work. The production resolver verifies that a candidate exists and is executable. A missing executable is treated as provider absence, not as a dashboard error.

## Domain Model and Components

### Provider identity

Add a stable provider identity with `claude` and `codex` cases plus user-facing names. Provider identity scopes caches, histories, notification IDs, notification copy, and dashboard sections.

### Provider meter

Retain `MeterViewModel` as the unit that owns one provider's fetch state, cached snapshot, burn history, backoff, display rows, and notifications. Give it provider metadata rather than merging both services into one `Usage` value. Existing Claude behavior remains represented by one instance; Codex uses a second instance.

### Dashboard model

Add a small main-actor dashboard model that owns the Claude and Codex meters and republishes changes needed by AppKit and SwiftUI. It provides:

- ordered visible provider meters;
- a combined loading/error state only for the menu-bar badge;
- the compact percentage and color from the highest used percentage among visible providers;
- fan-out methods for start, manual refresh, display-mode toggling, and preference updates.

Provider visibility is explicit. Claude remains visible. Codex begins as probing, becomes visible after a successful signed-in response, is hidden after a definitive absent/not-signed-in result, and remains visible across transient errors after it has produced data. Codex polling continues while its section is hidden so installing or signing in later is detected without restarting cc-meter.

### Codex app-server client

Add a `CodexUsageClient` conforming to `UsageFetching`. It depends on injected executable resolution and process transport interfaces so tests do not launch Codex. The platform implementation owns `Process`, stdin/stdout/stderr pipes, timeout, and termination. Core decoding and mapping remain independent of AppKit.

### Popover and menu bar

Refactor the existing provider-specific popover content into a reusable section view. The containing popover owns shared controls and renders the dashboard's visible sections. The menu-bar controller observes the dashboard instead of a single meter.

## Rate-Limit Mapping

The app-server response can contain a top-level `rateLimits` object and a `rateLimitsByLimitId` dictionary. Prefer the dictionary when it is present and non-empty because it contains independently named or model-scoped limits; otherwise map the top-level object. Do not also map the top-level object when the dictionary is used, because it commonly duplicates the default `codex` entry.

Each rate-limit object may contain `primary` and `secondary` windows with:

- `usedPercent` as the used percentage;
- `windowDurationMins` as the actual window length;
- `resetsAt` as Unix seconds;
- optional `limitName` for a model or separately scoped limit.

Map every present window. Build a stable display label from the duration:

- exact multiples of one week: `7-day`, `14-day`, and so on;
- exact multiples of one day: `1-day`, `2-day`, and so on;
- exact multiples of one hour: `1-hour`, `5-hour`, and so on;
- otherwise use the numeric duration followed by `-minute`, for example `90-minute`.

Append the non-empty `limitName` in parentheses when one is supplied. If multiple mapped windows would otherwise have the same label, append a stable limit identifier to preserve independent history and notification identity.

Codex does not expose Claude's `is_active` concept in this response, so all returned Codex windows are eligible when selecting its most constrained limit. Missing windows are ignored. Percentages continue through the existing clamping and color logic. A successful response with no usable windows is valid and renders `No active limits reported.`

## Storage and Compatibility

- Keep the existing Claude cache and history locations readable so upgrades do not discard current data.
- Store Codex cache and history separately under the existing cc-meter Application Support directory.
- Include provider identity in newly written notification keys and history identities.
- Do not migrate or reinterpret old Claude history samples.
- Keep the preferences schema and existing defaults unchanged. The used/remaining toggle and polling interval apply to both provider meters.
- Add no third-party Swift dependencies and retain macOS 13 and Swift tools 5.9 compatibility.

## Failure Handling

Codex-specific outcomes map as follows:

- executable not found: provider absent and hidden;
- rate-limit request returns an authentication error: provider not signed in and hidden until a later poll succeeds;
- process launch failure, timeout, premature EOF, temporary upstream failure, or app-server overload: transient Codex error that preserves last-known data once Codex has been detected;
- malformed protocol response: deterministic Codex error, visible once Codex is detected;
- unsupported Codex version or missing method: compatibility error that tells the user to update Codex;
- Claude failure: affects only the Claude section;
- Codex failure: affects only the Codex section.

Stderr is captured only for a bounded, sanitized diagnostic message. Credential material and full protocol payloads are never logged.

## Testing Strategy

All production behavior follows test-first red/green cycles.

Core tests cover:

- executable discovery order, executable validation, and absence;
- app-server initialize and request messages;
- ignoring notifications and unrelated response IDs;
- timeout, premature EOF, process-launch failure, protocol error, authentication error, and unsupported-method mapping;
- decoding a default primary/secondary response;
- preferring `rateLimitsByLimitId` without duplicating the top-level entry;
- named/model limit mapping;
- dynamic duration labels and duplicate-label disambiguation;
- missing windows and a successful empty response;
- independent Claude and Codex success, loading, hard-error, and transient stale states;
- hiding an absent or signed-out Codex provider and retaining visibility after transient failures;
- combined compact badge selection;
- dashboard fan-out for refresh, display mode, and preferences;
- provider-scoped cache/history/notification identity and provider-qualified notification copy;
- regression coverage for the existing Claude-only path.

Integration verification runs the entire Swift test suite and build. A manual smoke test uses an installed, signed-in Codex to confirm both sections render, Refresh updates both, the highest provider drives the menu-bar badge, and quitting leaves no child app-server process.

## Documentation

Update the README to describe dual-provider behavior, Codex requirements, the app-server protocol boundary, auto-detection, separate failures, and development commands. The documentation must state that cc-meter never reads or stores Codex OAuth tokens.

## Out of Scope

- API-key usage or billing limits for Codex API accounts.
- Codex login, logout, token refresh, account switching, or reset-credit redemption UI.
- A provider enable/disable preference.
- A long-lived shared app-server process.
- Direct calls to ChatGPT internal HTTP endpoints.
- Changes to notification thresholds, burn-rate math, or the existing visual color policy.
