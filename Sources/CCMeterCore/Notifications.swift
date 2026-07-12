import Foundation

/// A single notification the app may post. `id` is stable per (window, reason)
/// so the platform layer can de-duplicate/replace rather than stack duplicates.
public struct NotificationEvent: Equatable {
    public let id: String
    public let title: String
    public let body: String

    public init(id: String, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

public protocol Notifying {
    func post(_ event: NotificationEvent)
}

/// Decides which notifications to fire as usage changes over time. Edge-triggered:
/// a threshold fires once when usage crosses it upward, and re-arms only after the
/// window resets. The first observation of a window never fires retroactively, so
/// launching the app while already above a threshold does not spam alerts.
public final class ThresholdNotifier {
    private var lastPercent: [String: Double] = [:]
    private var windowResetsAt: [String: Date] = [:]
    private var firedThresholds: [String: Set<Double>] = [:]
    private var firedHeadsUp: Set<String> = []

    public init() {}

    /// Advances internal tracking to reflect `usage` and returns the events that
    /// should be posted for this tick. State is always updated (even when
    /// notifications are disabled) so re-enabling never replays old crossings.
    public func evaluate(_ usage: Usage,
                         provider: UsageProvider = .claude,
                         preferences: Preferences,
                         now: Date) -> [NotificationEvent] {
        var events: [NotificationEvent] = []
        let thresholds = preferences.notificationThresholds.sorted()

        for limit in usage.limits {
            let label = limit.kind.label
            let key = "\(provider.rawValue)#\(label)"
            let isNewWindow = windowResetsAt[key] != limit.resetsAt
            if isNewWindow {
                windowResetsAt[key] = limit.resetsAt
                firedThresholds[key] = []
                lastPercent[key] = limit.percent   // baseline, no retroactive fire
            }

            let previous = lastPercent[key] ?? limit.percent
            for threshold in thresholds {
                let alreadyFired = firedThresholds[key]?.contains(threshold) ?? false
                if previous < threshold, limit.percent >= threshold, !alreadyFired {
                    events.append(Self.thresholdEvent(provider: provider, limit: limit,
                                                      threshold: threshold, now: now))
                    firedThresholds[key, default: []].insert(threshold)
                }
            }
            lastPercent[key] = limit.percent

            if let mins = preferences.sessionResetHeadsUpMinutes, limit.kind.isSessionWindow {
                let secondsLeft = limit.resetsAt.timeIntervalSince(now)
                let headsUpKey = "\(key)@\(limit.resetsAt.timeIntervalSince1970)"
                let withinWindow = secondsLeft > 0 && secondsLeft <= Double(mins * 60)
                if isNewWindow && withinWindow {
                    // First time we see this window and we're already inside the
                    // heads-up range (e.g. relaunched mid-window): suppress rather
                    // than replay an alert the user already got. Only a live
                    // transition into the range should fire.
                    firedHeadsUp.insert(headsUpKey)
                } else if withinWindow && !firedHeadsUp.contains(headsUpKey) {
                    events.append(Self.headsUpEvent(provider: provider, limit: limit, now: now))
                    firedHeadsUp.insert(headsUpKey)
                }
            }
        }

        return preferences.notificationsEnabled ? events : []
    }

    private static func thresholdEvent(provider: UsageProvider,
                                       limit: UsageLimit,
                                       threshold: Double,
                                       now: Date) -> NotificationEvent {
        let pct = Int(threshold.rounded())
        let title: String
        let body: String
        if pct >= 100 {
            title = "\(provider.displayName) · \(limit.kind.label) limit reached"
            body = "You've hit your \(provider.displayName) \(limit.kind.label) limit. \(countdownText(to: limit.resetsAt, now: now))."
        } else {
            title = "\(provider.displayName) · \(limit.kind.label) usage at \(pct)%"
            body = "Your \(provider.displayName) \(limit.kind.label) window is \(Int(limit.percent.rounded()))% used. \(countdownText(to: limit.resetsAt, now: now))."
        }
        return NotificationEvent(id: "\(provider.rawValue)#\(limit.kind.label)#\(pct)",
                                 title: title, body: body)
    }

    private static func headsUpEvent(provider: UsageProvider,
                                     limit: UsageLimit,
                                     now: Date) -> NotificationEvent {
        NotificationEvent(id: "\(provider.rawValue)#\(limit.kind.label)#reset-headsup",
                          title: "\(provider.displayName) · \(limit.kind.label) resets soon",
                          body: "Your \(provider.displayName) \(limit.kind.label) window \(countdownText(to: limit.resetsAt, now: now)).")
    }
}
