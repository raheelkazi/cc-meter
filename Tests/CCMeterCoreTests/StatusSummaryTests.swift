import XCTest
@testable import CCMeterCore

final class StatusSummaryTests: XCTestCase {
    func testDecodesOperationalWithComponentsAndIncidents() throws {
        let json = """
        {"status":{"indicator":"none","description":"All Systems Operational"},
         "components":[{"name":"Claude Code","status":"operational"},
                       {"name":"Claude API (api.anthropic.com)","status":"degraded_performance"}],
         "incidents":[{"name":"Elevated errors","impact":"minor","status":"investigating","shortlink":"https://stspg.io/x"}]}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(StatusSummary.self, from: json)
        XCTAssertEqual(s.status.indicator, "none")
        XCTAssertEqual(s.components.map(\.name), ["Claude Code", "Claude API (api.anthropic.com)"])
        XCTAssertEqual(s.components[1].status, "degraded_performance")
        XCTAssertEqual(s.incidents.first?.impact, "minor")
        XCTAssertEqual(s.incidents.first?.shortlink, "https://stspg.io/x")
    }

    func testMissingArraysDefaultToEmpty() throws {
        let json = """
        {"status":{"indicator":"none","description":null}}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(StatusSummary.self, from: json)
        XCTAssertTrue(s.components.isEmpty)
        XCTAssertTrue(s.incidents.isEmpty)
        XCTAssertNil(s.status.description)
    }
}
