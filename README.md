# cc-meter

A native macOS menu bar app that shows your Claude Code usage limits in real
time: the 5-hour session window, the 7-day window, and any per-model weekly
limits. Each is color-coded by burn rate (green sustainable, amber elevated, red
burning fast, and red when under 10% remaining) with a reset countdown.

It reads the OAuth token that the `claude` CLI stores in your macOS Keychain and
calls Anthropic's usage endpoint. No token is ever displayed or stored elsewhere.

## Requirements

- macOS 13 or later
- The `claude` CLI, signed in (`claude` and complete the login once)
- Swift toolchain (Xcode or the Swift command line tools)

## Run

    swift run cc-meter

The app runs as a menu bar accessory (no dock icon). Click the menu bar item for
the full breakdown. Use the Used/Left button to switch between used and remaining
views, Refresh to fetch immediately, and Quit to exit.

Usage refreshes every 30 seconds.

## How it works

- Token: macOS Keychain, generic password, service `Claude Code-credentials`.
- Endpoint: `GET https://api.anthropic.com/api/oauth/usage`.
- If the token has expired, the app shows a re-authenticate message; run `claude`
  to refresh it, and the meter recovers on the next poll.

## Development

    swift test     # run the unit tests (core logic)
    swift build    # build
    swift run cc-meter

The core logic (Keychain parse, HTTP client, decoding, burn-rate color, view
model) lives in the `CCMeterCore` library and is unit-tested with injected
fakes. The `cc-meter` executable is thin AppKit/SwiftUI glue.

## Not yet implemented

Spend/credits row, threshold notifications, launch-at-login, preferences UI, and
automatic OAuth token refresh (v1 relies on the `claude` CLI keeping the Keychain
token fresh).
