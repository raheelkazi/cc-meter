import XCTest
@testable import CCMeterCore

final class DecodingTests: XCTestCase {
    func testDecodesThreeLimitsWithLabels() throws {
        let now = Date(timeIntervalSince1970: 1783100000)
        let response = try JSONDecoder().decode(UsageResponse.self, from: Fixtures.usageJSON)
        let usage = response.toUsage(now: now)

        XCTAssertEqual(usage.limits.count, 3)
        XCTAssertEqual(usage.limits[0].kind, .session)
        XCTAssertEqual(usage.limits[0].kind.label, "5-hour")
        XCTAssertEqual(usage.limits[1].kind, .weeklyAll)
        XCTAssertEqual(usage.limits[1].kind.label, "7-day")
        XCTAssertEqual(usage.limits[2].kind, .weeklyScoped(model: "Fable"))
        XCTAssertEqual(usage.limits[2].kind.label, "7-day (Fable)")

        XCTAssertEqual(usage.limits[2].percent, 54)
        XCTAssertTrue(usage.limits[2].isActive)
        XCTAssertFalse(usage.limits[0].isActive)
        XCTAssertEqual(usage.fetchedAt, now)
    }

    func testDropsUnknownKindGracefully() throws {
        let json = """
        { "limits": [ { "kind": "future_kind", "percent": 10,
          "resets_at": "2026-07-05T13:59:59+00:00", "is_active": false } ] }
        """.data(using: .utf8)!
        let usage = try JSONDecoder().decode(UsageResponse.self, from: json).toUsage(now: Date())
        XCTAssertEqual(usage.limits.count, 0)
    }
}
