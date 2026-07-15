import XCTest
@testable import CCMeterCore

@MainActor
final class StatusMonitorTests: XCTestCase {
    private final class FakeClient: StatusFetching {
        var results: [UsageProvider: ProviderStatus?] = [:]
        func fetch(_ provider: UsageProvider) async -> ProviderStatus? { results[provider] ?? nil }
    }

    func testRefreshPublishesPerProviderStatus() async {
        let client = FakeClient()
        client.results[.claude] = ProviderStatus(provider: .claude, level: .major, headline: "Outage")
        client.results[.codex] = ProviderStatus(provider: .codex, level: .ok)
        let monitor = StatusMonitor(client: client, interval: 300)
        await monitor.refresh()
        XCTAssertEqual(monitor.level(for: .claude), .major)
        XCTAssertEqual(monitor.level(for: .codex), .ok)
        XCTAssertEqual(monitor.status(for: .claude)?.headline, "Outage")
    }

    func testFailedFetchKeepsLastKnown() async {
        let client = FakeClient()
        client.results[.claude] = ProviderStatus(provider: .claude, level: .major, headline: "Outage")
        let monitor = StatusMonitor(client: client, interval: 300)
        await monitor.refresh()
        XCTAssertEqual(monitor.level(for: .claude), .major)

        client.results[.claude] = .some(nil)   // next fetch fails
        await monitor.refresh()
        XCTAssertEqual(monitor.level(for: .claude), .major, "a failed fetch must not clear a known outage")
    }

    func testUnknownProviderLevelIsOk() {
        let monitor = StatusMonitor(client: FakeClient(), interval: 300)
        XCTAssertEqual(monitor.level(for: .codex), .ok)
    }
}
