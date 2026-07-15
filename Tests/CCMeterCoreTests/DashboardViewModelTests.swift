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

    /// Multi-limit usage, one limit per percent, in a stable window order.
    private func usage(_ percents: [Double]) -> Usage {
        let kinds: [WindowKind] = [.session, .weeklyAll, .weeklyScoped(model: "Fable")]
        let limits = percents.enumerated().map { index, percent in
            UsageLimit(kind: kinds[index % kinds.count],
                       percent: percent,
                       resetsAt: now.addingTimeInterval(3600 * Double(index + 1)),
                       isActive: true)
        }
        return Usage(limits: limits, fetchedAt: now)
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

    // MARK: - Critical alert
    //
    // The flat popover has no hero, so a limit in trouble has to announce itself.
    // "Critical" reuses the app's own severity definition (usageColor -> .red), rather
    // than introducing a second threshold constant that could drift away from the bars.

    func testNoAlertWhileEveryLimitIsBelowCritical() async {
        let (dashboard, _, _) = makeDashboard(claude: .success(usage([89, 60])),
                                              codex: .success(usage([70])))
        await dashboard.refresh()

        XCTAssertNil(dashboard.alert, "89% is amber, not red — nothing has earned a focal point")
    }

    func testAlertNamesTheWorstCriticalLimitAcrossBothProviders() async throws {
        let (dashboard, _, _) = makeDashboard(claude: .success(usage([91])),
                                              codex: .success(usage([94])))
        await dashboard.refresh()

        let alert = try XCTUnwrap(dashboard.alert)
        XCTAssertEqual(alert.provider, .codex, "the binding limit is Codex's, not Claude's")
        XCTAssertEqual(alert.percent, 94)
        XCTAssertEqual(alert.label, "5-hour")
    }

    func testAlertCountsOtherElevatedLimitsWithoutStackingBanners() async throws {
        // 94 red, 61 amber, 2 green -> the alert names the 94 and counts the 61.
        let (dashboard, _, _) = makeDashboard(claude: .success(usage([94, 61, 2])),
                                              codex: .success(usage([14])))
        await dashboard.refresh()

        let alert = try XCTUnwrap(dashboard.alert)
        XCTAssertEqual(alert.percent, 94)
        XCTAssertEqual(alert.otherElevatedCount, 1, "the amber 61% counts; the greens do not")
    }

    func testAlertPercentFollowsTheUsedLeftToggle() async throws {
        let (dashboard, _, _) = makeDashboard(claude: .success(usage([94])),
                                              codex: .failure(.noCredentials))
        await dashboard.refresh()
        dashboard.toggleMode()

        let alert = try XCTUnwrap(dashboard.alert)
        XCTAssertEqual(alert.percent, 6, "in Left mode the alert reads remaining, like every row")
    }

    func testAlertSeverityIgnoresTheUsedLeftToggle() async throws {
        // 6% *left* is still critical: severity must come from used%, not the displayed number.
        let (dashboard, _, _) = makeDashboard(claude: .success(usage([94])),
                                              codex: .failure(.noCredentials))
        await dashboard.refresh()
        dashboard.toggleMode()

        XCTAssertNotNil(dashboard.alert, "toggling to Left must not silence a critical limit")
    }

    func testNoAlertWhileLoading() {
        let (dashboard, _, _) = makeDashboard(claude: .success(usage([94])),
                                              codex: .success(usage([94])))
        XCTAssertNil(dashboard.alert)
    }

    func testForwardsStatusLevelsFromMonitor() async {
        final class FakeClient: StatusFetching {
            func fetch(_ provider: UsageProvider) async -> ProviderStatus? {
                provider == .claude ? ProviderStatus(provider: .claude, level: .degraded, headline: "x") : nil
            }
        }
        let monitor = StatusMonitor(client: FakeClient(), interval: 300)
        await monitor.refresh()
        // Mirror this file's existing meter construction (DashboardStubClient + usage(_:) helpers).
        let claudeMeter = MeterViewModel(provider: .claude, client: DashboardStubClient(.success(usage(20))), now: { self.now })
        let codexMeter = MeterViewModel(provider: .codex, client: DashboardStubClient(.success(usage(20))), now: { self.now })
        let dashboard = DashboardViewModel(claude: claudeMeter, codex: codexMeter, statusMonitor: monitor)
        XCTAssertEqual(dashboard.statusLevels[.claude], .degraded)
        XCTAssertEqual(dashboard.providerStatuses[.claude]?.headline, "x")
    }

}
