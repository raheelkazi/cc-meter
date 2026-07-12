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

    func testUnnamedCodexGroupUsesActiveModelDisplayNameWithoutChangingIdentity() throws {
        let data = """
        {"id":2,"result":{"rateLimitsByLimitId":{
          "codex":{"limitId":"codex","limitName":null,
            "primary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":2000000}}
        }}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)

        let limit = try XCTUnwrap(response.toUsage(
            now: now,
            unnamedCodexModelName: "GPT-5.6-Sol"
        ).limits.first)

        XCTAssertEqual(limit.kind.label, "7-day (GPT-5.6-Sol)")
        XCTAssertEqual(limit.kind.identity, "codex:codex:primary")
    }

    func testExplicitLimitNameWinsOverActiveModelDisplayName() throws {
        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self,
                                                from: Fixtures.codexMultiLimitJSON)

        XCTAssertEqual(
            try response.toUsage(now: now, unnamedCodexModelName: "GPT-5.6-Sol")
                .limits.map(\.kind.label),
            ["5-hour (GPT-5.6-Sol)", "7-day (GPT-5.6-Sol)",
             "7-day (GPT-5.3-Codex-Spark)"]
        )
    }

    func testMissingActiveModelMetadataKeepsGenericLabel() throws {
        let data = """
        {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,
          "primary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":2000000}}}}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)

        XCTAssertEqual(try response.toUsage(now: now).limits.first?.kind.label, "7-day")
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

    func testIdentityStaysStableWhenDuplicateMembershipChanges() throws {
        let bothData = """
        {"id":2,"result":{"rateLimitsByLimitId":{
          "alpha":{"limitId":"alpha","primary":{"usedPercent":1,"windowDurationMins":60,"resetsAt":2000000}},
          "beta":{"limitId":"beta","primary":{"usedPercent":2,"windowDurationMins":60,"resetsAt":2000000}}
        }}}
        """.data(using: .utf8)!
        let alphaOnlyData = """
        {"id":2,"result":{"rateLimitsByLimitId":{
          "alpha":{"limitId":"alpha","primary":{"usedPercent":3,"windowDurationMins":60,"resetsAt":2000000}}
        }}}
        """.data(using: .utf8)!
        let both = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: bothData)
        let alphaOnly = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: alphaOnlyData)

        let bothUsage = try both.toUsage(now: now)
        let alphaOnlyUsage = try alphaOnly.toUsage(now: now)
        let firstIdentity = bothUsage.limits[0].kind.identity
        let secondIdentity = alphaOnlyUsage.limits[0].kind.identity
        XCTAssertEqual(firstIdentity, "codex:alpha:primary")
        XCTAssertEqual(secondIdentity, firstIdentity)
    }
}
