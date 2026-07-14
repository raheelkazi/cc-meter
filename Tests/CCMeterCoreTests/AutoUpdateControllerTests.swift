import Foundation
import XCTest
@testable import CCMeterCore

@MainActor
final class AutoUpdateControllerTests: XCTestCase {
    func testStartSchedulesFiveMinuteInitialAndHourlyDueChecks() {
        let fixture = makeController(outcome: .upToDate)

        fixture.controller.start(enabled: true)

        XCTAssertEqual(fixture.scheduler.requests.map(\.delay), [300, 3600])
        XCTAssertEqual(fixture.scheduler.requests.map(\.repeating), [nil, 3600])
    }

    func testUnsupportedUpdaterDoesNotSchedule() {
        let fixture = makeController(outcome: .unsupported, isSupported: false)

        fixture.controller.start(enabled: true)

        XCTAssertTrue(fixture.scheduler.requests.isEmpty)
    }

    func testApplyBeforeStartDoesNotSchedule() {
        let fixture = makeController(outcome: .upToDate)

        fixture.controller.apply(enabled: true)

        XCTAssertTrue(fixture.scheduler.requests.isEmpty)
    }

    func testDisablingCancelsBothScheduledTokens() {
        let fixture = makeController(outcome: .upToDate)
        fixture.controller.start(enabled: true)

        fixture.controller.apply(enabled: false)

        XCTAssertEqual(fixture.scheduler.tokens.map(\.cancelCount), [1, 1])
    }

    func testTimerScheduleTokenInvalidatesTimerWhenReleased() {
        let fired = expectation(description: "released timer must not fire")
        fired.isInverted = true
        var token: UpdateScheduleToken? = TimerUpdateScheduler().schedule(
            after: 0.01,
            repeating: nil,
            action: { fired.fulfill() }
        )

        XCTAssertNotNil(token)
        token = nil

        wait(for: [fired], timeout: 0.05)
    }

    func testReenablingReschedulesAfterCancellation() {
        let fixture = makeController(outcome: .upToDate)
        fixture.controller.start(enabled: true)
        fixture.controller.apply(enabled: false)

        fixture.controller.apply(enabled: true)

        XCTAssertEqual(fixture.scheduler.requests.map(\.delay), [300, 3600, 300, 3600])
        XCTAssertEqual(fixture.scheduler.tokens.prefix(2).map(\.cancelCount), [1, 1])
        XCTAssertEqual(fixture.scheduler.tokens.suffix(2).map(\.cancelCount), [0, 0])
    }

    func testRecentAttemptAndDisabledStateSkipUpdater() async {
        let recent = makeController(
            outcome: .upToDate,
            lastAttempt: now.addingTimeInterval(-23 * 3600)
        )
        recent.controller.start(enabled: true)
        await recent.controller.runDueCheck()
        XCTAssertEqual(recent.updater.callCount, 0)

        let disabled = makeController(outcome: .upToDate)
        disabled.controller.start(enabled: false)
        await disabled.controller.runDueCheck()
        XCTAssertEqual(disabled.updater.callCount, 0)
    }

    func testAttemptIsPersistedBeforeAwaitingUpdater() async {
        let updater = SuspendingUpdater()
        let fixture = makeController(updater: updater)
        fixture.controller.start(enabled: true)

        let check = Task { await fixture.controller.runDueCheck() }
        await updater.waitUntilCalled()

        XCTAssertEqual(fixture.attemptStore.lastAttempt, now)
        updater.resume(returning: .upToDate)
        await check.value
    }

    func testSuspendingUpdaterDoesNotLoseResumeBeforeOutcomeWaitIsRegistered() async {
        let reachedRegistrationGap = DispatchSemaphore(value: 0)
        let allowRegistration = DispatchSemaphore(value: 0)
        let updater = SuspendingUpdater(beforeOutcomeContinuationRegistration: {
            reachedRegistrationGap.signal()
            allowRegistration.wait()
        })
        let completed = expectation(description: "updater completed from the first resume")
        let install = Task.detached {
            let outcome = await updater.installIfAvailable()
            completed.fulfill()
            return outcome
        }

        XCTAssertEqual(reachedRegistrationGap.wait(timeout: .now() + 1), .success)
        await updater.waitUntilCalled()
        updater.resume(returning: .upToDate)
        allowRegistration.signal()

        await fulfillment(of: [completed], timeout: 1)
        updater.resume(returning: .upToDate) // Cleanup for the pre-fix failure path.
        let outcome = await install.value
        XCTAssertEqual(outcome, .upToDate)
    }

    func testSuspendingUpdaterRegistersWaiterAtomicallyWithCallCheck() async {
        let reachedWaiterRegistration = DispatchSemaphore(value: 0)
        let allowWaiterRegistration = DispatchSemaphore(value: 0)
        let installAttempted = DispatchSemaphore(value: 0)
        let updater = SuspendingUpdater(
            onInstallAttempt: { installAttempted.signal() },
            beforeWaiterRegistration: {
                reachedWaiterRegistration.signal()
                allowWaiterRegistration.wait()
            }
        )
        let waiterCompleted = expectation(description: "waiter observed the first install call")
        let waiter = Task.detached {
            await updater.waitUntilCalled()
            waiterCompleted.fulfill()
        }

        XCTAssertEqual(reachedWaiterRegistration.wait(timeout: .now() + 1), .success)
        let install = Task.detached { await updater.installIfAvailable() }
        XCTAssertEqual(installAttempted.wait(timeout: .now() + 1), .success)
        allowWaiterRegistration.signal()

        await fulfillment(of: [waiterCompleted], timeout: 1)
        updater.resume(returning: .upToDate)
        await waiter.value
        let outcome = await install.value
        XCTAssertEqual(outcome, .upToDate)
    }

    func testCompletedAttemptIsNotRetriedBeforeTwentyFourHours() async {
        let fixture = makeController(outcome: .upToDate)
        fixture.controller.start(enabled: true)

        await fixture.controller.runDueCheck()
        await fixture.controller.runDueCheck()

        XCTAssertEqual(fixture.updater.callCount, 1)
        XCTAssertEqual(fixture.attemptStore.lastAttempt, now)
    }

    func testOverlappingChecksInvokeUpdaterOnce() async {
        let updater = SuspendingUpdater()
        let fixture = makeController(updater: updater)
        fixture.controller.start(enabled: true)

        let first = Task { await fixture.controller.runDueCheck() }
        await updater.waitUntilCalled()
        let second = Task { await fixture.controller.runDueCheck() }
        await second.value

        XCTAssertEqual(updater.callCount, 1)
        updater.resume(returning: .upToDate)
        await first.value
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
        XCTAssertEqual(fixture.logger.dates, [now])
        XCTAssertEqual(fixture.notifications.events, [
            NotificationEvent(
                id: "cc-meter-auto-update-failed",
                title: "cc-meter update failed",
                body: "Automatic update failed during upgrade. See ~/Library/Logs/cc-meter/update.log."
            )
        ])
        XCTAssertTrue(fixture.exitStatuses.isEmpty)
    }

    func testUnsupportedAndUpToDateOutcomesHaveNoSideEffects() async {
        for outcome in [AutomaticUpdateOutcome.unsupported, .upToDate] {
            let fixture = makeController(outcome: outcome)
            fixture.controller.start(enabled: true)

            await fixture.controller.runDueCheck()

            XCTAssertTrue(fixture.exitStatuses.isEmpty)
            XCTAssertTrue(fixture.logger.failures.isEmpty)
            XCTAssertTrue(fixture.notifications.events.isEmpty)
        }
    }

    func testUserDefaultsAttemptStoreUsesStableKey() {
        let suiteName = "AutoUpdateControllerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let date = Date(timeIntervalSince1970: 1234)
        let store = UserDefaultsUpdateAttemptStore(defaults: defaults)

        store.lastAttempt = date

        XCTAssertEqual(defaults.object(forKey: "cc-meter.auto-update.last-attempt") as? Date, date)
        XCTAssertEqual(UserDefaultsUpdateAttemptStore(defaults: defaults).lastAttempt, date)
    }

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func makeController(
        outcome: AutomaticUpdateOutcome,
        isSupported: Bool = true,
        lastAttempt: Date? = nil
    ) -> Fixture {
        makeController(
            updater: StubUpdater(isSupported: isSupported, outcome: outcome),
            lastAttempt: lastAttempt
        )
    }


    /// A clock briefly running ahead (NTP correction after sleep) persists a FUTURE lastAttempt
    /// to UserDefaults. Once the clock corrects, `now - last` is negative — forever less than
    /// the 24h throttle — so the scheduled check never runs again, surviving restarts.
    func testAFutureLastAttemptDoesNotDisableUpdatesForever() async {
        let fixture = makeController(outcome: .upToDate,
                                     lastAttempt: now.addingTimeInterval(365 * 86400))
        fixture.controller.start(enabled: true)

        await fixture.controller.runDueCheck()

        XCTAssertEqual(fixture.updater.callCount, 1,
                       "a lastAttempt in the future must not wedge the updater permanently")
    // MARK: - Manual "Check Now"
    //
    // The updater was invisible: it ran daily and reported nothing, so a silently failing
    // updater looked exactly like a working one. Settings now shows status and can check
    // on demand.
    }

    func testCheckNowRunsEvenWhenAutomaticUpdatesAreDisabled() async {
        let fixture = makeController(outcome: .upToDate)
        fixture.controller.start(enabled: false)

        await fixture.controller.checkNow()

        XCTAssertEqual(fixture.updater.callCount, 1,
                       "an explicit request must run even with auto-updates off")
    }

    /// The daily throttle exists to stop the *scheduled* check hammering Homebrew. A person
    /// who clicks the button is asking now, and must not be silently ignored.
    func testCheckNowIgnoresTheOncePerDayThrottle() async {
        let fixture = makeController(outcome: .upToDate, lastAttempt: now)
        fixture.controller.start(enabled: true)

        await fixture.controller.runDueCheck()
        XCTAssertEqual(fixture.updater.callCount, 0, "scheduled check is throttled")

        await fixture.controller.checkNow()
        XCTAssertEqual(fixture.updater.callCount, 1, "the manual check is not")
    }

    func testStatusReportsUpToDateWithTheTimeItChecked() async {
        let fixture = makeController(outcome: .upToDate)

        await fixture.controller.checkNow()

        XCTAssertEqual(fixture.controller.status, .upToDate(at: now))
    }

    func testStatusReportsFailureAndStillLogsIt() async {
        let failure = UpdateFailure(stage: .upgrade, detail: "boom")
        let fixture = makeController(outcome: .failed(failure))

        await fixture.controller.checkNow()

        XCTAssertEqual(fixture.controller.status, .failed(failure, at: now))
        XCTAssertEqual(fixture.logger.failures.count, 1, "a manual failure is still written to the log")
    }

    /// The Homebrew service is `keep_alive successful_exit: false`, so exiting non-zero is
    /// how the app relaunches itself into the newly installed binary.
    func testUpdatedStatusRestartsTheApp() async {
        let fixture = makeController(outcome: .updated)

        await fixture.controller.checkNow()

        XCTAssertEqual(fixture.controller.status, .updated(at: now))
        XCTAssertEqual(fixture.exitStatuses, [AutoUpdateController.restartExitStatus])
    }

    func testStatusIsUnsupportedOutsideAHomebrewServiceInstall() async {
        let fixture = makeController(outcome: .unsupported, isSupported: false)

        await fixture.controller.checkNow()

        XCTAssertEqual(fixture.controller.status, .unsupported)
        XCTAssertEqual(fixture.updater.callCount, 0,
                       "a dev build must say so rather than pretend to check")
    }

    func testCheckNowRecordsTheAttemptSoTheDailyCheckDoesNotImmediatelyRepeatIt() async {
        let fixture = makeController(outcome: .upToDate)

        await fixture.controller.checkNow()

        XCTAssertEqual(fixture.attemptStore.lastAttempt, now)
    }

    private func makeController(
        updater: TestUpdater,
        lastAttempt: Date? = nil
    ) -> Fixture {
        let scheduler = StubScheduler()
        let attemptStore = StubAttemptStore(lastAttempt: lastAttempt)
        let logger = StubUpdateLogger()
        let notifications = StubNotifier()
        var exitStatuses: [Int32] = []
        let controller = AutoUpdateController(
            updater: updater,
            logger: logger,
            notifier: notifications,
            scheduler: scheduler,
            attemptStore: attemptStore,
            now: { [now] in now },
            exitHandler: { exitStatuses.append($0) }
        )
        return Fixture(
            controller: controller,
            updater: updater,
            scheduler: scheduler,
            attemptStore: attemptStore,
            logger: logger,
            notifications: notifications,
            getExitStatuses: { exitStatuses }
        )
    }
}

@MainActor
private struct Fixture {
    let controller: AutoUpdateController
    let updater: TestUpdater
    let scheduler: StubScheduler
    let attemptStore: StubAttemptStore
    let logger: StubUpdateLogger
    let notifications: StubNotifier
    let getExitStatuses: () -> [Int32]

    var exitStatuses: [Int32] { getExitStatuses() }
}

private protocol TestUpdater: AutomaticUpdating {
    var callCount: Int { get }
}

private final class StubUpdater: TestUpdater {
    let isSupported: Bool
    let outcome: AutomaticUpdateOutcome
    private(set) var callCount = 0

    init(isSupported: Bool, outcome: AutomaticUpdateOutcome) {
        self.isSupported = isSupported
        self.outcome = outcome
    }

    func installIfAvailable() async -> AutomaticUpdateOutcome {
        callCount += 1
        return outcome
    }
}

private final class SuspendingUpdater: TestUpdater {
    let isSupported = true
    private let lock = NSLock()
    private var storedCallCount = 0
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private var outcomeContinuation: CheckedContinuation<AutomaticUpdateOutcome, Never>?
    private var pendingOutcome: AutomaticUpdateOutcome?

    private let onInstallAttempt: () -> Void
    private let beforeWaiterRegistration: () -> Void
    private let beforeOutcomeContinuationRegistration: () -> Void

    init(
        onInstallAttempt: @escaping () -> Void = {},
        beforeWaiterRegistration: @escaping () -> Void = {},
        beforeOutcomeContinuationRegistration: @escaping () -> Void = {}
    ) {
        self.onInstallAttempt = onInstallAttempt
        self.beforeWaiterRegistration = beforeWaiterRegistration
        self.beforeOutcomeContinuationRegistration = beforeOutcomeContinuationRegistration
    }

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    func installIfAvailable() async -> AutomaticUpdateOutcome {
        onInstallAttempt()
        let waiters = lock.withLock {
            storedCallCount += 1
            let waiters = callWaiters
            callWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }

        beforeOutcomeContinuationRegistration()
        return await withCheckedContinuation { continuation in
            let outcome = lock.withLock {
                let outcome = pendingOutcome
                pendingOutcome = nil
                if outcome == nil {
                    outcomeContinuation = continuation
                }
                return outcome
            }

            if let outcome {
                continuation.resume(returning: outcome)
            }
        }
    }

    func waitUntilCalled() async {
        await withCheckedContinuation { continuation in
            let wasAlreadyCalled = lock.withLock {
                let wasAlreadyCalled = storedCallCount > 0
                if !wasAlreadyCalled {
                    beforeWaiterRegistration()
                    callWaiters.append(continuation)
                }
                return wasAlreadyCalled
            }

            if wasAlreadyCalled {
                continuation.resume()
            }
        }
    }

    func resume(returning outcome: AutomaticUpdateOutcome) {
        let continuation = lock.withLock {
            let continuation = outcomeContinuation
            outcomeContinuation = nil
            if continuation == nil {
                pendingOutcome = outcome
            }
            return continuation
        }
        continuation?.resume(returning: outcome)
    }
}

private final class StubScheduleToken: UpdateScheduleToken {
    private(set) var cancelCount = 0
    func cancel() { cancelCount += 1 }
}

private final class StubScheduler: UpdateScheduling {
    struct Request {
        let delay: TimeInterval
        let repeating: TimeInterval?
        let action: () -> Void
    }

    private(set) var requests: [Request] = []
    private(set) var tokens: [StubScheduleToken] = []

    func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval?,
        action: @escaping () -> Void
    ) -> UpdateScheduleToken {
        let token = StubScheduleToken()
        requests.append(Request(delay: delay, repeating: interval, action: action))
        tokens.append(token)
        return token
    }
}

private final class StubAttemptStore: UpdateAttemptStoring {
    var lastAttempt: Date?
    init(lastAttempt: Date?) { self.lastAttempt = lastAttempt }
}

private final class StubUpdateLogger: UpdateLogging {
    private(set) var failures: [UpdateFailure] = []
    private(set) var dates: [Date] = []

    func record(_ failure: UpdateFailure, at date: Date) {
        failures.append(failure)
        dates.append(date)
    }
}

private final class StubNotifier: Notifying {
    private(set) var events: [NotificationEvent] = []
    func post(_ event: NotificationEvent) { events.append(event) }
}
