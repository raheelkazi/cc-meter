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

    // MARK: - Threshold boundary pinning

    func testRemainingExactlyTenIsNotForcedRed() {
        // percent 90 -> remaining 10 -> rule 1's `< 10` is false, falls through to pace.
        // elapsed 1.0 -> greenThresh 1.0 * 1.0 = 1.0; used 0.9 <= 1.0 -> green.
        let c = burnRateColor(percent: 90, resetsAt: resets(afterFractionElapsed: 1.0, window: week),
                              windowLength: week, now: now)
        XCTAssertEqual(c, .green)
    }

    func testUsedExactlyFivePercentIsNotForcedGreen() {
        // percent 5 -> used 0.05 -> rule 2's `< 0.05` is false, falls through to pace.
        // elapsed 0.01 -> greenThresh 0.01, amberThresh 0.015; used 0.05 exceeds both -> red.
        let c = burnRateColor(percent: 5, resetsAt: resets(afterFractionElapsed: 0.01, window: week),
                              windowLength: week, now: now)
        XCTAssertEqual(c, .red)
    }

    func testGreenAmberSeamEqualityIsGreen() {
        // used 0.5, elapsed 0.5 -> used == elapsed * greenFactor(1.0) exactly -> rule 4's `<=` -> green.
        let c = burnRateColor(percent: 50, resetsAt: resets(afterFractionElapsed: 0.5, window: week),
                              windowLength: week, now: now)
        XCTAssertEqual(c, .green)
    }

    func testAmberRedSeamEqualityIsAmber() {
        // used 0.75, elapsed 0.5 -> used == elapsed * amberFactor(1.5) exactly -> rule 5's `<=` -> amber.
        let c = burnRateColor(percent: 75, resetsAt: resets(afterFractionElapsed: 0.5, window: week),
                              windowLength: week, now: now)
        XCTAssertEqual(c, .amber)
    }

    func testElapsedClampHighWhenResetIsInThePast() {
        // resetsAt one full window in the past -> raw elapsed 2.0, clamped to 1.0.
        // With greenFactor 0.5 / amberFactor 0.6: clamped(elapsed=1) gives green<=0.5,
        // amber<=0.6, so used 0.7 -> red. Without the clamp (elapsed=2) it would be
        // green<=1.0 -> green, so this case only passes when the clamp is applied.
        let c = burnRateColor(percent: 70, resetsAt: now.addingTimeInterval(-week),
                              windowLength: week, now: now, greenFactor: 0.5, amberFactor: 0.6)
        XCTAssertEqual(c, .red)
    }

    func testElapsedClampLowWhenResetIsBeyondAFullWindow() {
        // resetsAt two full windows in the future -> raw elapsed -1.0, clamped to 0.001.
        // With amberFactor 1000: clamped(elapsed=0.001) gives amber<=1.0, so used 0.5 ->
        // amber. Without the clamp (elapsed=-1) amber<=-1000 -> red, so this case only
        // passes when the clamp is applied.
        let c = burnRateColor(percent: 50, resetsAt: now.addingTimeInterval(2 * week),
                              windowLength: week, now: now, amberFactor: 1000)
        XCTAssertEqual(c, .amber)
    }

    func testCountdownAtExactlyZeroSeconds() {
        XCTAssertEqual(countdownText(to: now, now: now), "resetting")
    }
}
