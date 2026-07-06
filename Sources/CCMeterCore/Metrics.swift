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
