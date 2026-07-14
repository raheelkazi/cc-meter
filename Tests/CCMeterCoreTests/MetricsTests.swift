import XCTest
@testable import CCMeterCore

final class MetricsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func testGreenWhenEmpty() {
        // 0% used -> plenty left -> green (the bug reported in issue #1 showed red here).
        XCTAssertEqual(usageColor(percent: 0), .green)
    }

    func testGreenWhenBarelyUsed() {
        XCTAssertEqual(usageColor(percent: 2), .green)
    }

    func testGreenJustBelowAmber() {
        XCTAssertEqual(usageColor(percent: 49), .green)
    }

    func testAmberAtThreshold() {
        XCTAssertEqual(usageColor(percent: 50), .amber)
    }

    func testAmberInMidRange() {
        XCTAssertEqual(usageColor(percent: 75), .amber)
    }

    func testAmberJustBelowRed() {
        XCTAssertEqual(usageColor(percent: 89), .amber)
    }

    func testRedAtThreshold() {
        XCTAssertEqual(usageColor(percent: 90), .red)
    }

    func testRedWhenNearlyExhausted() {
        XCTAssertEqual(usageColor(percent: 99), .red)
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

    func testCustomThresholds() {
        // Callers can tune the seams; verify both boundaries honor `>=`.
        XCTAssertEqual(usageColor(percent: 60, amberThreshold: 60, redThreshold: 80), .amber)
        XCTAssertEqual(usageColor(percent: 79, amberThreshold: 60, redThreshold: 80), .amber)
        XCTAssertEqual(usageColor(percent: 80, amberThreshold: 60, redThreshold: 80), .red)
    }

    func testMonotonicallyHotterAsUsageClimbs() {
        // Color rank never decreases as usage rises: the core fix for issue #1.
        func rank(_ c: MeterColor) -> Int {
            switch c { case .green: return 0; case .amber: return 1; case .red: return 2 }
        }
        var previous = rank(usageColor(percent: 0))
        for p in stride(from: 0, through: 100, by: 1) {
            let r = rank(usageColor(percent: Double(p)))
            XCTAssertGreaterThanOrEqual(r, previous, "color went cooler at \(p)%")
            previous = r
        }
    }

    func testCountdownAtExactlyZeroSeconds() {
        XCTAssertEqual(countdownText(to: now, now: now), "resetting")
    }

    // The flat popover shows the reset as a right-aligned column ("5d 17h"), so the bare
    // value is derived once here and the "resets in ..." sentence is built from it.
    func testCountdownValueDropsThePrefixAndTextIsBuiltFromIt() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cases: [(TimeInterval, String)] = [
            (3600 * 24 * 5 + 3600 * 17, "5d 17h"),
            (3600 * 2 + 60 * 5, "2h 5m"),
            (60 * 38, "38m")
        ]
        for (offset, expected) in cases {
            let resetsAt = now.addingTimeInterval(offset)
            XCTAssertEqual(countdownValue(to: resetsAt, now: now), expected)
            XCTAssertEqual(countdownText(to: resetsAt, now: now), "resets in \(expected)")
        }
    }

    func testCountdownValueReadsNowOncePassed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(countdownValue(to: now.addingTimeInterval(-5), now: now), "now")
        XCTAssertEqual(countdownText(to: now.addingTimeInterval(-5), now: now), "resetting")
    }


    // Shared by the popover's "updated ..." cue and Settings' "checked ..." cue. The phrasing
    // lived inside lastUpdatedText with the word "updated" baked in, so it could not be reused.
    func testRelativeTimeTextPhrasing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cases: [(TimeInterval, String)] = [
            (-3, "just now"),
            (-42, "42s ago"),
            (-60 * 9, "9m ago"),
            (-3600 * 3, "3h ago")
        ]
        for (offset, expected) in cases {
            XCTAssertEqual(relativeTimeText(since: now.addingTimeInterval(offset), now: now),
                           expected)
        }
    }

    func testUpdateStatusSummariesAreHumanReadable() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let checked = now.addingTimeInterval(-3600 * 2)

        XCTAssertEqual(UpdateStatus.idle.summary(now: now), "Not checked yet")
        XCTAssertEqual(UpdateStatus.checking.summary(now: now), "Checking…")
        XCTAssertEqual(UpdateStatus.upToDate(at: checked).summary(now: now),
                       "Up to date · checked 2h ago")
        XCTAssertEqual(UpdateStatus.unsupported.summary(now: now),
                       "Only available for Homebrew service installations")
    }

    func testFailedUpdateSummaryNamesTheStageAndPointsAtTheLog() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let status = UpdateStatus.failed(UpdateFailure(stage: .upgrade, detail: "boom"),
                                         at: now.addingTimeInterval(-60))

        let summary = status.summary(now: now)

        XCTAssertTrue(summary.contains("upgrade"), summary)
        XCTAssertTrue(summary.contains("1m ago"), summary)
        XCTAssertTrue(summary.contains("update.log"), summary)
    }

}
