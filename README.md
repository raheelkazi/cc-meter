# cc-meter

A native macOS menu bar app that shows your Claude Code usage limits in real
time: the 5-hour session window, the 7-day window, and any per-model weekly
limits. Each is color-coded by how much of the limit is used, like a fuel gauge
(green when plenty is left, amber past 50%, red past 90%), with a reset countdown.

It reads the OAuth token that the `claude` CLI stores in your macOS Keychain and
calls Anthropic's usage endpoint. No token is ever displayed or stored elsewhere.

## Install with Homebrew

    brew install raheelkazi/tap/cc-meter
    brew services start cc-meter

That builds cc-meter, installs it, and runs it as a menu bar app that starts at
login. The first time it reads your usage, macOS asks to allow `security` to
access your Keychain - click "Always Allow" once and it will not ask again.

Manage it with:

    brew services restart cc-meter   # after an upgrade
    brew services stop cc-meter      # stop and disable

Upgrade later with `brew upgrade cc-meter`.

## Requirements

- macOS 13 or later
- The `claude` CLI, signed in (`claude` and complete the login once)
- Swift toolchain (Xcode or the Swift command line tools)

## Run

    swift run cc-meter

The app runs as a menu bar accessory (no dock icon). Click the menu bar item for
the full breakdown. Use the Used/Left button to switch between used and remaining
views, Refresh to fetch immediately, Settings… to open preferences, and Quit to
exit.

Usage refreshes every minute by default (configurable in Settings).

## Features

- **Live meter** for the 5-hour session, 7-day, and per-model weekly windows,
  color-coded green/amber/red with a reset countdown.
- **Threshold notifications**: get a macOS notification when a limit crosses
  80% / 95% / 100% (configurable), plus an optional heads-up before the 5-hour
  window resets. Alerts are edge-triggered, so you get one per crossing and they
  re-arm after each window reset.
- **Burn-rate projection**: each row shows current burn, safe burn, and whether
  the limit is projected to exhaust before the reset.
- **Spend / extra-credits row**: rendered when the usage endpoint reports it.
- **Automatic token refresh**: on an expired token the app silently refreshes
  using the stored refresh token and retries, falling back to a re-authenticate
  message only if refresh isn't possible.
- **Preferences window**: poll interval, notification thresholds, default
  used/remaining view, history on/off, and launch-at-login.

## How it works

- Token: macOS Keychain, generic password, service `Claude Code-credentials`.
- Endpoint: `GET https://api.anthropic.com/api/oauth/usage`.
- On an expired token the app attempts a silent OAuth refresh and writes the new
  token back to the Keychain. If refresh isn't possible it shows a
  re-authenticate message; run `claude` and the meter recovers on the next poll.
- History is stored locally at
  `~/Library/Application Support/cc-meter/history.json`, bounded to the last 7
  days. Preferences are stored in `UserDefaults`.
- Launch-at-login installs a per-user LaunchAgent
  (`~/Library/LaunchAgents/com.raheelkazi.cc-meter.plist`).
- Notifications are delivered via `osascript` (macOS may ask you to allow
  notifications for Script Editor the first time).

## Development

    swift test     # run the unit tests (core logic)
    swift build    # build
    swift run cc-meter

The core logic (preferences, Keychain parse/write, token refresh, HTTP client,
decoding, usage color, burn-rate, history, notification rules, and the view
model) lives in the `CCMeterCore` library and is unit-tested with injected
fakes. The `cc-meter` executable is thin AppKit/SwiftUI glue plus the platform
adapters (Keychain/launchctl/osascript shell-outs).
