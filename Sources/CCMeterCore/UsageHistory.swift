import Foundation

/// One recorded observation of a single limit's used percent at a point in time.
public struct HistorySample: Codable, Equatable {
    public let provider: UsageProvider
    public let kindLabel: String
    public let percent: Double
    public let at: Date
    /// The reset time of the window this sample belongs to. Lets consumers avoid
    /// mixing samples across a window reset (a fresh window shouldn't inherit the
    /// old window's burn rate or trend). Optional so older stored files decode.
    public let windowResetsAt: Date?

    public init(provider: UsageProvider = .claude,
                kindLabel: String,
                percent: Double,
                at: Date,
                windowResetsAt: Date? = nil) {
        self.provider = provider
        self.kindLabel = kindLabel
        self.percent = percent
        self.at = at
        self.windowResetsAt = windowResetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case provider, kindLabel, percent, at, windowResetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(UsageProvider.self, forKey: .provider) ?? .claude
        kindLabel = try container.decode(String.self, forKey: .kindLabel)
        percent = try container.decode(Double.self, forKey: .percent)
        at = try container.decode(Date.self, forKey: .at)
        windowResetsAt = try container.decodeIfPresent(Date.self, forKey: .windowResetsAt)
    }
}

public protocol HistoryStoring: AnyObject {
    /// Appends a sample per limit in `usage` and prunes anything past retention.
    func record(_ usage: Usage)
    /// Samples for a limit at or after `since`, oldest first.
    func recent(kindLabel: String, since: Date) -> [HistorySample]
    func record(_ usage: Usage, provider: UsageProvider)
    func recent(provider: UsageProvider, kindLabel: String, since: Date) -> [HistorySample]
}

public extension HistoryStoring {
    func record(_ usage: Usage, provider: UsageProvider) { record(usage) }
    func recent(provider: UsageProvider, kindLabel: String, since: Date) -> [HistorySample] {
        recent(kindLabel: kindLabel, since: since)
    }
}

/// Shared sample math so the file and in-memory stores behave identically.
enum HistoryMath {
    static func recent(_ samples: [HistorySample],
                       provider: UsageProvider,
                       kindLabel: String,
                       since: Date) -> [HistorySample] {
        samples
            .filter { $0.provider == provider && $0.kindLabel == kindLabel && $0.at >= since }
            .sorted { $0.at < $1.at }
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
        record(usage, provider: .claude)
    }

    public func record(_ usage: Usage, provider: UsageProvider) {
        let clock = now()
        for limit in usage.limits {
            samples.append(HistorySample(provider: provider,
                                         kindLabel: limit.kind.label, percent: limit.percent,
                                         at: clock, windowResetsAt: limit.resetsAt))
        }
        samples = HistoryMath.pruned(samples, now: clock, retention: retention)
        persist()
    }

    public func recent(kindLabel: String, since: Date) -> [HistorySample] {
        recent(provider: .claude, kindLabel: kindLabel, since: since)
    }

    public func recent(provider: UsageProvider, kindLabel: String, since: Date) -> [HistorySample] {
        HistoryMath.recent(samples, provider: provider, kindLabel: kindLabel, since: since)
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
        record(usage, provider: .claude)
    }

    public func record(_ usage: Usage, provider: UsageProvider) {
        let clock = now()
        for limit in usage.limits {
            samples.append(HistorySample(provider: provider,
                                         kindLabel: limit.kind.label, percent: limit.percent,
                                         at: clock, windowResetsAt: limit.resetsAt))
        }
        samples = HistoryMath.pruned(samples, now: clock, retention: retention)
    }

    public func recent(kindLabel: String, since: Date) -> [HistorySample] {
        recent(provider: .claude, kindLabel: kindLabel, since: since)
    }

    public func recent(provider: UsageProvider, kindLabel: String, since: Date) -> [HistorySample] {
        HistoryMath.recent(samples, provider: provider, kindLabel: kindLabel, since: since)
    }

}
