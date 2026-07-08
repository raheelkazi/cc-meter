import Foundation

/// One recorded observation of a single limit's used percent at a point in time.
public struct HistorySample: Codable, Equatable {
    public let kindLabel: String
    public let percent: Double
    public let at: Date
    /// The reset time of the window this sample belongs to. Lets consumers avoid
    /// mixing samples across a window reset (a fresh window shouldn't inherit the
    /// old window's burn rate or trend). Optional so older stored files decode.
    public let windowResetsAt: Date?

    public init(kindLabel: String, percent: Double, at: Date, windowResetsAt: Date? = nil) {
        self.kindLabel = kindLabel
        self.percent = percent
        self.at = at
        self.windowResetsAt = windowResetsAt
    }
}

/// Evenly-spaced downsample keeping the first and last values, for sparklines.
public func downsampleSeries(_ values: [Double], maxPoints: Int) -> [Double] {
    guard maxPoints > 0, values.count > maxPoints else { return values }
    var result: [Double] = []
    let step = Double(values.count - 1) / Double(maxPoints - 1)
    for i in 0..<maxPoints {
        result.append(values[Int((Double(i) * step).rounded())])
    }
    return result
}

public protocol HistoryStoring: AnyObject {
    /// Appends a sample per limit in `usage` and prunes anything past retention.
    func record(_ usage: Usage)
    /// Samples for a limit at or after `since`, oldest first.
    func recent(kindLabel: String, since: Date) -> [HistorySample]
    /// Recent percents for a limit, downsampled to at most `maxPoints` for a sparkline.
    func series(kindLabel: String, maxPoints: Int) -> [Double]
}

/// Shared sample math so the file and in-memory stores behave identically.
enum HistoryMath {
    static func recent(_ samples: [HistorySample], kindLabel: String, since: Date) -> [HistorySample] {
        samples
            .filter { $0.kindLabel == kindLabel && $0.at >= since }
            .sorted { $0.at < $1.at }
    }

    /// Evenly-spaced downsample that always keeps the first and last points, so a
    /// long history still renders a bounded-width sparkline without losing its
    /// endpoints (the trend's start and current value).
    static func series(_ samples: [HistorySample], kindLabel: String, maxPoints: Int) -> [Double] {
        let ordered = samples.filter { $0.kindLabel == kindLabel }.sorted { $0.at < $1.at }
        return downsampleSeries(ordered.map(\.percent), maxPoints: maxPoints)
    }

    static func pruned(_ samples: [HistorySample], now: Date, retention: TimeInterval) -> [HistorySample] {
        let cutoff = now.addingTimeInterval(-retention)
        return samples.filter { $0.at >= cutoff }
    }
}

/// Persists samples as a JSON array in Application Support, bounded to a
/// retention window (default 7 days) so the file stays small.
public final class FileHistoryStore: HistoryStoring {
    private let url: URL
    private let retention: TimeInterval
    private let now: () -> Date
    private var samples: [HistorySample]

    public init(url: URL, retention: TimeInterval = 7 * 24 * 3600, now: @escaping () -> Date = { Date() }) {
        self.url = url
        self.retention = retention
        self.now = now
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([HistorySample].self, from: data) {
            self.samples = decoded
        } else {
            self.samples = []
        }
    }

    /// Default location: ~/Library/Application Support/cc-meter/history.json.
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("cc-meter", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    public func record(_ usage: Usage) {
        let clock = now()
        for limit in usage.limits {
            samples.append(HistorySample(kindLabel: limit.kind.label, percent: limit.percent,
                                         at: clock, windowResetsAt: limit.resetsAt))
        }
        samples = HistoryMath.pruned(samples, now: clock, retention: retention)
        persist()
    }

    public func recent(kindLabel: String, since: Date) -> [HistorySample] {
        HistoryMath.recent(samples, kindLabel: kindLabel, since: since)
    }

    public func series(kindLabel: String, maxPoints: Int) -> [Double] {
        HistoryMath.series(samples, kindLabel: kindLabel, maxPoints: maxPoints)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// In-memory history for tests and previews.
public final class InMemoryHistoryStore: HistoryStoring {
    private var samples: [HistorySample]
    private let retention: TimeInterval
    private let now: () -> Date

    public init(samples: [HistorySample] = [],
                retention: TimeInterval = 7 * 24 * 3600,
                now: @escaping () -> Date = { Date() }) {
        self.samples = samples
        self.retention = retention
        self.now = now
    }

    public func record(_ usage: Usage) {
        let clock = now()
        for limit in usage.limits {
            samples.append(HistorySample(kindLabel: limit.kind.label, percent: limit.percent,
                                         at: clock, windowResetsAt: limit.resetsAt))
        }
        samples = HistoryMath.pruned(samples, now: clock, retention: retention)
    }

    public func recent(kindLabel: String, since: Date) -> [HistorySample] {
        HistoryMath.recent(samples, kindLabel: kindLabel, since: since)
    }

    public func series(kindLabel: String, maxPoints: Int) -> [Double] {
        HistoryMath.series(samples, kindLabel: kindLabel, maxPoints: maxPoints)
    }
}
