import XCTest
@testable import CCMeterCore

final class MetricsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let week: TimeInterval = 7 * 24 * 3600

    private func resets(afterFractionElapsed f: Double, window: TimeInterval) -> Date {
        // elapsed fraction f means (1 - f) of the window remains.
        return now.addingTimeInterval(window * (1 - f))
    }

    func testRedWhenRemainingUnderTen() {
        let c = burnRateColor(percent: 95, resetsAt: resets(afterFractionElapsed: 0.99, window: week),
                              windowLength: week, now: now)
        XCTAssertEqual(c, .red)
    }

    func testGreenWhenBarelyUsed() {
        let c = burnRateColor(percent: 2, resetsAt: resets(afterFractionElapsed: 0.01, window: week),
                              windowLength: week, now: now)
        XCTAssertEqual(c, .green)
    }

    func testGreenWhenPaceSustainable() {
        // used 0.20 <= elapsed 0.50 -> green
        let c = burnRateColor(percent: 20, resetsAt: resets(afterFractionElapsed: 0.5, window: week),
                              windowLength: week, now: now)
        XCTAssertEqual(c, .green)
    }

    func testAmberWhenElevated() {
        // used 0.60, elapsed 0.50 -> > green (0.50) but <= amber (0.75) -> amber
        let c = burnRateColor(percent: 60, resetsAt: resets(afterFractionElapsed: 0.5, window: week),
                              windowLength: week, now: now)
        XCTAssertEqual(c, .amber)
    }

    func testRedWhenBurningFast() {
        // used 0.85, elapsed 0.20 -> > amber (0.30) -> red
        let c = burnRateColor(percent: 85, resetsAt: resets(afterFractionElapsed: 0.2, window: week),
                              windowLength: week, now: now)
        XCTAssertEqual(c, .red)
    }

    func testCountdownDaysHours() {
        let d = now.addingTimeInterval(2 * 86400 + 3 * 3600)
        XCTAssertEqual(countdownText(to: d, now: now), "resets in 2d 3h")
    }

    func testCountdownHoursMinutes() {
        let d = now.addingTimeInterval(3 * 3600 + 42 * 60)
        XCTAssertEqual(countdownText(to: d, now: now), "resets in 3h 42m")
    }

    func testCountdownMinutesOnly() {
        let d = now.addingTimeInterval(30 * 60)
        XCTAssertEqual(countdownText(to: d, now: now), "resets in 30m")
    }

    func testCountdownPast() {
        XCTAssertEqual(countdownText(to: now.addingTimeInterval(-10), now: now), "resetting")
    }
}
