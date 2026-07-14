import XCTest
@testable import CCMeterCore

final class NotificationsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func sessionUsage(_ percent: Double, resetsIn: TimeInterval = 3600) -> Usage {
        Usage(limits: [UsageLimit(kind: .session, percent: percent,
                                  resetsAt: now.addingTimeInterval(resetsIn), isActive: true)],
              fetchedAt: now)
    }

    private func prefs(thresholds: [Double] = [80, 95, 100],
                       enabled: Bool = true,
                       headsUp: Int? = nil) -> Preferences {
        Preferences(notificationsEnabled: enabled,
                    notificationThresholds: thresholds,
                    sessionResetHeadsUpMinutes: headsUp)
    }

    func testFirstObservationDoesNotFireRetroactively() {
        let n = ThresholdNotifier()
        // Launch already at 85%: no retroactive spam for the 80% seam.
        XCTAssertTrue(n.evaluate(sessionUsage(85), preferences: prefs(), now: now).isEmpty)
    }

    func testFiresOnceWhenCrossingUpward() {
        let n = ThresholdNotifier()
        _ = n.evaluate(sessionUsage(50), preferences: prefs(), now: now)   // baseline
        let events = n.evaluate(sessionUsage(82), preferences: prefs(), now: now)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].id.contains("80"))
        // Staying above the seam does not re-fire.
        XCTAssertTrue(n.evaluate(sessionUsage(85), preferences: prefs(), now: now).isEmpty)
    }

    func testCrossingMultipleThresholdsInOneStep() {
        let n = ThresholdNotifier()
        _ = n.evaluate(sessionUsage(10), preferences: prefs(), now: now)
        let events = n.evaluate(sessionUsage(100), preferences: prefs(), now: now)
        XCTAssertEqual(events.count, 3)   // 80, 95, 100 all crossed at once
    }

    func testReArmsAfterWindowReset() {
        let n = ThresholdNotifier()
        _ = n.evaluate(sessionUsage(50), preferences: prefs(), now: now)
        XCTAssertEqual(n.evaluate(sessionUsage(82), preferences: prefs(), now: now).count, 1)
        // New window: different resetsAt, usage drops to ~0, then climbs again.
        _ = n.evaluate(sessionUsage(2, resetsIn: 7200), preferences: prefs(), now: now)
        let reArmed = n.evaluate(sessionUsage(85, resetsIn: 7200), preferences: prefs(), now: now)
        XCTAssertEqual(reArmed.count, 1)
    }

    func testDisabledSuppressesButStillTracks() {
        let n = ThresholdNotifier()
        _ = n.evaluate(sessionUsage(50), preferences: prefs(enabled: false), now: now)
        // Disabled: no events even though 80 was crossed...
        XCTAssertTrue(n.evaluate(sessionUsage(82), preferences: prefs(enabled: false), now: now).isEmpty)
        // ...and re-enabling does not replay the already-passed crossing.
        XCTAssertTrue(n.evaluate(sessionUsage(85), preferences: prefs(enabled: true), now: now).isEmpty)
    }

    func testHeadsUpFiresOnceOnTransitionIntoWindow() {
        let n = ThresholdNotifier()
        let p = prefs(thresholds: [], headsUp: 10)
        // Same window throughout (fixed reset); `now` advances toward it. First
        // seen far from reset, later crosses into the 10-minute range -> fires once.
        let reset = now.addingTimeInterval(3600)
        func usage(_ percent: Double) -> Usage {
            Usage(limits: [UsageLimit(kind: .session, percent: percent, resetsAt: reset, isActive: true)],
                  fetchedAt: now)
        }
        _ = n.evaluate(usage(30), preferences: p, now: now)                                  // 1h left
        let events = n.evaluate(usage(31), preferences: p, now: reset.addingTimeInterval(-300))  // 5m left
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].id.contains("reset-headsup"))
        // Does not re-fire for the same window.
        XCTAssertTrue(n.evaluate(usage(32), preferences: p, now: reset.addingTimeInterval(-240)).isEmpty)
    }

    func testHeadsUpSuppressedWhenFirstSeenInsideWindow() {
        // Simulates relaunching cc-meter while already inside the heads-up range:
        // the user was alerted before the restart, so don't replay it.
        let n = ThresholdNotifier()
        let p = prefs(thresholds: [], headsUp: 10)
        XCTAssertTrue(n.evaluate(sessionUsage(30, resetsIn: 300), preferences: p, now: now).isEmpty)
    }

    func testHeadsUpDoesNotFireWhenFarFromReset() {
        let n = ThresholdNotifier()
        let p = prefs(thresholds: [], headsUp: 10)
        XCTAssertTrue(n.evaluate(sessionUsage(30, resetsIn: 3600), preferences: p, now: now).isEmpty)
    }

    func testCodexNotificationIdentityAndCopyAreProviderQualified() {
        let n = ThresholdNotifier()
        _ = n.evaluate(sessionUsage(50), provider: .codex, preferences: prefs(), now: now)
        let event = n.evaluate(sessionUsage(82), provider: .codex, preferences: prefs(), now: now).first

        XCTAssertTrue(event?.id.hasPrefix("codex#") ?? false)
        XCTAssertTrue(event?.title.contains("Codex") ?? false)
        XCTAssertTrue(event?.body.contains("Codex") ?? false)
    }

    // MARK: - resets_at jitter
    //
    // The endpoint's resets_at jitters sub-second between polls. MeterViewModel already
    // tolerates that; ThresholdNotifier compared Dates exactly, so every poll looked like a
    // brand-new window, re-baselined lastPercent, and made `previous < threshold` unsatisfiable.
    // Net effect: no notification could ever fire, for anyone.

    private func jitteringUsage(_ percent: Double,
                                resetsAt: Date,
                                jitter: TimeInterval,
                                kind: WindowKind = .session,
                                fetchedAt: Date) -> Usage {
        Usage(limits: [UsageLimit(kind: kind,
                                  percent: percent,
                                  resetsAt: resetsAt.addingTimeInterval(jitter),
                                  isActive: true)],
              fetchedAt: fetchedAt)
    }

    func testThresholdFiresWhenResetsAtJittersSubSecondWithinTheSameWindow() {
        let notifier = ThresholdNotifier()
        let prefs = Preferences(notificationThresholds: [80])
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(3600)

        _ = notifier.evaluate(jitteringUsage(70, resetsAt: reset, jitter: 0, fetchedAt: now),
                              preferences: prefs, now: now)
        let events = notifier.evaluate(
            jitteringUsage(85, resetsAt: reset, jitter: 0.0003, fetchedAt: now),
            preferences: prefs, now: now
        )

        XCTAssertEqual(events.count, 1, "crossing 80% must notify; 0.3ms of jitter is not a new window")
    }

    /// The second-order trap: the heads-up dedupe key embedded the *jittering* resetsAt, so
    /// simply tolerating jitter in isNewWindow would flip this from never-firing to firing on
    /// every single poll.
    func testHeadsUpFiresOnceAcrossManyJitteringPolls() {
        let notifier = ThresholdNotifier()
        let prefs = Preferences(notificationThresholds: [], sessionResetHeadsUpMinutes: 10)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let reset = start.addingTimeInterval(3600)

        // Poll well outside the heads-up range, so the window is established without suppressing.
        _ = notifier.evaluate(jitteringUsage(10, resetsAt: reset, jitter: 0, fetchedAt: start),
                              preferences: prefs, now: start)

        // Now poll repeatedly *inside* the 10-minute range. Every poll carries fresh jitter —
        // none of them matches the established date exactly, so this genuinely exercises the
        // jitter path rather than passing on a lucky bit-identical Date.
        var fired = 0
        for i in 0..<5 {
            let now = reset.addingTimeInterval(-300 + Double(i))
            let events = notifier.evaluate(
                jitteringUsage(10, resetsAt: reset, jitter: Double(i + 1) * 0.0004, fetchedAt: now),
                preferences: prefs, now: now
            )
            fired += events.count
        }

        XCTAssertEqual(fired, 1, "the heads-up must fire exactly once, not once per poll")
    }

    /// The tolerance must not swallow a genuine reset: a real window moves by hours.
    func testRealWindowResetStillReArmsThresholds() {
        let notifier = ThresholdNotifier()
        let prefs = Preferences(notificationThresholds: [80])
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(3600)

        _ = notifier.evaluate(jitteringUsage(70, resetsAt: reset, jitter: 0, fetchedAt: now),
                              preferences: prefs, now: now)
        _ = notifier.evaluate(jitteringUsage(85, resetsAt: reset, jitter: 0, fetchedAt: now),
                              preferences: prefs, now: now)

        // A real reset: the window jumps forward by hours, usage drops, then climbs again.
        let newReset = reset.addingTimeInterval(5 * 3600)
        _ = notifier.evaluate(jitteringUsage(5, resetsAt: newReset, jitter: 0, fetchedAt: now),
                              preferences: prefs, now: now)
        let events = notifier.evaluate(
            jitteringUsage(85, resetsAt: newReset, jitter: 0, fetchedAt: now),
            preferences: prefs, now: now
        )

        XCTAssertEqual(events.count, 1, "a genuine reset must re-arm the threshold")
    }

}
