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
    private(set) var callCount = 0
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private var outcomeContinuation: CheckedContinuation<AutomaticUpdateOutcome, Never>?

    func installIfAvailable() async -> AutomaticUpdateOutcome {
        callCount += 1
        callWaiters.forEach { $0.resume() }
        callWaiters.removeAll()
        return await withCheckedContinuation { outcomeContinuation = $0 }
    }

    func waitUntilCalled() async {
        if callCount > 0 { return }
        await withCheckedContinuation { callWaiters.append($0) }
    }

    func resume(returning outcome: AutomaticUpdateOutcome) {
        outcomeContinuation?.resume(returning: outcome)
        outcomeContinuation = nil
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
