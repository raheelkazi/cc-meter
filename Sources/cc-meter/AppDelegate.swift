import AppKit
import CCMeterCore
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?
    private var settingsWindow: SettingsWindowController?
    private let preferencesStore = UserDefaultsPreferencesStore()
    private var dashboard: DashboardViewModel?
    private var autoUpdateController: AutomaticUpdateControlling?
    private var usageModel: UsageDetailViewModel?
    private var usageIndexer: UsageIndexer?
    private var usageIndexTimer: Timer?

    static func makeAutoUpdateController(environment: [String: String]) -> AutoUpdateController {
        let updater = HomebrewUpdater(
            resolver: HomebrewExecutableResolver(),
            runner: UpdateCommandProcess(),
            environment: environment
        )
        return AutoUpdateController(
            updater: updater,
            logger: FileUpdateLogger(),
            notifier: OsascriptNotifier(),
            scheduler: TimerUpdateScheduler(),
            attemptStore: UserDefaultsUpdateAttemptStore(),
            exitHandler: { Darwin.exit($0) }
        )
    }

    /// Live reset time for a provider's window, read from its meter, so the Usage tab's window
    /// lines up with the Limits tab. 5h -> the session window; 7d -> the first weekly window.
    static func resetsAt(_ dashboard: DashboardViewModel,
                         provider: UsageProvider, window: UsageWindow) -> Date? {
        let meter = provider == .claude ? dashboard.claude : dashboard.codex
        guard case .ok(let usage) = meter.state else { return nil }
        switch window {
        case .fiveHour:
            return usage.limits.first(where: { $0.kind.isSessionWindow })?.resetsAt
        case .sevenDay:
            return usage.limits.first(where: { !$0.kind.isSessionWindow })?.resetsAt
        }
    }

    static func startAutomaticUpdates(
        _ controller: AutomaticUpdateControlling,
        preferences: Preferences
    ) {
        controller.start(enabled: preferences.automaticUpdatesEnabled)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.log("didFinishLaunching enter")
        // Bail out if another cc-meter is already running (e.g. launch-at-login
        // plus a manual start) so we don't double up menu bar items or pollers.
        let acquired = SingleInstance.acquire()
        DebugLog.log("SingleInstance.acquire -> \(acquired)")
        guard acquired else {
            NSApplication.shared.terminate(nil)
            return
        }

        // Reflect the real login-item state so the toggle isn't lying on launch.
        var preferences = preferencesStore.load()
        preferences.launchAtLogin = LoginItem.isEnabled
        preferencesStore.save(preferences)

        let reader = KeychainReader(service: "Claude Code-credentials", account: NSUserName())
        let writer = KeychainWriter(service: "Claude Code-credentials", account: NSUserName())
        let provider = KeychainTokenProvider(reader: reader)
        let credentialStore = KeychainCredentialStore(reader: reader, writer: writer)
        let transport = URLSessionTransport(session: .shared)
        let refresher = OAuthTokenRefresher(store: credentialStore, transport: transport)
        let client = UsageClient(tokenProvider: provider,
                                 transport: transport,
                                 refresher: refresher,
                                 now: { Date() })

        let history = FileHistoryStore(url: FileHistoryStore.defaultURL(provider: .claude))

        // 180s default polling: the usage endpoint's rate budget is shared with
        // Claude Code itself (a handful of requests per ~5 minutes), so a tighter
        // cadence trips 429s. DiskUsageStore seeds the display with the last good
        // fetch at startup so a rate-limited first poll shows real numbers.
        let claudeMeter = MeterViewModel(provider: .claude,
                                         client: client,
                                         interval: preferences.pollInterval,
                                         store: DiskUsageStore.standard(provider: .claude),
                                         preferences: preferences,
                                         history: history,
                                         notifier: ThresholdNotifier(),
                                         notificationSink: OsascriptNotifier())

        let codexClient = CodexUsageClient(
            resolver: CodexExecutableResolver(),
            transport: CodexAppServerProcess(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "development"
        )
        let codexMeter = MeterViewModel(
            provider: .codex,
            client: codexClient,
            interval: preferences.pollInterval,
            store: DiskUsageStore.standard(provider: .codex),
            preferences: preferences,
            history: FileHistoryStore(url: FileHistoryStore.defaultURL(provider: .codex)),
            notifier: ThresholdNotifier(),
            notificationSink: OsascriptNotifier()
        )
        let dashboard = DashboardViewModel(claude: claudeMeter, codex: codexMeter)
        self.dashboard = dashboard

        var usageModel: UsageDetailViewModel?
        if preferences.usageBreakdownEnabled {
            let claudeDir = UsageIndexer.defaultClaudeProjectsDir()
            let codexDir = UsageIndexer.defaultCodexSessionsDir()
            let eventStore = FileUsageEventStore(url: FileUsageEventStore.defaultURL())
            let indexer = UsageIndexer(
                fileSystem: SystemFileSystem(),
                store: eventStore,
                cursors: FileCursorStore(url: FileCursorStore.defaultURL()),
                claudeProjectsDir: claudeDir,
                codexSessionsDir: codexDir)
            self.usageIndexer = indexer

            let model = UsageDetailViewModel(
                store: eventStore,
                resetsAt: { [weak dashboard] provider, window in
                    guard let dashboard else { return nil }
                    return Self.resetsAt(dashboard, provider: provider, window: window)
                },
                indexerTick: { indexer.tick() },   // synchronous; the view-model runs it off-main
                logsPresent: { provider in
                    FileManager.default.fileExists(atPath: provider == .claude ? claudeDir : codexDir)
                })
            usageModel = model
            self.usageModel = model

            // First index build (off-main; flips hasIndexed when done) + periodic refresh.
            // refreshInBackground never blocks the main thread (the #16 lesson).
            model.refreshInBackground()
            let timer = Timer.scheduledTimer(withTimeInterval: preferences.pollInterval, repeats: true) { _ in
                Task { @MainActor in model.refreshInBackground() }
            }
            self.usageIndexTimer = timer
        }

        // Built before the settings window: Settings shows the updater's status and can
        // trigger a check, so it needs the controller to observe.
        let autoUpdateController = Self.makeAutoUpdateController(
            environment: ProcessInfo.processInfo.environment
        )
        self.autoUpdateController = autoUpdateController

        settingsWindow = SettingsWindowController(
            loadPreferences: { [preferencesStore] in preferencesStore.load() },
            onChange: { [weak self] prefs in self?.applyPreferences(prefs) },
            updates: autoUpdateController
        )

        let controller = MenuBarController(dashboard: dashboard, usageModel: usageModel) { [weak self] in
            self?.settingsWindow?.show()
        }
        controller.install()
        self.controller = controller

        Self.startAutomaticUpdates(autoUpdateController, preferences: preferences)

        dashboard.start()
        DebugLog.log("didFinishLaunching complete; entering run loop")
    }

    private func applyPreferences(_ preferences: Preferences) {
        let previous = preferencesStore.load()
        preferencesStore.save(preferences)
        dashboard?.apply(preferences)
        autoUpdateController?.apply(enabled: preferences.automaticUpdatesEnabled)
        if preferences.launchAtLogin != previous.launchAtLogin {
            LoginItem.setEnabled(preferences.launchAtLogin)
        }
    }
}
