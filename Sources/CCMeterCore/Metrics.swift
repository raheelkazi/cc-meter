import Foundation

/// Colors a window by how much of the limit has been used, like a fuel gauge:
/// plenty left -> green, getting close -> amber, nearly exhausted -> red. Usage
/// only ever gets "hotter" as it climbs, so an empty window reads green and a
/// full one reads red.
public func usageColor(percent: Double,
                       amberThreshold: Double = 50,
                       redThreshold: Double = 90) -> MeterColor {
    if percent >= redThreshold { return .red }
    if percent >= amberThreshold { return .amber }
    return .green
}

/// Bare time to reset, e.g. "2d 3h", "42m". The popover shows this as a right-aligned
/// column, where the "resets in" prefix would be identical on every row and so carries
/// no information.
public func countdownValue(to resetsAt: Date, now: Date) -> String {
    let secs = Int(resetsAt.timeIntervalSince(now))
    if secs <= 0 { return "now" }
    let days = secs / 86400
    let hours = (secs % 86400) / 3600
    let mins = (secs % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(mins)m" }
    return "\(mins)m"
}

/// Human countdown to the reset time, e.g. "resets in 2d 3h", "resets in 42m".
public func countdownText(to resetsAt: Date, now: Date) -> String {
    guard resetsAt.timeIntervalSince(now) > 0 else { return "resetting" }
    return "resets in \(countdownValue(to: resetsAt, now: now))"
}
