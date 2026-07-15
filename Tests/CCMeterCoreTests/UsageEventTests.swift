import XCTest
@testable import CCMeterCore

final class UsageEventTests: XCTestCase {
    func testTotalExcludesReasoningWhichIsASubsetOfOutput() {
        // Codex reasoning_output_tokens is already inside output_tokens, so summing it double-counts.
        let t = TokenCounts(input: 100, output: 20, cacheCreation: 5, cacheRead: 200, reasoning: 3)
        XCTAssertEqual(t.total, 325)
    }

    func testAdditionIsElementwise() {
        let a = TokenCounts(input: 1, output: 2, cacheCreation: 3, cacheRead: 4, reasoning: 5)
        let b = TokenCounts(input: 10, output: 20, cacheCreation: 30, cacheRead: 40, reasoning: 50)
        XCTAssertEqual(a + b, TokenCounts(input: 11, output: 22, cacheCreation: 33, cacheRead: 44, reasoning: 55))
    }

    func testEventRoundTripsThroughCodable() throws {
        let event = UsageEvent(provider: .claude, at: Date(timeIntervalSince1970: 1_000_000),
                               project: "cc-meter", model: "claude-opus-4-8",
                               tokens: TokenCounts(input: 10, output: 2), dedupKey: "claude:r1:m1")
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(UsageEvent.self, from: data), event)
    }
}
