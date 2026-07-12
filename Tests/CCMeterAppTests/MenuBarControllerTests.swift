import AppKit
import XCTest
@testable import CCMeterCore
@testable import cc_meter

@MainActor
final class MenuBarControllerTests: XCTestCase {
    func testTitleStringAppliesEachProviderColor() {
        let presentation = MenuBarPresentation.make(summaries: [
            ProviderCompactSummary(provider: .claude, percent: 62, color: .amber),
            ProviderCompactSummary(provider: .codex, percent: 18, color: .green)
        ], isLoading: false, hasError: false)

        let title = MenuBarController.titleString(for: presentation)
        let string = title.string as NSString
        let firstDot = string.range(of: "●")
        let secondSearch = NSRange(location: NSMaxRange(firstDot),
                                   length: string.length - NSMaxRange(firstDot))
        let secondDot = string.range(of: "●", range: secondSearch)

        XCTAssertEqual(title.string, "Cl ● 62% · Cx ● 18%")
        XCTAssertEqual(title.attribute(.foregroundColor, at: firstDot.location,
                                       effectiveRange: nil) as? NSColor,
                       NSColor.systemOrange)
        XCTAssertEqual(title.attribute(.foregroundColor, at: secondDot.location,
                                       effectiveRange: nil) as? NSColor,
                       NSColor.systemGreen)
    }
}
