import XCTest
@testable import CCMeterCore

final class UsageBreakdownTests: XCTestCase {
    private let windowStart = Date(timeIntervalSince1970: 1_000_000)
    private var now: Date { windowStart.addingTimeInterval(5 * 3600) }

    private func event(_ project: String, _ model: String, input: Int, at: Date) -> UsageEvent {
        UsageEvent(provider: .claude, at: at, project: project, model: model,
                   tokens: TokenCounts(input: input), dedupKey: "\(project)-\(model)-\(at.timeIntervalSince1970)")
    }

    func testRollsUpProjectsAndModelsSortedByTokens() {
        let events = [
            event("cc-meter", "claude-opus-4-8", input: 300, at: windowStart.addingTimeInterval(60)),
            event("web", "claude-opus-4-8", input: 100, at: windowStart.addingTimeInterval(120)),
            event("cc-meter", "claude-sonnet", input: 100, at: windowStart.addingTimeInterval(180)),
        ]
        let b = UsageBreakdownBuilder.build(events: events, provider: .claude, window: .fiveHour,
                                            windowStart: windowStart, now: now)
        XCTAssertEqual(b.totalTokens, 500)
        XCTAssertEqual(b.projects.map(\.project), ["cc-meter", "web"])
        XCTAssertEqual(b.projects.map(\.tokens), [400, 100])
        XCTAssertEqual(b.projects[0].share, 0.8, accuracy: 0.0001)
        XCTAssertEqual(b.models.map(\.model), ["claude-opus-4-8", "claude-sonnet"])
        XCTAssertEqual(b.models.map(\.tokens), [400, 100])
    }

    func testExcludesEventsBeforeWindowStartAndOtherProviders() {
        let events = [
            event("cc-meter", "claude-opus-4-8", input: 50, at: windowStart.addingTimeInterval(-10)), // too old
            event("cc-meter", "claude-opus-4-8", input: 70, at: windowStart.addingTimeInterval(60)),
            UsageEvent(provider: .codex, at: windowStart.addingTimeInterval(60), project: "cc-meter",
                       model: "gpt-5.6-sol", tokens: TokenCounts(input: 999), dedupKey: "cx"),
        ]
        let b = UsageBreakdownBuilder.build(events: events, provider: .claude, window: .fiveHour,
                                            windowStart: windowStart, now: now)
        XCTAssertEqual(b.totalTokens, 70)
    }

    func testBucketsSpanTheWindow() {
        let events = [
            event("p", "claude-opus-4-8", input: 10, at: windowStart.addingTimeInterval(30)),        // bucket 0
            event("p", "claude-opus-4-8", input: 20, at: windowStart.addingTimeInterval(2*3600 + 5)), // bucket 2
        ]
        let b = UsageBreakdownBuilder.build(events: events, provider: .claude, window: .fiveHour,
                                            windowStart: windowStart, now: now)
        XCTAssertEqual(b.buckets.count, 5)
        XCTAssertEqual(b.buckets.map(\.tokens), [10, 0, 20, 0, 0])
    }

    func testNotionalCostNilWhenNoModelPriced() {
        let events = [UsageEvent(provider: .codex, at: windowStart.addingTimeInterval(60), project: "p",
                                 model: "gpt-5.6-sol", tokens: TokenCounts(input: 100), dedupKey: "x")]
        let b = UsageBreakdownBuilder.build(events: events, provider: .codex, window: .fiveHour,
                                            windowStart: windowStart, now: now)
        XCTAssertNil(b.notionalCost)
        XCTAssertFalse(b.costIsPartial)
    }

    func testCostIsPartialWhenSomeModelsPricedAndSomeNot() {
        let events = [
            event("p", "claude-opus-4-8", input: 100, at: windowStart.addingTimeInterval(60)),
            UsageEvent(provider: .claude, at: windowStart.addingTimeInterval(120), project: "p",
                       model: "future-unpriced-model", tokens: TokenCounts(input: 50), dedupKey: "u"),
        ]
        let b = UsageBreakdownBuilder.build(events: events, provider: .claude, window: .fiveHour,
                                            windowStart: windowStart, now: now)
        // The priced portion (opus) is shown and flagged partial, not blanked to n/a by the 33% unpriced.
        XCTAssertNotNil(b.notionalCost)
        XCTAssertEqual(b.notionalCost!, 100 * 15.0 / 1_000_000, accuracy: 1e-9)
        XCTAssertTrue(b.costIsPartial)
    }

    func testCostNotPartialWhenAllModelsPriced() {
        let events = [event("p", "claude-opus-4-8", input: 100, at: windowStart.addingTimeInterval(60))]
        let b = UsageBreakdownBuilder.build(events: events, provider: .claude, window: .fiveHour,
                                            windowStart: windowStart, now: now)
        XCTAssertNotNil(b.notionalCost)
        XCTAssertFalse(b.costIsPartial)
    }
}
