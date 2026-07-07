import AppKit
import CCMeterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let reader = KeychainReader(service: "Claude Code-credentials", account: NSUserName())
        let provider = KeychainTokenProvider(reader: reader)
        let client = UsageClient(tokenProvider: provider,
                                 transport: URLSessionTransport(session: .shared),
                                 now: { Date() })
        // 180s polling: the usage endpoint's rate budget is shared with Claude
        // Code itself and is only a handful of requests per ~5 minutes, so a
        // 60s cadence kept tripping 429s.
        let viewModel = MeterViewModel(client: client,
                                       interval: 180,
                                       store: DiskUsageStore.standard())

        let controller = MenuBarController(viewModel: viewModel)
        controller.install()
        self.controller = controller

        viewModel.start()
    }
}
