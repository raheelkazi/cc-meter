import XCTest
@testable import CCMeterCore

final class BurnRateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func samples(_ points: [(minutes: Double, percent: Double)]) -> [HistorySample] {
        points.map { HistorySample(kindLabel: "5-hour", percent: $0.percent,
                                   at: start.addingTimeInterval($0.minutes * 60)) }
    }

    func testRateNilWithoutEnoughSpan() {
        // Two points only 30s apart -> below the 120s minimum span.
        let s = [HistorySample(kindLabel: "x", percent: 0, at: start),
                 HistorySample(kindLabel: "x", percent: 5, at: start.addingTimeInterval(30))]
        XCTAssertNil(burnRatePerHour(s))
    }

    func testRateComputesPercentPerHour() {
        // 10% over 30 minutes -> 20%/hour.
        let rate = burnRatePerHour(samples([(0, 0), (15, 5), (30, 10)]))
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate!, 20, accuracy: 0.001)
    }

    func testProjectionTimeToLimit() {
        // At 20%/hr from 60% used -> 40% left -> 2 hours to 100%.
        let projection = burnProjection(samples: samples([(0, 40), (30, 50), (60, 60)]),
                                        currentPercent: 60,
                                        resetsAt: start.addingTimeInterval(10 * 3600),
                                        now: start.addingTimeInterval(60 * 60))
        XCTAssertNotNil(projection)
        XCTAssertEqual(projection!.timeToLimit, 2 * 3600, accuracy: 1)
        XCTAssertTrue(projection!.willExhaustBeforeReset)
    }

    func testProjectionNotUrgentWhenResetComesFirst() {
        // Same 2h-to-limit pace, but the window resets in 30 minutes.
        let projection = burnProjection(samples: samples([(0, 40), (30, 50), (60, 60)]),
                                        currentPercent: 60,
                                        resetsAt: start.addingTimeInterval(60 * 60 + 30 * 60),
                                        now: start.addingTimeInterval(60 * 60))
        XCTAssertEqual(projection?.willExhaustBeforeReset, false)
    }

    func testNoProjectionWhenFlat() {
        let projection = burnProjection(samples: samples([(0, 50), (30, 50), (60, 50)]),
                                        currentPercent: 50,
                                        resetsAt: start.addingTimeInterval(3600),
                                        now: start.addingTimeInterval(3600))
        XCTAssertNil(projection)
    }

    func testNoProjectionWhenAlreadyFull() {
        let projection = burnProjection(samples: samples([(0, 90), (30, 95), (60, 100)]),
                                        currentPercent: 100,
                                        resetsAt: start.addingTimeInterval(3600),
                                        now: start.addingTimeInterval(3600))
        XCTAssertNil(projection)
    }

    func testBurnTextFormatting() {
        XCTAssertEqual(burnText(BurnProjection(ratePerHour: 1, timeToLimit: 40 * 60, willExhaustBeforeReset: true)),
                       "~40m to limit")
        XCTAssertEqual(burnText(BurnProjection(ratePerHour: 1, timeToLimit: 3 * 3600 + 5 * 60, willExhaustBeforeReset: true)),
                       "~3h 5m to limit")
        XCTAssertEqual(burnText(BurnProjection(ratePerHour: 1, timeToLimit: 26 * 3600, willExhaustBeforeReset: false)),
                       "~1d 2h to limit")
    }
}
