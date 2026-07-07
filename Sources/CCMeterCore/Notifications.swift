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
    public func evaluate(_ usage: Usage, preferences: Preferences, now: Date) -> [NotificationEvent] {
        var events: [NotificationEvent] = []
        let thresholds = preferences.notificationThresholds.sorted()

        for limit in usage.limits {
            let label = limit.kind.label
            let isNewWindow = windowResetsAt[label] != limit.resetsAt
            if isNewWindow {
                windowResetsAt[label] = limit.resetsAt
                firedThresholds[label] = []
                lastPercent[label] = limit.percent   // baseline, no retroactive fire
            }

            let previous = lastPercent[label] ?? limit.percent
            for threshold in thresholds {
                let alreadyFired = firedThresholds[label]?.contains(threshold) ?? false
                if previous < threshold, limit.percent >= threshold, !alreadyFired {
                    events.append(Self.thresholdEvent(limit: limit, threshold: threshold, now: now))
                    firedThresholds[label, default: []].insert(threshold)
                }
            }
            lastPercent[label] = limit.percent

            if let mins = preferences.sessionResetHeadsUpMinutes, limit.kind == .session {
                let secondsLeft = limit.resetsAt.timeIntervalSince(now)
                let key = "\(label)@\(limit.resetsAt.timeIntervalSince1970)"
                if secondsLeft > 0, secondsLeft <= Double(mins * 60), !firedHeadsUp.contains(key) {
                    events.append(Self.headsUpEvent(limit: limit, now: now))
                    firedHeadsUp.insert(key)
                }
            }
        }

        return preferences.notificationsEnabled ? events : []
    }

    private static func thresholdEvent(limit: UsageLimit, threshold: Double, now: Date) -> NotificationEvent {
        let pct = Int(threshold.rounded())
        let title: String
        let body: String
        if pct >= 100 {
            title = "\(limit.kind.label) limit reached"
            body = "You've hit your \(limit.kind.label) limit. \(countdownText(to: limit.resetsAt, now: now))."
        } else {
            title = "\(limit.kind.label) usage at \(pct)%"
            body = "Your \(limit.kind.label) window is \(Int(limit.percent.rounded()))% used. \(countdownText(to: limit.resetsAt, now: now))."
        }
        return NotificationEvent(id: "\(limit.kind.label)#\(pct)", title: title, body: body)
    }

    private static func headsUpEvent(limit: UsageLimit, now: Date) -> NotificationEvent {
        NotificationEvent(id: "\(limit.kind.label)#reset-headsup",
                          title: "\(limit.kind.label) resets soon",
                          body: "Your \(limit.kind.label) window \(countdownText(to: limit.resetsAt, now: now)).")
    }
}
