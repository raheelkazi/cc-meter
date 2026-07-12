# Automatic Homebrew Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bootstrap cc-meter `v0.4.3` so Homebrew service installations silently install only future cc-meter releases once daily and restart safely into the new binary.

**Architecture:** A process-backed `HomebrewUpdater` owns exact fixed Homebrew commands, while an injected `AutoUpdateController` owns eligibility, cadence, persistence, single-flight behavior, failure reporting, and restart status. Preferences and lifecycle wiring stay thin; command execution and scheduling remain independently testable.

**Tech Stack:** Swift 5.9, Foundation `Process`, Combine, AppKit/SwiftUI, XCTest, Homebrew, launchd, macOS 13.

## Global Constraints

- Retain macOS 13 and Swift tools 5.9 compatibility.
- Add no third-party Swift dependencies.
- Preserve the source-built Homebrew formula and `homebrew.mxcl.cc-meter` LaunchAgent.
- Never invoke Homebrew through a shell command string or arbitrary `PATH` lookup.
- Never upgrade a package other than `raheelkazi/tap/cc-meter`.
- Never download or install a binary outside Homebrew.
- Never require administrator privileges or a password prompt.
- Run only from the eligible Homebrew service environment.
- Keep provider polling and automatic-update scheduling independent.
- Keep success silent; log and notify once per failed daily attempt.

---

### Task 1: Add the default-on update preference and Settings control

**Files:**
- Modify: `Sources/CCMeterCore/Preferences.swift`
- Modify: `Sources/cc-meter/SettingsView.swift`
- Modify: `Tests/CCMeterCoreTests/PreferencesTests.swift`

**Interfaces:**
- Consumes: the existing lenient `Preferences` Codable model and Settings working copy.
- Produces: `Preferences.automaticUpdatesEnabled: Bool`, default `true`, plus a user-facing toggle.

- [ ] **Step 1: Write failing preference compatibility tests**

Add to `PreferencesTests.swift`:

```swift
func testAutomaticUpdatesDefaultToEnabled() {
    XCTAssertTrue(Preferences().automaticUpdatesEnabled)
}

func testLegacyPreferencesEnableAutomaticUpdates() throws {
    let data = #"{"pollInterval":180,"notificationsEnabled":true}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Preferences.self, from: data)
    XCTAssertTrue(decoded.automaticUpdatesEnabled)
}

func testAutomaticUpdatesRoundTrip() throws {
    let original = Preferences(automaticUpdatesEnabled: false)
    let decoded = try JSONDecoder().decode(
        Preferences.self,
        from: JSONEncoder().encode(original)
    )
    XCTAssertFalse(decoded.automaticUpdatesEnabled)
}
```

- [ ] **Step 2: Run preference tests and verify RED**

Run:

```bash
swift test --filter PreferencesTests
```

Expected: compilation fails because `automaticUpdatesEnabled` does not exist.

- [ ] **Step 3: Implement lenient preference storage**

Add to `Preferences`:

```swift
public var automaticUpdatesEnabled: Bool
```

Add `automaticUpdatesEnabled: Bool = true` to the initializer, assign it, add it to `CodingKeys`, and decode with:

```swift
automaticUpdatesEnabled = try c.decodeIfPresent(
    Bool.self,
    forKey: .automaticUpdatesEnabled
) ?? d.automaticUpdatesEnabled
```

- [ ] **Step 4: Add the exact Settings UI**

Insert between the Display and Startup cards in `SettingsView.body`:

```swift
card("Updates") {
    Toggle("Automatically install cc-meter updates",
           isOn: $prefs.automaticUpdatesEnabled)
    Text("Available for Homebrew service installations.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

- [ ] **Step 5: Verify GREEN and build the Settings view**

Run:

```bash
swift test --filter PreferencesTests
swift build
```

Expected: all preference tests pass and the application builds.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/CCMeterCore/Preferences.swift Sources/cc-meter/SettingsView.swift Tests/CCMeterCoreTests/PreferencesTests.swift
git commit -m "feat: add automatic update preference"
```

### Task 2: Define and test targeted Homebrew update behavior

**Files:**
- Create: `Sources/CCMeterCore/HomebrewUpdater.swift`
- Create: `Tests/CCMeterCoreTests/HomebrewUpdaterTests.swift`

**Interfaces:**
- Produces: `AutomaticUpdating`, `AutomaticUpdateOutcome`, `UpdateFailure`, `UpdateCommandRunning`, `UpdateCommandResult`, `UpdateCommandError`, `HomebrewExecutableResolving`, `HomebrewExecutableResolver`, and `HomebrewUpdater`.
- Consumes: fixed service environment, known executable candidates, and a command runner supplied by Task 3 in production.

- [ ] **Step 1: Write failing command-flow tests**

Create tests with a stub runner that records `(URL, [String], TimeInterval, Int)` and returns queued results. Cover these exact assertions:

```swift
private struct StubBrewResolver: HomebrewExecutableResolving {
    let url: URL?
    func resolve() -> URL? { url }
}

private final class StubUpdateCommandRunner: UpdateCommandRunning {
    var results: [Result<UpdateCommandResult, UpdateCommandError>]
    private(set) var arguments: [[String]] = []

    init(results: [Result<UpdateCommandResult, UpdateCommandError>]) {
        self.results = results
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval,
             maxOutputBytes: Int) async throws -> UpdateCommandResult {
        self.arguments.append(arguments)
        return try results.removeFirst().get()
    }
}

private func makeUpdater(runner: StubUpdateCommandRunner,
                         serviceName: String?) -> HomebrewUpdater {
    HomebrewUpdater(
        resolver: StubBrewResolver(url: URL(fileURLWithPath: "/test/brew")),
        runner: runner,
        environment: serviceName.map { ["XPC_SERVICE_NAME": $0] } ?? [:]
    )
}
```

```swift
func testEligibleOutdatedInstallRunsOnlyTargetedCommands() async {
    let runner = StubUpdateCommandRunner(results: [
        .success(UpdateCommandResult(status: 0, output: "")),
        .success(UpdateCommandResult(status: 0, output: "cc-meter\n")),
        .success(UpdateCommandResult(status: 0, output: "installed\n"))
    ])
    let updater = makeUpdater(runner: runner, serviceName: "homebrew.mxcl.cc-meter")

    XCTAssertEqual(await updater.installIfAvailable(), .updated)
    XCTAssertEqual(runner.arguments, [
        ["update-if-needed"],
        ["outdated", "--quiet", "--formula", "raheelkazi/tap/cc-meter"],
        ["upgrade", "--formula", "raheelkazi/tap/cc-meter"]
    ])
}

func testNonExactOutdatedOutputDoesNotBecomeACommand() async {
    let runner = StubUpdateCommandRunner(results: [
        .success(UpdateCommandResult(status: 0, output: "")),
        .success(UpdateCommandResult(status: 0, output: "cc-meter; touch /tmp/nope\n"))
    ])
    let updater = makeUpdater(runner: runner, serviceName: "homebrew.mxcl.cc-meter")

    XCTAssertEqual(await updater.installIfAvailable(), .upToDate)
    XCTAssertEqual(runner.arguments.count, 2)
}

func testManualRunIsUnsupportedAndRunsNothing() async {
    let runner = StubUpdateCommandRunner(results: [])
    let updater = makeUpdater(runner: runner, serviceName: nil)
    XCTAssertFalse(updater.isSupported)
    XCTAssertEqual(await updater.installIfAvailable(), .unsupported)
    XCTAssertTrue(runner.arguments.isEmpty)
}
```

Also test tap-qualified outdated output, missing executable, nonzero status at each stage, launch error, and timeout mapping to `.failed` with the correct stage.

- [ ] **Step 2: Run Homebrew updater tests and verify RED**

Run:

```bash
swift test --filter HomebrewUpdaterTests
```

Expected: compilation fails because the update contracts do not exist.

- [ ] **Step 3: Implement the contracts and resolver**

Create these public contracts in `HomebrewUpdater.swift`:

```swift
public enum HomebrewUpdateStage: String, Equatable {
    case metadata, outdated, upgrade
}

public struct UpdateFailure: Equatable {
    public let stage: HomebrewUpdateStage
    public let detail: String
}

public enum AutomaticUpdateOutcome: Equatable {
    case unsupported
    case upToDate
    case updated
    case failed(UpdateFailure)
}

public protocol AutomaticUpdating: AnyObject {
    var isSupported: Bool { get }
    func installIfAvailable() async -> AutomaticUpdateOutcome
}

public struct UpdateCommandResult: Equatable {
    public let status: Int32
    public let output: String
}

public enum UpdateCommandError: Error, Equatable {
    case launch(String)
    case timeout(String)
}

public protocol UpdateCommandRunning: AnyObject {
    func run(executable: URL,
             arguments: [String],
             timeout: TimeInterval,
             maxOutputBytes: Int) async throws -> UpdateCommandResult
}

public protocol HomebrewExecutableResolving {
    func resolve() -> URL?
}
```

Implement `HomebrewExecutableResolver` with injected candidates and `FileManager`, defaulting in order to `/opt/homebrew/bin/brew` and `/usr/local/bin/brew`, and selecting the first executable file.

- [ ] **Step 4: Implement exact update sequencing**

Implement `HomebrewUpdater` with constants:

```swift
private static let serviceName = "homebrew.mxcl.cc-meter"
private static let formula = "raheelkazi/tap/cc-meter"
private static let metadataTimeout: TimeInterval = 120
private static let upgradeTimeout: TimeInterval = 900
private static let outputLimit = 64 * 1024
```

`isSupported` is true only when the injected environment's `XPC_SERVICE_NAME` exactly matches the service name and the resolver returns an executable. `installIfAvailable()` must:

```swift
guard isSupported, let brew = resolver.resolve() else { return .unsupported }
switch await run(stage: .metadata, brew: brew,
                 arguments: ["update-if-needed"],
                 timeout: Self.metadataTimeout) {
case .success:
    break
case .failure(let failure):
    return .failed(failure)
}
let outdated: UpdateCommandResult
switch await run(
    stage: .outdated,
    brew: brew,
    arguments: ["outdated", "--quiet", "--formula", Self.formula],
    timeout: Self.metadataTimeout
) {
case .success(let result):
    outdated = result
case .failure(let failure):
    return .failed(failure)
}
let names = Set(outdated.output.split(whereSeparator: \.isNewline).map {
    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
})
guard names.contains("cc-meter") || names.contains(Self.formula) else {
    return .upToDate
}
switch await run(stage: .upgrade, brew: brew,
                 arguments: ["upgrade", "--formula", Self.formula],
                 timeout: Self.upgradeTimeout) {
case .success:
    return .updated
case .failure(let failure):
    return .failed(failure)
}
```

Use this private result enum so every nonzero result and thrown command error becomes a stage-specific failure without duplicating mapping code:

```swift
private enum StageResult {
    case success(UpdateCommandResult)
    case failure(UpdateFailure)
}
```

Never append parsed output to command arguments.

- [ ] **Step 5: Verify GREEN**

Run:

```bash
swift test --filter HomebrewUpdaterTests
```

Expected: all targeted sequencing, eligibility, and failure tests pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/CCMeterCore/HomebrewUpdater.swift Tests/CCMeterCoreTests/HomebrewUpdaterTests.swift
git commit -m "feat: add targeted Homebrew updater"
```

### Task 3: Add bounded asynchronous process execution and failure logging

**Files:**
- Create: `Sources/CCMeterCore/UpdateCommandProcess.swift`
- Create: `Sources/CCMeterCore/UpdateLog.swift`
- Create: `Tests/CCMeterCoreTests/UpdateCommandProcessTests.swift`
- Create: `Tests/CCMeterCoreTests/UpdateLogTests.swift`

**Interfaces:**
- Implements: `UpdateCommandRunning` through `UpdateCommandProcess`.
- Produces: `UpdateLogging` and `FileUpdateLogger` with a 64 KiB retained file.

- [ ] **Step 1: Write failing real-process tests**

Create temporary executable scripts from Swift test code with POSIX mode `0o755`. Test:

```swift
private func makeScript(_ contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cc-meter-update-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("command")
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: url.path)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return url
}
```

```swift
func testRunnerPassesArgumentsAndCapturesBoundedOutput() async throws {
    let script = try makeScript("""
    #!/bin/sh
    printf '%s\\n' "$@"
    printf 'stderr-line\\n' >&2
    """)
    let result = try await UpdateCommandProcess().run(
        executable: script,
        arguments: ["one", "two"],
        timeout: 2,
        maxOutputBytes: 64 * 1024
    )
    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("one\ntwo"))
    XCTAssertTrue(result.output.contains("stderr-line"))
}

func testRunnerTimesOutAndReturnsCapturedOutput() async {
    let script = try! makeScript("""
    #!/bin/sh
    printf 'before-timeout\\n'
    sleep 5
    """)
    do {
        _ = try await UpdateCommandProcess().run(
            executable: script, arguments: [], timeout: 0.1, maxOutputBytes: 1024
        )
        XCTFail("expected timeout")
    } catch let error as UpdateCommandError {
        guard case .timeout(let output) = error else {
            return XCTFail("expected timeout, got \(error)")
        }
        XCTAssertTrue(output.contains("before-timeout"))
    } catch {
        XCTFail("unexpected error: \(error)")
    }
}
```

Add a large-output test asserting captured UTF-8 data is no more than the requested byte limit and a launch-failure test using a missing executable.

- [ ] **Step 2: Write failing bounded logger tests**

Create tests that call `FileUpdateLogger.record` twice, assert both timestamped stages are present, then append failures larger than 64 KiB and assert the file is at most 64 KiB and retains the newest entry.

- [ ] **Step 3: Run focused tests and verify RED**

Run:

```bash
swift test --filter 'UpdateCommandProcessTests|UpdateLogTests'
```

Expected: compilation fails because the process and logger types do not exist.

- [ ] **Step 4: Implement the process session**

Implement `UpdateCommandProcess.run` with a private retained session class, `Process`, separate stdout/stderr pipes, `NSLock`, one completion path, and a `DispatchWorkItem` timeout. The session must:

```swift
process.executableURL = executable
process.arguments = arguments
process.standardOutput = stdout
process.standardError = stderr
stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
    self?.consume(handle.availableData)
}
stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
    self?.consume(handle.availableData)
}
process.terminationHandler = { [weak self] process in
    self?.finish(.success(UpdateCommandResult(
        status: process.terminationStatus,
        output: self?.capturedText() ?? ""
    )))
}
```

`consume` always drains pipe data but appends only the remaining byte allowance. Timeout captures current output, terminates the running process, and finishes with `.timeout(output)`. Launch errors finish with `.launch(localizedDescription)`. `finish` cancels the timeout, clears both readability handlers, terminates a still-running process, releases the self-retain, and invokes completion exactly once outside the lock.

- [ ] **Step 5: Implement the bounded file logger**

Define:

```swift
public protocol UpdateLogging {
    func record(_ failure: UpdateFailure, at date: Date)
}

public final class FileUpdateLogger: UpdateLogging {
    public static let maxBytes = 64 * 1024
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/cc-meter/update.log")
    }
}
```

`record` creates the parent directory, formats one UTC ISO-8601 entry containing stage and detail, appends it to existing data, retains `combined.suffix(Self.maxBytes)`, and writes atomically. It never writes environment data.
Filesystem failures are swallowed so update diagnostics can never crash or block the menu-bar app.

- [ ] **Step 6: Verify GREEN and regression-test process cleanup**

Run:

```bash
swift test --filter 'UpdateCommandProcessTests|UpdateLogTests|HomebrewUpdaterTests'
```

Expected: all process, timeout, bound, logger, and updater tests pass.

- [ ] **Step 7: Commit Task 3**

```bash
git add Sources/CCMeterCore/UpdateCommandProcess.swift Sources/CCMeterCore/UpdateLog.swift Tests/CCMeterCoreTests/UpdateCommandProcessTests.swift Tests/CCMeterCoreTests/UpdateLogTests.swift
git commit -m "feat: run and log Homebrew updates safely"
```

### Task 4: Orchestrate daily checks, failure handling, and restart

**Files:**
- Create: `Sources/CCMeterCore/AutoUpdateController.swift`
- Create: `Tests/CCMeterCoreTests/AutoUpdateControllerTests.swift`

**Interfaces:**
- Consumes: `AutomaticUpdating`, `UpdateLogging`, `Notifying`, injected scheduler/store/time/exit.
- Produces: `AutomaticUpdateControlling`, `AutoUpdateController.start(enabled:)`, `apply(enabled:)`, and `runDueCheck()`.

- [ ] **Step 1: Write failing cadence and outcome tests**

Create fakes for `UpdateScheduling`, `UpdateScheduleToken`, `UpdateAttemptStoring`, `AutomaticUpdating`, `UpdateLogging`, and `Notifying`. Add tests asserting:

```swift
func testStartSchedulesFiveMinuteInitialAndHourlyDueChecks() {
    let fixture = makeController(outcome: .upToDate)
    fixture.controller.start(enabled: true)
    XCTAssertEqual(fixture.scheduler.requests.map(\.delay), [300, 3600])
    XCTAssertEqual(fixture.scheduler.requests.map(\.repeating), [nil, 3600])
}

func testRecentAttemptAndDisabledStateSkipUpdater() async {
    let recent = makeController(outcome: .upToDate,
                                lastAttempt: now.addingTimeInterval(-23 * 3600))
    recent.controller.start(enabled: true)
    await recent.controller.runDueCheck()
    XCTAssertEqual(recent.updater.callCount, 0)

    let disabled = makeController(outcome: .upToDate)
    disabled.controller.start(enabled: false)
    await disabled.controller.runDueCheck()
    XCTAssertEqual(disabled.updater.callCount, 0)
}

func testUpdatedExitsWithTempFailWithoutNotification() async {
    let fixture = makeController(outcome: .updated)
    fixture.controller.start(enabled: true)
    await fixture.controller.runDueCheck()
    XCTAssertEqual(fixture.exitStatuses, [75])
    XCTAssertTrue(fixture.notifications.events.isEmpty)
}

func testFailureLogsAndNotifiesWithoutExit() async {
    let failure = UpdateFailure(stage: .upgrade, detail: "build failed")
    let fixture = makeController(outcome: .failed(failure))
    fixture.controller.start(enabled: true)
    await fixture.controller.runDueCheck()
    XCTAssertEqual(fixture.logger.failures, [failure])
    XCTAssertEqual(fixture.notifications.events, [
        NotificationEvent(
            id: "cc-meter-auto-update-failed",
            title: "cc-meter update failed",
            body: "Automatic update failed during upgrade. See ~/Library/Logs/cc-meter/update.log."
        )
    ])
    XCTAssertTrue(fixture.exitStatuses.isEmpty)
}
```

Also test unsupported scheduling, disabling cancels both tokens, re-enabling reschedules, last-attempt persistence before awaiting the updater, no retry before 24 hours, and two overlapping checks invoking the updater once.

- [ ] **Step 2: Run controller tests and verify RED**

Run:

```bash
swift test --filter AutoUpdateControllerTests
```

Expected: compilation fails because controller and scheduling contracts do not exist.

- [ ] **Step 3: Implement scheduling and attempt storage contracts**

Define `AutomaticUpdateControlling`, `UpdateScheduleToken`, `UpdateScheduling`, `UpdateAttemptStoring`, `UserDefaultsUpdateAttemptStore`, and `TimerUpdateScheduler`. Use key `cc-meter.auto-update.last-attempt`. The timer scheduler uses the main run loop in `.common` mode and returns a token whose `cancel()` invalidates the timer.

```swift
@MainActor
public protocol AutomaticUpdateControlling: AnyObject {
    func start(enabled: Bool)
    func apply(enabled: Bool)
}
```

Conform `AutoUpdateController` to this protocol.

Use these public cadence constants:

```swift
public static let initialDelay: TimeInterval = 5 * 60
public static let dueCheckInterval: TimeInterval = 60 * 60
public static let minimumAttemptInterval: TimeInterval = 24 * 60 * 60
public static let restartExitStatus: Int32 = 75
```

- [ ] **Step 4: Implement controller state transitions**

`start(enabled:)` marks lifecycle started, stores enabled state, and reconciles scheduling. `apply(enabled:)` updates state and reconciles only after start. Scheduling exists only when enabled and `updater.isSupported`; disabling cancels and clears both tokens.

Implement `runDueCheck()` as:

```swift
public func runDueCheck() async {
    guard enabled, updater.isSupported, !isChecking else { return }
    let attemptedAt = now()
    if let last = attemptStore.lastAttempt,
       attemptedAt.timeIntervalSince(last) < Self.minimumAttemptInterval {
        return
    }
    isChecking = true
    attemptStore.lastAttempt = attemptedAt
    let outcome = await updater.installIfAvailable()
    isChecking = false

    switch outcome {
    case .unsupported, .upToDate:
        break
    case .updated:
        exitHandler(Self.restartExitStatus)
    case .failed(let failure):
        logger.record(failure, at: attemptedAt)
        notifier.post(NotificationEvent(
            id: "cc-meter-auto-update-failed",
            title: "cc-meter update failed",
            body: "Automatic update failed during \(failure.stage.rawValue). See ~/Library/Logs/cc-meter/update.log."
        ))
    }
}
```

Scheduled actions launch `Task { @MainActor in await self?.runDueCheck() }`. Keep controller mutations main-actor isolated.

- [ ] **Step 5: Verify GREEN**

Run:

```bash
swift test --filter AutoUpdateControllerTests
```

Expected: all cadence, persistence, single-flight, outcome, notification, and restart tests pass.

- [ ] **Step 6: Commit Task 4**

```bash
git add Sources/CCMeterCore/AutoUpdateController.swift Tests/CCMeterCoreTests/AutoUpdateControllerTests.swift
git commit -m "feat: schedule automatic cc-meter updates"
```

### Task 5: Wire the updater into app lifecycle and documentation

**Files:**
- Modify: `Sources/cc-meter/AppDelegate.swift`
- Modify: `README.md`
- Modify: `docs/RELEASING.md`
- Create: `Tests/CCMeterAppTests/AutoUpdateIntegrationTests.swift`

**Interfaces:**
- Consumes: all Task 1-4 production types.
- Produces: retained production controller, live preference propagation, bootstrap/recovery documentation.

- [ ] **Step 1: Add an app-target lifecycle wiring test seam**

Use the `AutomaticUpdateControlling` protocol from Task 4 for the retained property and extract this static factory in `AppDelegate`:

```swift
static func makeAutoUpdateController(environment: [String: String]) -> AutoUpdateController {
    let updater = HomebrewUpdater(
        resolver: HomebrewExecutableResolver(),
        runner: UpdateCommandProcess(),
        environment: environment
    )
    return AutoUpdateController(
        updater: updater,
        scheduler: TimerUpdateScheduler(),
        attemptStore: UserDefaultsUpdateAttemptStore(),
        notifier: OsascriptNotifier(),
        logger: FileUpdateLogger(),
        exitHandler: { Darwin.exit($0) }
    )
}
```

Add a small internal helper and test it with a stub `AutomaticUpdateControlling`:

```swift
static func startAutomaticUpdates(_ controller: AutomaticUpdateControlling,
                                  preferences: Preferences) {
    controller.start(enabled: preferences.automaticUpdatesEnabled)
}
```

The app test passes preferences with the field both true and false and asserts the stub receives the matching values. Keep all real Homebrew commands behind the service-name eligibility check.

- [ ] **Step 2: Wire startup and preference changes**

Add retained property:

```swift
private var autoUpdateController: AutomaticUpdateControlling?
```

After dashboard/menu controller installation:

```swift
let autoUpdateController = Self.makeAutoUpdateController(
    environment: ProcessInfo.processInfo.environment
)
self.autoUpdateController = autoUpdateController
Self.startAutomaticUpdates(autoUpdateController, preferences: preferences)
```

Extend `applyPreferences`:

```swift
autoUpdateController?.apply(enabled: preferences.automaticUpdatesEnabled)
```

- [ ] **Step 3: Update user and release documentation**

Replace README's manual-only upgrade text with explicit `v0.4.3` bootstrap instructions, daily default-on targeted updates, Settings opt-out, Homebrew-service eligibility, failure log path, and `brew upgrade cc-meter` recovery command. Update `docs/RELEASING.md` to say that pushing the updated tap formula is what automatic clients observe on their next due check.

- [ ] **Step 4: Build and run app/core tests**

Run:

```bash
swift build
swift test --filter 'AutoUpdate|Homebrew|UpdateCommand|UpdateLog|Preferences'
```

Expected: build succeeds and all update-related tests pass without invoking the installed Homebrew formula.

- [ ] **Step 5: Commit Task 5**

```bash
git add Sources/cc-meter/AppDelegate.swift README.md docs/RELEASING.md Tests/CCMeterAppTests/AutoUpdateIntegrationTests.swift
git commit -m "feat: enable silent Homebrew updates"
```

### Task 6: Verify, review, merge, and publish the bootstrap release

**Files:**
- Modify: `docs/superpowers/plans/2026-07-12-automatic-homebrew-updates.md` only for completion checkmarks.
- External after merge: `/opt/homebrew/Library/Taps/raheelkazi/homebrew-tap/Formula/cc-meter.rb`.

**Interfaces:**
- Produces: reviewed `v0.4.3`, updated tap, and an installed bootstrap client ready to auto-install subsequent versions.

- [ ] **Step 1: Run fresh verification**

```bash
swift test
swift build -c release
git diff --check main...HEAD
```

Expected: all tests pass, release build succeeds, and no whitespace errors exist.

- [ ] **Step 2: Audit scope and request independent review**

```bash
git status --short --branch
git diff --stat main...HEAD
git log --oneline main..HEAD
```

Give an independent reviewer the base/head SHAs, approved spec, and this plan. Resolve every Critical and Important finding, then rerun Step 1.

- [ ] **Step 3: Merge and verify main**

Fast-forward the feature branch into `main`, then run `swift test` from the main checkout. Do not remove the worktree until merged-main verification passes.

- [ ] **Step 4: Publish `v0.4.3` and update the tap**

```bash
git push origin main
git tag -a v0.4.3 -m "cc-meter v0.4.3"
git push origin v0.4.3
curl -fsSL https://github.com/raheelkazi/cc-meter/archive/refs/tags/v0.4.3.tar.gz | shasum -a 256
```

Use the printed SHA-256 in the tap formula, run `brew audit --strict raheelkazi/tap/cc-meter` and `brew style raheelkazi/tap/cc-meter`, commit `cc-meter 0.4.3`, and push the tap.

- [ ] **Step 5: Install and smoke-test the bootstrap**

```bash
brew update
brew upgrade raheelkazi/tap/cc-meter
brew services restart raheelkazi/tap/cc-meter
brew list --versions cc-meter
brew services list | rg '^cc-meter\s'
pgrep -af '^/opt/homebrew/opt/cc-meter/bin/cc-meter$|^/usr/local/opt/cc-meter/bin/cc-meter$'
```

Expected: version `0.4.3`, service `started`, and the process running through Homebrew's `opt` path. Verify Settings shows automatic updates enabled. Do not publish a fake later formula merely to exercise a production upgrade.
