import XCTest
@testable import CCMeterCore

final class ModelPriceTableTests: XCTestCase {
    func testKnownModelCostsSumPerTokenClass() {
        // Opus: $15/M input, $75/M output, $18.75/M cache write, $1.50/M cache read.
        let tokens = TokenCounts(input: 1_000_000, output: 1_000_000,
                                 cacheCreation: 1_000_000, cacheRead: 1_000_000)
        let cost = ModelPriceTable.notionalCost(tokens, model: "claude-opus-4-8")
        XCTAssertNotNil(cost)
        XCTAssertEqual(cost!, 15 + 75 + 18.75 + 1.50, accuracy: 0.0001)
    }

    func testUnknownModelHasNoPrice() {
        XCTAssertNil(ModelPriceTable.price(for: "gpt-5.6-sol"))
        XCTAssertNil(ModelPriceTable.notionalCost(TokenCounts(input: 10), model: "gpt-5.6-sol"))
    }

    func testPricesAsOfIsStamped() {
        XCTAssertFalse(ModelPriceTable.pricesAsOf.isEmpty)
    }
}
