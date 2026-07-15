import Foundation

/// User-tunable settings. Persisted as a single value so adding a field is a
/// one-line change with a sensible default, and old stored blobs still decode.
public struct Preferences: Codable, Equatable {
    /// Seconds between automatic polls. Clamped to a sane floor on load.
    public var pollInterval: TimeInterval
    /// Whether the app posts local notifications when a limit crosses a threshold.
    public var notificationsEnabled: Bool
    /// Used-percent seams (ascending) that fire a notification when crossed upward.
    public var notificationThresholds: [Double]
    /// Minutes before a session/window reset to post a heads-up (nil = off).
    public var sessionResetHeadsUpMinutes: Int?
    /// Which value the popover/menu bar shows by default on launch.
    public var defaultShowRemaining: Bool
    /// Whether usage samples are recorded to disk for burn forecasts.
    public var historyEnabled: Bool
    /// Whether the app should relaunch at login (managed via a LaunchAgent).
    public var launchAtLogin: Bool
    /// Whether Homebrew service installations should update automatically.
    public var automaticUpdatesEnabled: Bool
    /// Whether the Usage tab parses local Claude/Codex logs for the token breakdown.
    public var usageBreakdownEnabled: Bool

    public static let minPollInterval: TimeInterval = 15

    /// 180s: the usage endpoint's rate budget is shared with Claude Code itself,
    /// so a tighter cadence trips 429s.
    public init(pollInterval: TimeInterval = 180,
                notificationsEnabled: Bool = true,
                notificationThresholds: [Double] = [80, 95, 100],
                sessionResetHeadsUpMinutes: Int? = 10,
                defaultShowRemaining: Bool = false,
                historyEnabled: Bool = true,
                launchAtLogin: Bool = false,
                automaticUpdatesEnabled: Bool = true,
                usageBreakdownEnabled: Bool = true) {
        self.pollInterval = pollInterval
        self.notificationsEnabled = notificationsEnabled
        self.notificationThresholds = notificationThresholds
        self.sessionResetHeadsUpMinutes = sessionResetHeadsUpMinutes
        self.defaultShowRemaining = defaultShowRemaining
        self.historyEnabled = historyEnabled
        self.launchAtLogin = launchAtLogin
        self.automaticUpdatesEnabled = automaticUpdatesEnabled
        self.usageBreakdownEnabled = usageBreakdownEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case pollInterval, notificationsEnabled, notificationThresholds
        case sessionResetHeadsUpMinutes, defaultShowRemaining, historyEnabled, launchAtLogin
        case automaticUpdatesEnabled, usageBreakdownEnabled
    }

    /// Decodes leniently: any field absent from an older stored blob falls back
    /// to its default, so shipping a new preference never wipes existing settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        pollInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .pollInterval) ?? d.pollInterval
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        notificationThresholds = try c.decodeIfPresent([Double].self, forKey: .notificationThresholds) ?? d.notificationThresholds
        sessionResetHeadsUpMinutes = try c.decodeIfPresent(Int.self, forKey: .sessionResetHeadsUpMinutes) ?? d.sessionResetHeadsUpMinutes
        defaultShowRemaining = try c.decodeIfPresent(Bool.self, forKey: .defaultShowRemaining) ?? d.defaultShowRemaining
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? d.historyEnabled
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        automaticUpdatesEnabled = try c.decodeIfPresent(
            Bool.self,
            forKey: .automaticUpdatesEnabled
        ) ?? d.automaticUpdatesEnabled
        usageBreakdownEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .usageBreakdownEnabled) ?? d.usageBreakdownEnabled
    }

    /// Returns a copy with out-of-range values coerced back into supported bounds.
    public func normalized() -> Preferences {
        var p = self
        p.pollInterval = max(Self.minPollInterval, pollInterval)
        p.notificationThresholds = Set(notificationThresholds.map { min(100, max(0, $0)) }).sorted()
        if let m = sessionResetHeadsUpMinutes { p.sessionResetHeadsUpMinutes = max(1, m) }
        return p
    }
}

public protocol PreferencesStoring: AnyObject {
    func load() -> Preferences
    func save(_ preferences: Preferences)
}

/// Persists `Preferences` as a JSON blob under a single UserDefaults key.
public final class UserDefaultsPreferencesStore: PreferencesStoring {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "cc-meter.preferences") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> Preferences {
        guard let data = defaults.data(forKey: key),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return prefs.normalized()
    }

    public func save(_ preferences: Preferences) {
        let normalized = preferences.normalized()
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: key)
    }
}

/// In-memory store for tests and previews.
public final class InMemoryPreferencesStore: PreferencesStoring {
    private var current: Preferences
    public init(_ initial: Preferences = Preferences()) { self.current = initial }
    public func load() -> Preferences { current }
    public func save(_ preferences: Preferences) { current = preferences.normalized() }
}
