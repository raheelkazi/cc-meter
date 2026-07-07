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
views, Refresh to fetch immediately, and Quit to exit.

Usage refreshes every minute.

## How it works

- Token: macOS Keychain, generic password, service `Claude Code-credentials`.
- Endpoint: `GET https://api.anthropic.com/api/oauth/usage`.
- If the token has expired, the app shows a re-authenticate message; run `claude`
  to refresh it, and the meter recovers on the next poll.

## Development

    swift test     # run the unit tests (core logic)
    swift build    # build
    swift run cc-meter

The core logic (Keychain parse, HTTP client, decoding, usage color, view
model) lives in the `CCMeterCore` library and is unit-tested with injected
fakes. The `cc-meter` executable is thin AppKit/SwiftUI glue.

## Not yet implemented

Spend/credits row, threshold notifications, launch-at-login, preferences UI, and
automatic OAuth token refresh (v1 relies on the `claude` CLI keeping the Keychain
token fresh).
