import XCTest
@testable import CCMeterCore

final class LaunchAgentTests: XCTestCase {
    func testPlistEmbedsLabelAndProgramPath() {
        let plist = LaunchAgent.plist(label: "com.example.app", programPath: "/opt/bin/cc-meter")
        XCTAssertTrue(plist.contains("<string>com.example.app</string>"))
        XCTAssertTrue(plist.contains("<string>/opt/bin/cc-meter</string>"))
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"))
    }

    func testPlistURLIsUnderLaunchAgents() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let url = LaunchAgent.plistURL(home: home, label: "com.example.app")
        XCTAssertEqual(url.path, "/Users/tester/Library/LaunchAgents/com.example.app.plist")
    }
}
