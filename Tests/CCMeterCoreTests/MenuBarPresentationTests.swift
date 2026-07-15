import XCTest
@testable import CCMeterCore

final class MenuBarPresentationTests: XCTestCase {
    func testDualProviderPresentationUsesLabelsOrderColorsAndTooltip() {
        let presentation = MenuBarPresentation.make(summaries: [
            ProviderCompactSummary(provider: .claude, percent: 62, color: .amber),
            ProviderCompactSummary(provider: .codex, percent: 18, color: .green)
        ], isLoading: false, hasError: false)

        XCTAssertEqual(presentation.segments, [
            MenuBarTitleSegment(text: "Cl "),
            MenuBarTitleSegment(text: "●", color: .amber),
            MenuBarTitleSegment(text: " 62%"),
            MenuBarTitleSegment(text: " · "),
            MenuBarTitleSegment(text: "Cx "),
            MenuBarTitleSegment(text: "●", color: .green),
            MenuBarTitleSegment(text: " 18%")
        ])
        XCTAssertEqual(presentation.plainTitle, "Cl ● 62% · Cx ● 18%")
        XCTAssertEqual(presentation.tooltip,
                       "Claude Code 62% used · Codex 18% used")
    }

    func testSingleProviderPresentationKeepsCurrentCompactTitle() {
        for summary in [
            ProviderCompactSummary(provider: .claude, percent: 62, color: .amber),
            ProviderCompactSummary(provider: .codex, percent: 18, color: .green)
        ] {
            let presentation = MenuBarPresentation.make(summaries: [summary],
                                                        isLoading: false,
                                                        hasError: false)
            XCTAssertEqual(presentation.segments, [
                MenuBarTitleSegment(text: "● ", color: summary.color),
                MenuBarTitleSegment(text: "\(summary.percent)%")
            ])
            XCTAssertEqual(presentation.tooltip,
                           "\(summary.provider.displayName) \(summary.percent)% used")
        }
    }

    func testEmptyPresentationPreservesLoadingErrorAndIdleFallbacks() {
        XCTAssertEqual(MenuBarPresentation.make(summaries: [], isLoading: true,
                                                hasError: true).plainTitle, "CC ...")
        XCTAssertEqual(MenuBarPresentation.make(summaries: [], isLoading: false,
                                                hasError: true).plainTitle, "CC !")
        XCTAssertEqual(MenuBarPresentation.make(summaries: [], isLoading: false,
                                                hasError: false).plainTitle, "CC")
    }

    func testDegradedProviderShowsWarningGlyph() {
        let summaries = [ProviderCompactSummary(provider: .claude, percent: 42, color: .green),
                         ProviderCompactSummary(provider: .codex, percent: 30, color: .green)]
        let p = MenuBarPresentation.make(summaries: summaries, isLoading: false, hasError: false,
                                         statuses: [.claude: .major])
        XCTAssertTrue(p.segments.contains { $0.text == "⚠" && $0.color == .red },
                      "a degraded provider shows a colored warning glyph")
        XCTAssertFalse(p.plainTitle.contains("●⚠"))
        XCTAssertTrue(p.plainTitle.contains("42%"))
    }

    func testNoStatusesKeepsDots() {
        let summaries = [ProviderCompactSummary(provider: .claude, percent: 42, color: .green)]
        let p = MenuBarPresentation.make(summaries: summaries, isLoading: false, hasError: false)
        XCTAssertTrue(p.segments.contains { $0.text.contains("●") })
        XCTAssertFalse(p.segments.contains { $0.text == "⚠" })
    }
}
