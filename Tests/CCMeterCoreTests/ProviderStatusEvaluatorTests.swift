import XCTest
@testable import CCMeterCore

final class ProviderStatusEvaluatorTests: XCTestCase {
    private let url = URL(string: "https://status.claude.com")!
    private func summary(indicator: String = "none", comps: [(String,String)] = [], incidents: [(String,String)] = []) -> StatusSummary {
        let comp = comps.map { "{\"name\":\"\($0.0)\",\"status\":\"\($0.1)\"}" }.joined(separator: ",")
        let inc = incidents.map { "{\"name\":\"\($0.0)\",\"impact\":\"\($0.1)\",\"status\":\"investigating\",\"shortlink\":\"https://stspg.io/x\"}" }.joined(separator: ",")
        let json = "{\"status\":{\"indicator\":\"\(indicator)\",\"description\":\"desc\"},\"components\":[\(comp)],\"incidents\":[\(inc)]}"
        return try! JSONDecoder().decode(StatusSummary.self, from: json.data(using: .utf8)!)
    }

    func testAllOperationalIsOk() {
        let s = summary(comps: [("Claude Code","operational"), ("claude.ai","major_outage")])
        // claude.ai is NOT a relevant component for the Claude provider, so its outage is ignored.
        let r = ProviderStatusEvaluator.evaluate(s, provider: .claude, statusURL: url)
        XCTAssertEqual(r.level, .ok)
    }

    func testDegradedRelevantComponent() {
        let s = summary(comps: [("Claude API (api.anthropic.com)","degraded_performance")])
        XCTAssertEqual(ProviderStatusEvaluator.evaluate(s, provider: .claude, statusURL: url).level, .degraded)
    }

    func testMajorOutageComponent() {
        let s = summary(comps: [("Claude Code","major_outage")])
        XCTAssertEqual(ProviderStatusEvaluator.evaluate(s, provider: .claude, statusURL: url).level, .major)
    }

    func testActiveIncidentDrivesLevelAndHeadline() {
        let s = summary(comps: [("Claude Code","operational")], incidents: [("Elevated errors","major")])
        let r = ProviderStatusEvaluator.evaluate(s, provider: .claude, statusURL: url)
        XCTAssertEqual(r.level, .major)
        XCTAssertEqual(r.headline, "Elevated errors")
        XCTAssertEqual(r.url?.absoluteString, "https://stspg.io/x")
    }

    func testCodexMatchesCodexApi() {
        let s = summary(comps: [("Codex API","partial_outage"), ("Batch","major_outage")])
        XCTAssertEqual(ProviderStatusEvaluator.evaluate(s, provider: .codex, statusURL: url).level, .degraded)
    }

    func testFallsBackToIndicatorWhenNoComponentMatches() {
        let s = summary(indicator: "major", comps: [("Unrelated","operational")])
        XCTAssertEqual(ProviderStatusEvaluator.evaluate(s, provider: .codex, statusURL: url).level, .major)
    }

    func testUnknownStatusStringsAreSafe() {
        let s = summary(comps: [("Claude Code","brand_new_status")])
        XCTAssertEqual(ProviderStatusEvaluator.evaluate(s, provider: .claude, statusURL: url).level, .ok)
    }
}
