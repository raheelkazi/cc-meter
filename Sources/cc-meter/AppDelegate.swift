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
        let viewModel = MeterViewModel(client: client, interval: 60)

        let controller = MenuBarController(viewModel: viewModel)
        controller.install()
        self.controller = controller

        viewModel.start()
    }
}
