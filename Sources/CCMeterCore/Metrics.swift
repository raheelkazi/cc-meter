import Foundation

/// Colors a window by comparing how much has been used to how far through the
/// window we are. Uses less than sustainable pace -> green, elevated -> amber,
/// burning too fast -> red. Remaining under 10% forces red.
public func burnRateColor(percent: Double,
                          resetsAt: Date,
                          windowLength: TimeInterval,
                          now: Date,
                          greenFactor: Double = 1.0,
                          amberFactor: Double = 1.5) -> MeterColor {
    let remaining = 100 - percent
    if remaining < 10 { return .red }

    let used = percent / 100
    if used < 0.05 { return .green }   // guard against false-red right after a reset

    let timeUntilReset = resetsAt.timeIntervalSince(now)
    let elapsed = min(max((windowLength - timeUntilReset) / windowLength, 0.001), 1)

    if used <= elapsed * greenFactor { return .green }
    if used <= elapsed * amberFactor { return .amber }
    return .red
}

/// Human countdown to the reset time, e.g. "resets in 2d 3h", "resets in 42m".
public func countdownText(to resetsAt: Date, now: Date) -> String {
    let secs = Int(resetsAt.timeIntervalSince(now))
    if secs <= 0 { return "resetting" }
    let days = secs / 86400
    let hours = (secs % 86400) / 3600
    let mins = (secs % 3600) / 60
    if days > 0 { return "resets in \(days)d \(hours)h" }
    if hours > 0 { return "resets in \(hours)h \(mins)m" }
    return "resets in \(mins)m"
}
