import XCTest
@testable import CCMeterCore

final class ProviderTests: XCTestCase {
    func testProviderDisplayNamesAreStable() {
        XCTAssertEqual(UsageProvider.claude.displayName, "Claude Code")
        XCTAssertEqual(UsageProvider.codex.displayName, "Codex")
    }

    func testNamedWindowPreservesLabelAndSessionMeaning() {
        let kind = WindowKind.named(label: "5-hour", isSession: true)
        XCTAssertEqual(kind.label, "5-hour")
        XCTAssertTrue(kind.isSessionWindow)
        XCTAssertFalse(WindowKind.weeklyAll.isSessionWindow)
    }
}
