import XCTest
@testable import CCMeterCore

/// Labels for the side-by-side popover cells.
///
/// Pairing limits on one line only works if a cell is narrow, and the full labels
/// ("7-day · GPT-5.3-Codex-Spark") are far too wide. The `GPT-5.x` stem repeats on every
/// limit and identifies nothing; the last token is the part that does the work.
final class CompactLabelTests: XCTestCase {
    func testModelTokenKeepsOnlyTheDistinguishingSuffix() {
        XCTAssertEqual(shortModelToken("GPT-5.6-Sol"), "Sol")
        XCTAssertEqual(shortModelToken("GPT-5.3-Codex-Spark"), "Spark")
        XCTAssertEqual(shortModelToken("Fable"), "Fable")
    }

    func testModelFamilyLabelCollapsesClaudeNamesToTheFamily() {
        XCTAssertEqual(modelFamilyLabel("claude-opus-4-8"), "opus")
        XCTAssertEqual(modelFamilyLabel("claude-sonnet-5"), "sonnet")
        XCTAssertEqual(modelFamilyLabel("claude-fable-5"), "fable")
        XCTAssertEqual(modelFamilyLabel("claude-haiku-4-5"), "haiku")
        // Non-Claude names keep their meaningful trailing token.
        XCTAssertEqual(modelFamilyLabel("gpt-5.6-sol"), "sol")
    }

    func testWindowTokenAbbreviatesHoursAndDays() {
        XCTAssertEqual(compactWindowToken("5-hour"), "5h")
        XCTAssertEqual(compactWindowToken("7-day"), "7d")
        XCTAssertEqual(compactWindowToken("30-day"), "30d")
        XCTAssertEqual(compactWindowToken("something else"), "something else")
    }

    func testCompactLabelsForEachWindowKind() {
        XCTAssertEqual(WindowKind.session.compactLabel, "5h")
        XCTAssertEqual(WindowKind.weeklyAll.compactLabel, "7d")
        XCTAssertEqual(WindowKind.weeklyScoped(model: "Fable").compactLabel, "7d·Fable")
    }

    /// The window is never dropped. Codex reports the same model in more than one window,
    /// so a bare "Sol" would render two cells that look identical.
    func testCompactLabelKeepsTheWindowSoTheSameModelStaysDistinguishable() {
        let fiveHour = WindowKind.named(id: "a", label: "5-hour · GPT-5.6-Sol", isSession: true)
        let sevenDay = WindowKind.named(id: "b", label: "7-day · GPT-5.6-Sol", isSession: false)

        XCTAssertEqual(fiveHour.compactLabel, "5h·Sol")
        XCTAssertEqual(sevenDay.compactLabel, "7d·Sol")
        XCTAssertNotEqual(fiveHour.compactLabel, sevenDay.compactLabel)
    }

    func testUnscopedNamedWindowCompactsToJustTheWindow() {
        let kind = WindowKind.named(id: "a", label: "7-day", isSession: false)
        XCTAssertEqual(kind.compactLabel, "7d")
    }
}

@MainActor
final class CompactRowLabelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private final class StubClient: UsageFetching {
        let usage: Usage
        init(_ usage: Usage) { self.usage = usage }
        func fetch() async -> Result<Usage, UsageError> { .success(usage) }
    }

    private func rows(for kinds: [WindowKind]) async -> [MeterRow] {
        let limits = kinds.enumerated().map { index, kind in
            UsageLimit(kind: kind, percent: Double(index + 1),
                       resetsAt: now.addingTimeInterval(3600), isActive: true)
        }
        let vm = MeterViewModel(provider: .codex,
                                client: StubClient(Usage(limits: limits, fetchedAt: now)),
                                now: { self.now })
        await vm.refresh()
        return vm.rows
    }

    func testRowsCarryCompactLabels() async {
        let labels = await rows(for: [.session, .weeklyScoped(model: "GPT-5.6-Sol")])
            .map(\.compactLabel)
        XCTAssertEqual(labels, ["5h", "7d·Sol"])
    }

    /// Shortening is the one change here that can destroy information. If two limits would
    /// compact to the same cell, both fall back to their full labels rather than render two
    /// rows the user cannot tell apart.
    func testCollidingCompactLabelsFallBackToFullLabels() async {
        let colliding = await rows(for: [
            .named(id: "a", label: "7-day · Anthropic-Sol", isSession: false),
            .named(id: "b", label: "7-day · OpenAI-Sol", isSession: false)
        ])

        XCTAssertEqual(colliding.map(\.compactLabel),
                       ["7-day · Anthropic-Sol", "7-day · OpenAI-Sol"],
                       "both would compact to 7d·Sol, so neither may be shortened")
    }

    func testNonCollidingLabelsStayShortEvenWhenAnotherPairCollides() async {
        let mixed = await rows(for: [
            .session,
            .named(id: "a", label: "7-day · Anthropic-Sol", isSession: false),
            .named(id: "b", label: "7-day · OpenAI-Sol", isSession: false)
        ])

        XCTAssertEqual(mixed.map(\.compactLabel),
                       ["5h", "7-day · Anthropic-Sol", "7-day · OpenAI-Sol"],
                       "only the colliding pair gives up its short form")
    }
}
