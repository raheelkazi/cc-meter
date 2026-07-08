import Foundation

/// A projection of when a limit will be exhausted at the recent consumption rate.
public struct BurnProjection: Equatable {
    /// Estimated consumption rate in used-percent per hour (always > 0 here).
    public let ratePerHour: Double
    /// Seconds until the limit reaches 100% at `ratePerHour`.
    public let timeToLimit: TimeInterval
    /// True when exhaustion is projected to happen before the window resets,
    /// i.e. the pace is genuinely unsustainable for this window.
    public let willExhaustBeforeReset: Bool

    public init(ratePerHour: Double, timeToLimit: TimeInterval, willExhaustBeforeReset: Bool) {
        self.ratePerHour = ratePerHour
        self.timeToLimit = timeToLimit
        self.willExhaustBeforeReset = willExhaustBeforeReset
    }
}

/// Least-squares slope of percent vs. time (in hours) over the samples. Returns
/// nil when there is too little signal to extrapolate responsibly: fewer than
/// two points, or a time span below `minSpan`.
public func burnRatePerHour(_ samples: [HistorySample], minSpan: TimeInterval = 120) -> Double? {
    let ordered = samples.sorted { $0.at < $1.at }
    guard ordered.count >= 2 else { return nil }
    guard let first = ordered.first, let last = ordered.last,
          last.at.timeIntervalSince(first.at) >= minSpan else { return nil }

    let base = first.at
    let xs = ordered.map { $0.at.timeIntervalSince(base) / 3600.0 }   // hours
    let ys = ordered.map(\.percent)
    let n = Double(xs.count)
    let meanX = xs.reduce(0, +) / n
    let meanY = ys.reduce(0, +) / n
    var num = 0.0, den = 0.0
    for i in xs.indices {
        let dx = xs[i] - meanX
        num += dx * (ys[i] - meanY)
        den += dx * dx
    }
    guard den > 0 else { return nil }
    return num / den
}

/// Builds a projection for a limit, or nil when the pace is flat/negative or the
/// limit is already full. `minRatePerHour` suppresses trivial drift so the UI
/// only shows a projection when it is actually meaningful.
public func burnProjection(samples: [HistorySample],
                           currentPercent: Double,
                           resetsAt: Date,
                           now: Date,
                           minRatePerHour: Double = 1.0) -> BurnProjection? {
    guard currentPercent < 100 else { return nil }
    guard let rate = burnRatePerHour(samples), rate >= minRatePerHour else { return nil }

    let hoursToLimit = (100 - currentPercent) / rate
    let secondsToLimit = hoursToLimit * 3600
    let exhaustionDate = now.addingTimeInterval(secondsToLimit)
    return BurnProjection(ratePerHour: rate,
                          timeToLimit: secondsToLimit,
                          willExhaustBeforeReset: exhaustionDate < resetsAt)
}

/// Compact human text for a projection, e.g. "~40m to limit", "~2h to limit".
public func burnText(_ projection: BurnProjection) -> String {
    let secs = Int(projection.timeToLimit)
    let days = secs / 86400
    let hours = (secs % 86400) / 3600
    let mins = (secs % 3600) / 60
    let duration: String
    if days > 0 { duration = "\(days)d \(hours)h" }
    else if hours > 0 { duration = "\(hours)h \(mins)m" }
    else { duration = "\(max(1, mins))m" }
    return "~\(duration) to limit"
}
