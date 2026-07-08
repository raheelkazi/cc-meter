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

    func testSpendAbsentIsNil() throws {
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Fixtures.usageJSON)
            .toUsage(now: Date())
        XCTAssertNil(usage.spend)
    }

    func testSpendDecodesCentsToDollars() throws {
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Fixtures.usageWithSpendJSON)
            .toUsage(now: Date())
        XCTAssertEqual(usage.spend?.amount, 12.34)
        XCTAssertEqual(usage.spend?.limit, 50.0)
        XCTAssertEqual(usage.spend?.currency, "USD")
        XCTAssertEqual(usage.spend?.percent ?? 0, 24.68, accuracy: 0.001)
    }

    func testSpendPercentNilWithoutLimit() {
        let spend = Spend(amount: 5, limit: nil, currency: "USD")
        XCTAssertNil(spend.percent)
    }

    func testMalformedSpendDoesNotFailWholeResponse() throws {
        // Real endpoint returned spend.used as an object, not a number. A spend
        // shape mismatch must NOT blank the meter: limits still decode, spend nil.
        let json = """
        {
          "limits": [
            { "kind": "session", "percent": 20, "resets_at": "2026-07-03T21:09:59+00:00", "is_active": true }
          ],
          "spend": { "used": { "amount_cents": 1234, "currency": "USD" }, "limit": { "amount_cents": 5000 } }
        }
        """.data(using: .utf8)!
        let usage = try JSONDecoder().decode(UsageResponse.self, from: json).toUsage(now: Date())
        XCTAssertEqual(usage.limits.count, 1)
        XCTAssertNil(usage.spend)
    }
}
