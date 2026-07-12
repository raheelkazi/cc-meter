import Foundation

@MainActor
public protocol AutomaticUpdateControlling: AnyObject {
    func start(enabled: Bool)
    func apply(enabled: Bool)
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
public final class AutoUpdateController: AutomaticUpdateControlling {
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
