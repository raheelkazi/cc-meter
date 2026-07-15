import XCTest
@testable import CCMeterCore

final class ProviderStatusTests: XCTestCase {
    func testLevelOrdersAndColors() {
        XCTAssertTrue(StatusLevel.ok < .degraded)
        XCTAssertTrue(StatusLevel.degraded < .major)
        XCTAssertNil(StatusLevel.ok.color)
        XCTAssertEqual(StatusLevel.degraded.color, .amber)
        XCTAssertEqual(StatusLevel.major.color, .red)
    }

    func testProviderStatusStoresFields() {
        let s = ProviderStatus(provider: .claude, level: .major, headline: "API outage",
                               detail: "Elevated errors", url: URL(string: "https://status.claude.com"))
        XCTAssertEqual(s.level, .major)
        XCTAssertEqual(s.headline, "API outage")
    }
}
