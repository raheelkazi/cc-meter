import AppKit
import CCMeterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?
    private var settingsWindow: SettingsWindowController?
    private let preferencesStore = UserDefaultsPreferencesStore()
    private var viewModel: MeterViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bail out if another cc-meter is already running (e.g. launch-at-login
        // plus a manual start) so we don't double up menu bar items or pollers.
        guard SingleInstance.acquire() else {
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

        let history = FileHistoryStore(url: FileHistoryStore.defaultURL())

        // 180s default polling: the usage endpoint's rate budget is shared with
        // Claude Code itself (a handful of requests per ~5 minutes), so a tighter
        // cadence trips 429s. DiskUsageStore seeds the display with the last good
        // fetch at startup so a rate-limited first poll shows real numbers.
        let viewModel = MeterViewModel(client: client,
                                       interval: preferences.pollInterval,
                                       store: DiskUsageStore.standard(),
                                       preferences: preferences,
                                       history: history,
                                       notifier: ThresholdNotifier(),
                                       notificationSink: OsascriptNotifier())
        self.viewModel = viewModel

        settingsWindow = SettingsWindowController(
            loadPreferences: { [preferencesStore] in preferencesStore.load() },
            onChange: { [weak self] prefs in self?.applyPreferences(prefs) }
        )

        let controller = MenuBarController(viewModel: viewModel) { [weak self] in
            self?.settingsWindow?.show()
        }
        controller.install()
        self.controller = controller

        viewModel.start()
    }

    private func applyPreferences(_ preferences: Preferences) {
        let previous = preferencesStore.load()
        preferencesStore.save(preferences)
        viewModel?.apply(preferences)
        if preferences.launchAtLogin != previous.launchAtLogin {
            LoginItem.setEnabled(preferences.launchAtLogin)
        }
    }
}
