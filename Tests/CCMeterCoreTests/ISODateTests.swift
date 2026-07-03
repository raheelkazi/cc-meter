import XCTest
@testable import CCMeterCore

final class ISODateTests: XCTestCase {
    func testParsesSixDigitFractionalWithOffset() {
        let d = ISODate.parse("2026-07-03T21:09:59.903723+00:00")
        XCTAssertNotNil(d)
        // 2026-07-03T21:09:59.903723+00:00 as epoch seconds (sanity anchor,
        // captured via ISODate.parse(...)!.timeIntervalSince1970).
        XCTAssertEqual(d!.timeIntervalSince1970, 1783112999.903, accuracy: 1.0)
    }

    func testParsesPlainInternetDateTime() {
        XCTAssertNotNil(ISODate.parse("2026-07-05T13:59:59+00:00"))
    }

    func testReturnsNilForGarbage() {
        XCTAssertNil(ISODate.parse("not-a-date"))
    }
}
