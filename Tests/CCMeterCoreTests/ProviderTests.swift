import XCTest
@testable import CCMeterCore

final class ProviderTests: XCTestCase {
    func testProviderDisplayNamesAreStable() {
        XCTAssertEqual(UsageProvider.claude.displayName, "Claude Code")
        XCTAssertEqual(UsageProvider.codex.displayName, "Codex")
    }

    func testNamedWindowPreservesLabelAndSessionMeaning() {
        let kind = WindowKind.named(id: "codex:default:primary",
                                    label: "5-hour", isSession: true)
        XCTAssertEqual(kind.label, "5-hour")
        XCTAssertEqual(kind.identity, "codex:default:primary")
        XCTAssertTrue(kind.isSessionWindow)
        XCTAssertFalse(WindowKind.weeklyAll.isSessionWindow)
    }
}
