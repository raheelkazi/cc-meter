# Dual-Provider Menu-Bar Design

## Goal

Make the compact macOS menu-bar badge show Claude Code and Codex simultaneously when both providers have usable usage data, without making the single-provider or no-data states more verbose.

## Product Behavior

- When both providers have compact summaries, render them in fixed order as `Cl ● 62% · Cx ● 18%`.
- `Cl` always identifies Claude Code and `Cx` always identifies Codex.
- Color each provider's dot independently using its existing usage-severity color.
- Show each provider's own most constrained active limit percentage; do not collapse the pair to the higher percentage.
- When only one provider has a compact summary, retain the existing unlabeled form, such as `● 62%`.
- A hidden, signed-out, loading, or otherwise data-less Codex meter does not occupy space in the badge.
- If one provider has usable data and the other does not, render only the usable provider.
- If neither provider has usable data, retain the existing `CC ...`, `CC !`, and `CC` states.
- Keep the badge in the existing used-percentage semantics even when the popover is toggled to show remaining percentages.
- Set the status-item tooltip to full provider names and used percentages, for example `Claude Code 62% used · Codex 18% used`. Use the same fixed provider order and include only providers represented in the badge.

## Architecture

### Provider compact summary

Add a small value type in `CCMeterCore` containing:

- the `UsageProvider` identity;
- its rounded compact percentage;
- its `MeterColor`.

`DashboardViewModel` exposes an ordered collection of these summaries. Claude is appended when `claude.compact` is available. Codex is appended only when `showsCodex` is true and `codex.compact` is available. This collection is the single source of truth for the menu-bar title and tooltip.

Retain the existing `compact` property as the highest-percentage summary derived from the ordered collection. This preserves current loading/error behavior and avoids changing consumers that need the most constrained provider rather than the full pair.

### Menu-bar presentation

Add a pure, AppKit-independent formatter in `CCMeterCore`. It consumes the ordered provider summaries plus the dashboard loading/error flags and returns a presentation made of ordered text segments with optional `MeterColor`, along with an optional tooltip. This formatter owns abbreviations, separators, exact spacing, full tooltip names, and the existing empty-summary fallback strings.

The segment boundary makes dot coloring explicit without putting `NSColor` or `NSAttributedString` into the core module. It also makes exact title text, tooltip text, provider order, and both independent colors testable without launching a status item.

### Native menu-bar rendering

Keep `NSStatusItem` with variable length and continue using an attributed title; no custom status-item view is needed.

For two summaries, the formatter produces provider abbreviation, independently colored dot, percentage, and separator segments. For one summary, it produces the current colored-dot and percentage presentation without an abbreviation. `MenuBarController` converts those segments to an attributed title, mapping only colored segments through the existing `MeterColor` AppKit bridge, and applies the formatter's tooltip.

Provider abbreviations and full tooltip names are mapped from `UsageProvider`, so presentation does not depend on array position alone even though display order is fixed.

## Data Flow

1. Each `MeterViewModel` derives its compact percentage and severity color from its most constrained eligible limit.
2. `DashboardViewModel` turns available provider compacts into an ordered `[ProviderCompactSummary]`.
3. The core formatter turns those summaries and dashboard state flags into title segments and tooltip text.
4. `MenuBarController` observes dashboard changes and renders the formatter's presentation.
5. Missing provider summaries are omitted without suppressing valid data from the other provider.
6. When the collection is empty, the formatter uses the existing loading, error, or idle title.

## Failure and Transitional States

- Claude usable, Codex probing or hidden: show Claude alone.
- Codex usable, Claude unauthorized or failed: show Codex alone.
- Both usable: show the labeled pair.
- A provider showing a retained last-good snapshot remains eligible because its meter still supplies a compact summary.
- Neither usable and at least one visible provider loading: show `CC ...`.
- Neither usable and at least one visible provider errored: show `CC !`.
- Neither usable and neither loading nor errored: show `CC`.

## Testing Strategy

Use test-first red/green cycles.

Core dashboard tests cover:

- two summaries in fixed Claude-then-Codex order;
- independent percentages and colors;
- hidden or data-less Codex omission;
- Codex-only output when Claude has no usable data;
- the retained highest-percentage `compact` behavior;
- existing loading and error fallbacks when the collection is empty.

The core menu-bar formatter is deterministic and independently testable. Formatter tests cover:

- exact labeled-pair text;
- independent color ranges for both dots;
- the unchanged single-provider text;
- full-name tooltip text and ordering;
- empty-summary fallback selection.

Run the full Swift test suite and a production build. A manual smoke test confirms that the installed status item widens to show both providers, updates both percentages after Refresh, and collapses cleanly when Codex becomes unavailable.

## Compatibility and Constraints

- Retain macOS 13 and Swift tools 5.9 compatibility.
- Add no third-party dependencies.
- Do not change provider fetching, storage, history, notifications, burn forecasts, or polling.
- Do not add a new preference for menu-bar layout in this change.
- Do not replace the native status item with a custom view.

## Out of Scope

- Official Claude or Codex logo artwork.
- User-configurable provider order or abbreviations.
- A stacked, animated, rotating, or graph-based status item.
- Showing every model-scoped Codex quota in the menu bar; Codex continues to contribute its single most constrained compact percentage.
