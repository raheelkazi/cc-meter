import XCTest
@testable import CCMeterCore

final class PreferencesTests: XCTestCase {
    func testDefaults() {
        let p = Preferences()
        XCTAssertEqual(p.pollInterval, 180)
        XCTAssertTrue(p.notificationsEnabled)
        XCTAssertEqual(p.notificationThresholds, [80, 95, 100])
        XCTAssertEqual(p.sessionResetHeadsUpMinutes, 10)
        XCTAssertFalse(p.defaultShowRemaining)
        XCTAssertTrue(p.historyEnabled)
        XCTAssertFalse(p.launchAtLogin)
    }

    func testAutomaticUpdatesDefaultToEnabled() {
        XCTAssertTrue(Preferences().automaticUpdatesEnabled)
    }

    func testLegacyPreferencesEnableAutomaticUpdates() throws {
        let data = #"{"pollInterval":180,"notificationsEnabled":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertTrue(decoded.automaticUpdatesEnabled)
    }

    func testAutomaticUpdatesRoundTrip() throws {
        let original = Preferences(automaticUpdatesEnabled: false)
        let decoded = try JSONDecoder().decode(
            Preferences.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertFalse(decoded.automaticUpdatesEnabled)
    }

    func testNormalizeClampsInterval() {
        var p = Preferences()
        p.pollInterval = 1
        XCTAssertEqual(p.normalized().pollInterval, Preferences.minPollInterval)
    }

    func testNormalizeSortsAndDedupesThresholds() {
        var p = Preferences()
        p.notificationThresholds = [95, 80, 80, 150, -10]
        // 150 clamps to 100, -10 clamps to 0, duplicates removed, sorted ascending.
        XCTAssertEqual(p.normalized().notificationThresholds, [0, 80, 95, 100])
    }

    func testLenientDecodeFillsMissingFieldsWithDefaults() throws {
        // An older stored blob missing newer keys must not wipe them.
        let json = #"{"pollInterval":30}"#.data(using: .utf8)!
        let p = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertEqual(p.pollInterval, 30)
        XCTAssertEqual(p.notificationThresholds, [80, 95, 100]) // default preserved
        XCTAssertTrue(p.notificationsEnabled)
    }

    func testUserDefaultsRoundTrip() {
        let defaults = UserDefaults(suiteName: "cc-meter.tests.\(UUID().uuidString)")!
        let store = UserDefaultsPreferencesStore(defaults: defaults, key: "k")
        var p = Preferences()
        p.pollInterval = 45
        p.defaultShowRemaining = true
        store.save(p)
        let loaded = store.load()
        XCTAssertEqual(loaded.pollInterval, 45)
        XCTAssertTrue(loaded.defaultShowRemaining)
    }

    func testMissingStoreLoadsDefaults() {
        let defaults = UserDefaults(suiteName: "cc-meter.tests.\(UUID().uuidString)")!
        let store = UserDefaultsPreferencesStore(defaults: defaults, key: "absent")
        XCTAssertEqual(store.load(), Preferences())
    }

    func testUsageBreakdownEnabledDefaultsTrue() {
        XCTAssertTrue(Preferences().usageBreakdownEnabled)
    }

    func testUsageBreakdownEnabledAbsentDecodesToDefault() throws {
        let json = "{\"pollInterval\":180}".data(using: .utf8)!
        let prefs = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertTrue(prefs.usageBreakdownEnabled)
    }

    func testUsageBreakdownEnabledRoundTrips() throws {
        var prefs = Preferences()
        prefs.usageBreakdownEnabled = false
        let data = try JSONEncoder().encode(prefs)
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: data).usageBreakdownEnabled)
    }
}
