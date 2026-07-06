# cc-meter: Homebrew distribution

- **Date:** 2026-07-06
- **Status:** Approved design, pending spec review
- **Author:** Raheel Kazi (with Claude Code)

## Overview

Make `cc-meter` installable without a git account or a manual `swift build`, for
a developer-ish audience, via a Homebrew tap. The target experience is:

```
brew install raheelkazi/tap/cc-meter
brew services start cc-meter
```

`brew upgrade` updates it; `brew services` manages login-persistence. No code
signing, no Apple Developer account, no pre-built release binaries to host.

## Goals

- A non-cloning install path: a user with Homebrew runs two commands and has the
  menu bar app running and starting at login.
- Free and low-maintenance: no paid Apple Developer account, no signed/notarized
  artifacts, no binary uploads per release.
- Updates are mechanical: tag a new version, bump the formula.

## Non-goals (this iteration)

- Code signing and notarization (not needed for the Homebrew path; Homebrew
  strips the download quarantine, and the binary reads the Keychain via
  `/usr/bin/security`, so no Gatekeeper or keychain-signature friction).
- A `.app` bundle (the bare menu bar accessory binary works under a LaunchAgent).
- In-app auto-update checking (Homebrew is the update mechanism).
- Distribution to fully non-technical users who lack Homebrew (would require a
  signed `.app` in a `.dmg` and a paid account - a separate future effort).

## Approach: formula that builds from source

A Homebrew **formula** (not a cask) that downloads a tagged source tarball and
builds it locally.

- **Why formula-from-source:** no artifact to build, sign, or host; Homebrew
  compiles `swift build -c release` on the user's machine and installs the
  binary. The only cost is a ~30s compile and a dependency on the Swift
  toolchain (Xcode Command Line Tools), which the developer audience already
  has.
- **Why not a cask:** a cask installs a pre-built artifact, which would mean
  building and uploading a binary every release, and a bare CLI binary is an
  awkward cask payload. No benefit for this audience.

## Persistence via `brew services`

The formula declares a `service` block so `brew services start cc-meter`
generates and loads a per-user LaunchAgent that runs the menu bar app and starts
it at login. This is the Homebrew-native replacement for the hand-rolled
`update.sh` + `~/Library/LaunchAgents/com.raheelkazi.cc-meter.plist`.

- `brew services start cc-meter` - run now and at login.
- `brew services restart cc-meter` - after an upgrade.
- `brew services stop cc-meter` - stop and disable.

The service runs the installed binary (`opt_bin/"cc-meter"`) as a user agent in
the GUI session, so the `NSStatusItem` appears in the menu bar (verified with the
equivalent manual LaunchAgent).

## Keychain access (unchanged)

The Homebrew-built binary is ad-hoc signed only, but token reads already go
through `/usr/bin/security` (Apple-signed, stable identity), so a single "Always
Allow" persists across rebuilds and upgrades. No distribution-specific change is
needed.

## Components to build

1. **Release tag `v0.1.0`** on `raheelkazi/cc-meter`. The formula pins to the
   GitHub-generated source tarball
   (`https://github.com/raheelkazi/cc-meter/archive/refs/tags/v0.1.0.tar.gz`) and
   its sha256.

2. **Tap repo `raheelkazi/homebrew-tap`** (public), containing
   `Formula/cc-meter.rb`. The name maps to `brew install raheelkazi/tap/cc-meter`.
   The formula:
   - `desc`, `homepage`, `url` (the v0.1.0 tarball), `sha256`, `license "MIT"`.
   - `depends_on :macos` and `depends_on xcode: :build` (Swift toolchain).
   - `def install`: `system "swift", "build", "--disable-sandbox", "-c",
     "release"` then `bin.install ".build/release/cc-meter"`.
   - `service do run [opt_bin/"cc-meter"]; keep_alive false; ... end`.
   - `test do` block that runs a trivial smoke check (e.g. the binary exists and
     is executable; a menu bar app has no meaningful `--version` yet, so the test
     stays minimal).

3. **README update** on `cc-meter`: a "Install with Homebrew" section with the
   two-line install, plus `brew services` start/stop/restart and the one-time
   "Always Allow" keychain note.

4. **Release/update runbook** (short doc or README section): to ship an update,
   tag a new `vX.Y.Z`, compute the tarball sha256, and bump `url` + `sha256` in
   the formula. Optionally note `brew bump-formula-pr` as the automated path.

5. **`LICENSE` file** on `cc-meter` (MIT) if not already present, so the
   formula's `license "MIT"` is accurate and `brew audit --strict` passes. This
   should exist before the `v0.1.0` tag so the tarball includes it.

## Open questions

None. Version is `v0.1.0`; tap is `raheelkazi/homebrew-tap`.

## Testing / verification

- `brew install --build-from-source ./Formula/cc-meter.rb` (or via the tap)
  compiles and installs the binary cleanly.
- `brew services start cc-meter` loads the agent and the menu bar item appears.
- `brew audit --strict --online raheelkazi/tap/cc-meter` passes (formula style
  and metadata).
- `brew uninstall cc-meter` and `brew services stop cc-meter` cleanly remove it.
