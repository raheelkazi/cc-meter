import XCTest
@testable import CCMeterCore
@testable import cc_meter

@MainActor
final class AutoUpdateIntegrationTests: XCTestCase {
    func testStartAutomaticUpdatesPropagatesEnabledPreference() {
        let controller = AutomaticUpdateControllerStub()

        AppDelegate.startAutomaticUpdates(
            controller,
            preferences: Preferences(automaticUpdatesEnabled: true)
        )

        XCTAssertEqual(controller.startedValues, [true])
    }

    func testStartAutomaticUpdatesPropagatesDisabledPreference() {
        let controller = AutomaticUpdateControllerStub()

        AppDelegate.startAutomaticUpdates(
            controller,
            preferences: Preferences(automaticUpdatesEnabled: false)
        )

        XCTAssertEqual(controller.startedValues, [false])
    }
}

@MainActor
private final class AutomaticUpdateControllerStub: AutomaticUpdateControlling {
    private(set) var startedValues: [Bool] = []

    func start(enabled: Bool) {
        startedValues.append(enabled)
    }

    func apply(enabled: Bool) {}
}
