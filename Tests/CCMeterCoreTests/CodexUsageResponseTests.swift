import XCTest
@testable import CCMeterCore

final class CodexUsageResponseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testMapsDictionaryLimitsWithoutDuplicatingTopLevel() throws {
        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self,
                                                from: Fixtures.codexMultiLimitJSON)
        let usage = try response.toUsage(now: now)

        XCTAssertEqual(usage.limits.map(\.kind.label), [
            "5-hour", "7-day", "7-day (GPT-5.3-Codex-Spark)"
        ])
        XCTAssertEqual(usage.limits.map(\.percent), [25, 40, 10])
        XCTAssertEqual(usage.limits[0].resetsAt, Date(timeIntervalSince1970: 1_783_900_000))
        XCTAssertTrue(usage.limits.allSatisfy(\.isActive))
    }

    func testMapsDynamicDurationsAndIgnoresMissingWindow() throws {
        let data = """
        {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,
          "primary":{"usedPercent":3,"windowDurationMins":1440,"resetsAt":2000000},
          "secondary":{"usedPercent":4,"windowDurationMins":90,"resetsAt":2000100}}}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)

        XCTAssertEqual(try response.toUsage(now: now).limits.map(\.kind.label),
                       ["1-day", "90-minute"])
    }

    func testSuccessfulEmptyResponseProducesNoLimits() throws {
        let data = "{\"id\":2,\"result\":{\"rateLimits\":null,\"rateLimitsByLimitId\":{}}}"
            .data(using: .utf8)!
        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        XCTAssertTrue(try response.toUsage(now: now).limits.isEmpty)
    }

    func testDuplicateLabelsGainStableLimitIDSuffix() throws {
        let data = """
        {"id":2,"result":{"rateLimitsByLimitId":{
          "alpha":{"limitId":"alpha","primary":{"usedPercent":1,"windowDurationMins":60,"resetsAt":2000000}},
          "beta":{"limitId":"beta","primary":{"usedPercent":2,"windowDurationMins":60,"resetsAt":2000000}}
        }}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        XCTAssertEqual(try response.toUsage(now: now).limits.map(\.kind.label),
                       ["1-hour [alpha]", "1-hour [beta]"])
    }

    func testRPCErrorIsExposedByMapping() throws {
        let data = "{\"id\":2,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}"
            .data(using: .utf8)!
        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)
        XCTAssertThrowsError(try response.toUsage(now: now)) { error in
            XCTAssertEqual(error as? CodexProtocolError,
                           CodexProtocolError(code: -32601, message: "Method not found"))
        }
    }
}
