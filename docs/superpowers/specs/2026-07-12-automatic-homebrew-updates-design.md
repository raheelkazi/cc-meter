# Automatic Homebrew Updates Design

## Goal

Allow Homebrew service installations of cc-meter to install future cc-meter releases silently, restart into the new binary, and recover safely from update failures without requiring users to run `brew upgrade` manually.

Version `v0.4.3` is the bootstrap release. Existing users must install it once through Homebrew; releases after it are eligible for automatic installation.

## Product Behavior

- Add `Automatically install cc-meter updates` to Settings.
- Default the preference to enabled, including for existing preference blobs that predate the field.
- Begin the first due check five minutes after launch so usage loading and menu-bar startup remain the priority.
- Perform at most one Homebrew check in any rolling 24-hour period. An hourly lightweight timer only evaluates whether a check is due; it does not invoke Homebrew when the persisted check time is recent.
- Update only `raheelkazi/tap/cc-meter`; do not upgrade unrelated formulae or casks.
- Keep successful no-update checks and successful installations silent.
- After a successful installation, restart automatically into the new binary.
- On failure, keep the current process and version running, write a bounded local diagnostic, post one failure notification for that attempt, and wait until the next daily check.
- Disabling automatic updates cancels future scheduled checks. Re-enabling permits a check once the persisted 24-hour interval is due.
- Manual Quit remains a clean exit and must not relaunch the app.
- Manual or source-built runs skip automatic updates. The Settings toggle remains visible in an `Updates` card with the caption `Available for Homebrew service installations.`

## Homebrew and Service Eligibility

Automatic updating is eligible only when all of these are true:

1. The preference is enabled.
2. The process environment contains `XPC_SERVICE_NAME=homebrew.mxcl.cc-meter`, proving the current process is managed by the Homebrew LaunchAgent.
3. An executable Homebrew binary exists at `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`, in that order.

Do not invoke a login shell or search arbitrary `PATH` entries. Known executable paths plus fixed argument arrays keep command construction deterministic and prevent shell injection.

## Components

### Preferences

Extend `Preferences` with `automaticUpdatesEnabled: Bool`, defaulting to `true`. Include it in coding keys, lenient decoding, equality, in-memory storage, and the Settings view. Existing stored preferences decode the missing field as enabled.

`AppDelegate.applyPreferences` forwards changes to the update controller as well as the dashboard so disabling the setting takes effect immediately.

### Auto-update controller

Add a main-actor `AutoUpdateController` responsible for:

- the five-minute initial scheduling delay;
- the hourly due-state timer;
- the persisted last-attempt date;
- single-flight protection;
- applying preference changes;
- mapping update outcomes to silence, failure notification, or restart.

The controller depends on injected time, scheduling, preference-state storage, updater, notification, logger, and exit closures so unit tests do not invoke Homebrew, wait for real timers, post notifications, or terminate the test process.

Check updater eligibility before scheduling. Unsupported manual/source runs create no timer, invoke no Homebrew command, and do not write a last-attempt date.

Record the attempt time immediately before invoking Homebrew. A failure therefore does not create a tight retry loop across app restarts. Persist it in `UserDefaults` under a separate key from the preferences JSON.

### Homebrew updater

Add a process-backed updater with four outcomes:

- `unsupported`: the service environment or Homebrew executable is absent;
- `upToDate`: Homebrew reports no cc-meter upgrade;
- `updated`: the targeted upgrade completes successfully;
- `failed(UpdateFailure)`: a command fails, times out, or returns an unexpected result.

Run this fixed sequence:

```text
brew update-if-needed
brew outdated --quiet --formula raheelkazi/tap/cc-meter
brew upgrade --formula raheelkazi/tap/cc-meter   # only when outdated output names cc-meter
```

`update-if-needed` is Homebrew's documented fast no-op-friendly update command for scripts, while a named `upgrade` limits installation to the specified formula. Homebrew remains responsible for fetching the tap, verifying the formula's source checksum, compiling, installing, linking, and cleaning old versions.

Run each process asynchronously so the menu-bar UI remains responsive. Use a 2-minute timeout for metadata commands and a 15-minute timeout for the build/install command. Capture a maximum of 64 KiB across stdout and stderr for diagnostics. Terminate a timed-out child process and classify it as failure.

Treat `outdated` output as exact newline-delimited formula names. Upgrade only if a trimmed line equals `cc-meter` or `raheelkazi/tap/cc-meter`; never interpolate command output into a subsequent command.

### Restart behavior

After `brew upgrade` succeeds, call an injected exit closure with status `75` (`EX_TEMPFAIL`). The Homebrew LaunchAgent already uses `KeepAlive` with `SuccessfulExit=false`, so the nonzero exit causes launchd to start the program path again. The path is `/opt/homebrew/opt/cc-meter/bin/cc-meter` or its Intel equivalent and now resolves to the newly installed keg.

The new process sees the persisted recent attempt and does not run another update. Normal Quit continues through the existing clean termination path and remains non-restarting.

Never use the nonzero restart path outside an eligible Homebrew service process.

### Diagnostics and notifications

Write update diagnostics to `~/Library/Logs/cc-meter/update.log`. Keep at most 64 KiB, retaining the newest entries when trimming. Include timestamps, command stage, exit status or timeout, and bounded process output. Do not log environment variables or usage-provider payloads.

Post failures through the existing `Notifying` boundary with stable ID `cc-meter-auto-update-failed`, title `cc-meter update failed`, and concise body directing the user to the log. This operational notification is emitted whenever automatic updating is enabled even if usage-threshold notifications are disabled.

Successful checks and upgrades do not post notifications.

## App Lifecycle Integration

`AppDelegate` creates the updater and controller after loading preferences, starts scheduling after the dashboard and menu-bar controller are installed, and retains the controller for the process lifetime. Preference changes update both dashboard behavior and auto-update enablement.

The updater does not block provider refreshes, mutate provider state, or reuse usage polling timers.

## Release Workflow

Keep the existing release workflow:

1. Merge and verify `main`.
2. Push a version tag.
3. Update the tap formula URL and SHA-256.
4. Push the tap.

Once a client has `v0.4.3`, its next due check refreshes Homebrew metadata, detects the newly published formula version, installs only cc-meter, and restarts it. No appcast, prebuilt binary archive, Sparkle key, or additional Homebrew tap is introduced.

## Failure Handling

- Automatic updates disabled: schedule no Homebrew work.
- Manual/source run: return `unsupported` silently.
- Homebrew missing or non-executable: return `unsupported` silently.
- Another update already running: ignore the overlapping tick.
- `update-if-needed` failure or timeout: log, notify, keep current version.
- `outdated` failure or timeout: log, notify, keep current version.
- No exact cc-meter line in outdated output: return `upToDate` silently.
- Upgrade failure or timeout: log, notify, keep current version.
- Upgrade success: persist state is already current, then exit 75 for launchd restart.
- App terminates during a Homebrew command for an unrelated reason: the next eligible daily attempt re-evaluates Homebrew's installed state instead of assuming the prior attempt completed.

## Testing Strategy

Follow test-first red/green cycles.

Core and controller tests cover:

- new preferences default, round trip, and legacy decode;
- Settings changes propagated to the controller;
- five-minute initial delay and 24-hour persisted due interval;
- disabled and recently checked states invoking no updater;
- single-flight behavior;
- `unsupported` and `upToDate` remaining silent;
- `updated` invoking exit status 75 exactly once;
- failure logging and notification without exit;
- no automatic retry before 24 hours.

Process updater tests use temporary fake executables and cover:

- Apple Silicon and Intel Homebrew resolution order;
- service-environment eligibility;
- exact command arguments and ordering;
- no upgrade when exact outdated output is absent;
- upgrade when `cc-meter` or its tap-qualified name is present;
- nonzero exits, bounded stdout/stderr, and timeouts;
- output text never becoming command arguments.

Logger tests cover file creation, append behavior, and 64 KiB retention. Full verification runs `swift test`, a release build, Homebrew formula audit/style, and an installed-service smoke test. The smoke test uses a harmless fake updater result for restart behavior; it must not downgrade or republish a real formula.

## Documentation

Update README installation and upgrade guidance to explain:

- `v0.4.3` as the one-time bootstrap upgrade;
- daily silent targeted updates enabled by default;
- the Settings opt-out;
- Homebrew-service-only eligibility;
- failure log location;
- the unchanged manual `brew upgrade cc-meter` recovery command.

Update release documentation to state that pushing the tap is the event automatic clients observe.

## Compatibility and Constraints

- Retain macOS 13 and Swift tools 5.9 compatibility.
- Add no third-party Swift dependencies.
- Preserve the current source-built Homebrew formula and LaunchAgent service.
- Never run Homebrew through a shell command string.
- Never upgrade unrelated packages.
- Never directly download, install, or execute a binary outside Homebrew.
- Never require administrator privileges or a password prompt.
- Keep provider polling and update scheduling independent.

## References

- [Homebrew manual](https://docs.brew.sh/Manpage), including `update-if-needed`, `outdated`, and targeted `upgrade` behavior.
- [Homebrew Autoupdate](https://github.com/DomT4/homebrew-autoupdate), considered but not selected because it requires a separate tap, explicit trust, and external client configuration.
- [Sparkle documentation](https://sparkle-project.org/documentation/), considered as a future option if cc-meter migrates to a signed application-bundle distribution.

## Out of Scope

- Updating clients older than the bootstrap release without one manual upgrade.
- Sparkle, appcasts, signed `.app` bundles, casks, notarization, or prebuilt archives.
- Automatic updates for manual `swift run`, copied binaries, or non-Homebrew package managers.
- Release channels, prereleases, staged rollouts, rollback UI, or downgrade support.
- Automatically updating Homebrew itself beyond `brew update-if-needed` metadata behavior.
