import XCTest
@testable import CCMeterCore

private final class DashboardStubClient: UsageFetching {
    var result: Result<Usage, UsageError>
    private(set) var fetchCount = 0

    init(_ result: Result<Usage, UsageError>) { self.result = result }

    func fetch() async -> Result<Usage, UsageError> {
        fetchCount += 1
        return result
    }
}

@MainActor
final class DashboardViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func usage(_ percent: Double) -> Usage {
        Usage(limits: [
            UsageLimit(kind: .session, percent: percent,
                       resetsAt: now.addingTimeInterval(3600), isActive: true)
        ], fetchedAt: now)
    }

    private func makeDashboard(claude: Result<Usage, UsageError>,
                               codex: Result<Usage, UsageError>)
        -> (DashboardViewModel, DashboardStubClient, DashboardStubClient) {
        let claudeClient = DashboardStubClient(claude)
        let codexClient = DashboardStubClient(codex)
        let claudeMeter = MeterViewModel(provider: .claude, client: claudeClient, now: { self.now })
        let codexMeter = MeterViewModel(provider: .codex, client: codexClient, now: { self.now })
        return (DashboardViewModel(claude: claudeMeter, codex: codexMeter),
                claudeClient, codexClient)
    }

    func testCodexStartsHiddenAndAppearsAfterSuccess() async {
        let (dashboard, _, _) = makeDashboard(claude: .success(usage(20)),
                                               codex: .success(usage(40)))
        XCTAssertFalse(dashboard.showsCodex)
        await dashboard.refresh()
        XCTAssertTrue(dashboard.showsCodex)
    }

    func testMissingOrUnauthorizedCodexStaysHidden() async {
        for error in [UsageError.noCredentials, .unauthorized] {
            let (dashboard, _, _) = makeDashboard(claude: .success(usage(20)),
                                                   codex: .failure(error))
            await dashboard.refresh()
            XCTAssertFalse(dashboard.showsCodex)
        }
    }

    func testTransientAndHardErrorsKeepPreviouslyDetectedCodexVisible() async {
        let (dashboard, _, codexClient) = makeDashboard(claude: .success(usage(20)),
                                                         codex: .success(usage(40)))
        await dashboard.refresh()
        XCTAssertTrue(dashboard.showsCodex)

        codexClient.result = .failure(.network("offline"))
        await dashboard.refresh()
        XCTAssertTrue(dashboard.showsCodex)
        XCTAssertNotNil(dashboard.codex.staleSnapshot)

        codexClient.result = .failure(.badResponse("changed"))
        await dashboard.refresh()
        XCTAssertTrue(dashboard.showsCodex)
    }

    func testInitialMalformedCodexResponseRemainsHidden() async {
        let (dashboard, _, _) = makeDashboard(claude: .success(usage(20)),
                                               codex: .failure(.badResponse("changed")))
        await dashboard.refresh()
        XCTAssertFalse(dashboard.showsCodex)
    }

    func testCompactUsesHighestVisibleProvider() async {
        let (dashboard, _, _) = makeDashboard(claude: .success(usage(20)),
                                               codex: .success(usage(70)))
        await dashboard.refresh()
        XCTAssertEqual(dashboard.compact?.percent, 70)
    }

    func testCompactProvidersExposeClaudeThenCodexWithIndependentValues() async {
        let (dashboard, _, _) = makeDashboard(claude: .success(usage(20)),
                                               codex: .success(usage(70)))
        await dashboard.refresh()

        XCTAssertEqual(dashboard.compactProviders, [
            ProviderCompactSummary(provider: .claude, percent: 20, color: .green),
            ProviderCompactSummary(provider: .codex, percent: 70, color: .amber)
        ])
    }

    func testCompactProvidersOmitHiddenCodex() async {
        let (dashboard, _, _) = makeDashboard(claude: .success(usage(20)),
                                               codex: .failure(.unauthorized))
        await dashboard.refresh()

        XCTAssertEqual(dashboard.compactProviders, [
            ProviderCompactSummary(provider: .claude, percent: 20, color: .green)
        ])
    }

    func testCompactProvidersCanShowCodexAlone() async {
        let (dashboard, _, _) = makeDashboard(claude: .failure(.unauthorized),
                                               codex: .success(usage(55)))
        await dashboard.refresh()

        XCTAssertEqual(dashboard.compactProviders, [
            ProviderCompactSummary(provider: .codex, percent: 55, color: .amber)
        ])
        XCTAssertEqual(dashboard.compact?.percent, 55)
        XCTAssertFalse(dashboard.hasError)
    }

    func testValidCodexCompactSurvivesClaudeError() async {
        let (dashboard, _, _) = makeDashboard(claude: .failure(.unauthorized),
                                               codex: .success(usage(55)))
        await dashboard.refresh()
        XCTAssertEqual(dashboard.compact?.percent, 55)
        XCTAssertFalse(dashboard.hasError)
    }

    func testRefreshToggleAndPreferencesFanOut() async {
        let (dashboard, claudeClient, codexClient) = makeDashboard(claude: .success(usage(20)),
                                                                   codex: .success(usage(40)))
        await dashboard.refresh()
        XCTAssertEqual(claudeClient.fetchCount, 1)
        XCTAssertEqual(codexClient.fetchCount, 1)

        dashboard.toggleMode()
        XCTAssertEqual(dashboard.claude.displayMode, .remaining)
        XCTAssertEqual(dashboard.codex.displayMode, .remaining)

        dashboard.toggleMode()
        dashboard.apply(Preferences(defaultShowRemaining: true))
        XCTAssertEqual(dashboard.claude.displayMode, .remaining)
        XCTAssertEqual(dashboard.codex.displayMode, .remaining)
    }
}
