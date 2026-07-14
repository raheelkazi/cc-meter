import Foundation

@MainActor
public protocol AutomaticUpdateControlling: AnyObject {
    func start(enabled: Bool)
    func apply(enabled: Bool)
    /// Check on demand, ignoring both the enabled flag and the daily throttle: someone
    /// clicking a button is asking *now*.
    func checkNow() async
    var status: UpdateStatus { get }
}

/// What the updater last did, so Settings can say so.
///
/// The updater used to run daily and report nothing, which meant a silently failing updater
/// looked exactly like a working one.
public enum UpdateStatus: Equatable {
    /// Nothing has been checked yet in this run.
    case idle
    case checking
    case upToDate(at: Date)
    /// Installed. The app exits non-zero so the Homebrew service relaunches it on the new binary.
    case updated(at: Date)
    case failed(UpdateFailure, at: Date)
    /// Not a Homebrew service install (a dev build, say), so there is nothing to check.
    case unsupported

    /// One line for Settings, so the updater stops being invisible.
    public func summary(now: Date) -> String {
        switch self {
        case .idle:
            return "Not checked yet"
        case .checking:
            return "Checking…"
        case .upToDate(let at):
            return "Up to date · checked \(relativeTimeText(since: at, now: now))"
        case .updated(let at):
            return "Updated \(relativeTimeText(since: at, now: now)) · restarting"
        case .failed(let failure, let at):
            return "Check failed during \(failure.stage.rawValue) "
                + "\(relativeTimeText(since: at, now: now)) · see update.log"
        case .unsupported:
            return "Only available for Homebrew service installations"
        }
    }
}

@MainActor
public protocol UpdateScheduleToken: AnyObject {
    func cancel()
}

@MainActor
public protocol UpdateScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval?,
        action: @escaping () -> Void
    ) -> UpdateScheduleToken
}

public protocol UpdateAttemptStoring: AnyObject {
    var lastAttempt: Date? { get set }
}

public final class UserDefaultsUpdateAttemptStore: UpdateAttemptStoring {
    private static let key = "cc-meter.auto-update.last-attempt"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var lastAttempt: Date? {
        get { defaults.object(forKey: Self.key) as? Date }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

@MainActor
public final class TimerUpdateScheduler: UpdateScheduling {
    public init() {}

    public func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval?,
        action: @escaping () -> Void
    ) -> UpdateScheduleToken {
        let timer = Timer(
            fire: Date().addingTimeInterval(delay),
            interval: interval ?? 0,
            repeats: interval != nil
        ) { _ in
            action()
        }
        RunLoop.main.add(timer, forMode: .common)
        return TimerUpdateScheduleToken(timer: timer)
    }
}

@MainActor
private final class TimerUpdateScheduleToken: UpdateScheduleToken {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    deinit {
        timer.invalidate()
    }

    func cancel() {
        timer.invalidate()
    }
}

@MainActor
public final class AutoUpdateController: AutomaticUpdateControlling, ObservableObject {
    @Published public private(set) var status: UpdateStatus = .idle

    public static let initialDelay: TimeInterval = 5 * 60
    public static let dueCheckInterval: TimeInterval = 60 * 60
    public static let minimumAttemptInterval: TimeInterval = 24 * 60 * 60
    public static let restartExitStatus: Int32 = 75

    private let updater: AutomaticUpdating
    private let logger: UpdateLogging
    private let notifier: Notifying
    private let scheduler: UpdateScheduling
    private let attemptStore: UpdateAttemptStoring
    private let now: () -> Date
    private let exitHandler: (Int32) -> Void

    private var hasStarted = false
    private var enabled = false
    private var isChecking = false
    private var initialToken: UpdateScheduleToken?
    private var repeatingToken: UpdateScheduleToken?

    public init(
        updater: AutomaticUpdating,
        logger: UpdateLogging,
        notifier: Notifying,
        scheduler: UpdateScheduling,
        attemptStore: UpdateAttemptStoring,
        now: @escaping () -> Date = Date.init,
        exitHandler: @escaping (Int32) -> Void
    ) {
        self.updater = updater
        self.logger = logger
        self.notifier = notifier
        self.scheduler = scheduler
        self.attemptStore = attemptStore
        self.now = now
        self.exitHandler = exitHandler
    }

    public func start(enabled: Bool) {
        hasStarted = true
        self.enabled = enabled
        reconcileScheduling()
    }

    public func apply(enabled: Bool) {
        self.enabled = enabled
        guard hasStarted else { return }
        reconcileScheduling()
    }

    /// The scheduled check. Runs at most once a day, and only when enabled.
    public func runDueCheck() async {
        guard enabled, updater.isSupported, !isChecking else { return }
        let attemptedAt = now()
        // abs(), because a clock that briefly ran ahead (an NTP correction after sleep) persists
        // a FUTURE lastAttempt to UserDefaults. Once the clock corrects, the difference is
        // negative — forever less than the throttle — and the updater would never run again,
        // surviving restarts and reinstalls, with no symptom but "Not checked yet".
        if let last = attemptStore.lastAttempt,
           abs(attemptedAt.timeIntervalSince(last)) < Self.minimumAttemptInterval {
            return
        }
        // A background failure is invisible, so it earns a notification.
        await performCheck(at: attemptedAt, notifyOnFailure: true)
    }

    /// The Settings button. Deliberately ignores both the enabled flag and the daily
    /// throttle — those exist to stop the *background* check hammering Homebrew, and someone
    /// clicking a button is asking now.
    public func checkNow() async {
        guard !isChecking else { return }
        guard updater.isSupported else {
            status = .unsupported
            return
        }
        // No notification: whoever clicked is looking at the result already.
        await performCheck(at: now(), notifyOnFailure: false)
    }

    private func performCheck(at attemptedAt: Date, notifyOnFailure: Bool) async {
        isChecking = true
        status = .checking
        attemptStore.lastAttempt = attemptedAt
        let outcome = await updater.installIfAvailable()
        isChecking = false

        switch outcome {
        case .unsupported:
            status = .unsupported
        case .upToDate:
            status = .upToDate(at: attemptedAt)
        case .updated:
            status = .updated(at: attemptedAt)
            // The Homebrew service is keep_alive successful_exit:false, so exiting non-zero
            // is how we relaunch onto the binary we just installed.
            exitHandler(Self.restartExitStatus)
        case .failed(let failure):
            status = .failed(failure, at: attemptedAt)
            logger.record(failure, at: attemptedAt)
            guard notifyOnFailure else { return }
            notifier.post(NotificationEvent(
                id: "cc-meter-auto-update-failed",
                title: "cc-meter update failed",
                body: "Automatic update failed during \(failure.stage.rawValue). See ~/Library/Logs/cc-meter/update.log."
            ))
        }
    }

    private func reconcileScheduling() {
        guard enabled, updater.isSupported else {
            cancelScheduling()
            return
        }
        guard initialToken == nil, repeatingToken == nil else { return }

        initialToken = scheduler.schedule(
            after: Self.initialDelay,
            repeating: nil,
            action: scheduledAction()
        )
        repeatingToken = scheduler.schedule(
            after: Self.dueCheckInterval,
            repeating: Self.dueCheckInterval,
            action: scheduledAction()
        )
    }

    private func cancelScheduling() {
        initialToken?.cancel()
        repeatingToken?.cancel()
        initialToken = nil
        repeatingToken = nil
    }

    private func scheduledAction() -> () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                await self?.runDueCheck()
            }
        }
    }
}
