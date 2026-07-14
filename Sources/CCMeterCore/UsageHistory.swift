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

/// Persists samples in Application Support, bounded to a retention window (default 7 days).
///
/// Stored as JSON Lines — one sample per line — so a poll appends a few hundred bytes instead
/// of re-serialising the whole file. It previously encoded *every retained sample* and
/// rewrote the entire file on every poll, on the main actor: at a 60s poll that is a ~4MB
/// re-encode 1,440 times a day (~6GB of writes), and it grew for the first 7 days and then
/// plateaued — so it degraded the longer the app stayed running.
///
/// All disk work now happens on a background queue. The file is compacted (fully rewritten
/// from the pruned in-memory samples) only every `compactEvery` records, which is what keeps
/// it from growing without bound.
public final class FileHistoryStore: HistoryStoring {
    private let url: URL
    private let retention: TimeInterval
    private let now: () -> Date
    private var samples: [HistorySample]
    private let compactEvery: Int
    private var recordsSinceCompact = 0

    /// `record` is called from `@MainActor refresh()`. Encoding and writing there stalled the
    /// UI once per poll, so every write is handed to this serial queue instead.
    private static let io = DispatchQueue(label: "cc-meter.history.io", qos: .utility)

    public init(url: URL,
                retention: TimeInterval = 7 * 24 * 3600,
                compactEvery: Int = 500,
                now: @escaping () -> Date = { Date() }) {
        self.url = url
        self.retention = retention
        self.compactEvery = compactEvery
        self.now = now

        let (loaded, isLegacyFormat) = Self.load(url)
        self.samples = HistoryMath.pruned(loaded, now: now(), retention: retention)
        // A file left in the old whole-array format is rewritten once, as JSON Lines.
        if isLegacyFormat { compact() }
    }

    /// Returns the samples, and whether the file was in the legacy JSON-array format.
    private static func load(_ url: URL) -> ([HistorySample], isLegacyFormat: Bool) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return ([], false) }
        let decoder = JSONDecoder()

        if let legacy = try? decoder.decode([HistorySample].self, from: data) {
            return (legacy, true)
        }

        let decoded = data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(HistorySample.self, from: Data($0)) }
        return (decoded, false)
    }

    /// Blocks until every queued write has landed. For tests, and for a clean shutdown.
    public func flush() {
        Self.io.sync {}
    }

    /// Default location: ~/Library/Application Support/cc-meter/history.json.
    public static func defaultURL(provider: UsageProvider = .claude,
                                  fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("cc-meter", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = provider == .claude ? "history.json" : "history-codex.json"
        return dir.appendingPathComponent(filename)
    }

    public func record(_ usage: Usage) {
        record(usage, provider: .claude)
    }

    public func record(_ usage: Usage, provider: UsageProvider) {
        let clock = now()
        let fresh = usage.limits.map {
            HistorySample(provider: provider,
                          kindLabel: $0.kind.identity, percent: $0.percent,
                          at: clock, windowResetsAt: $0.resetsAt)
        }
        samples.append(contentsOf: fresh)
        samples = HistoryMath.pruned(samples, now: clock, retention: retention)

        recordsSinceCompact += 1
        // Pruning drops samples on every poll once the retention window is full, so compaction
        // cannot be driven by "did anything expire" — it would then run every single time.
        // Append cheaply; rewrite occasionally.
        if recordsSinceCompact >= compactEvery {
            compact()
        } else {
            append(fresh)
        }
    }

    public func recent(kindLabel: String, since: Date) -> [HistorySample] {
        recent(provider: .claude, kindLabel: kindLabel, since: since)
    }

    public func recent(provider: UsageProvider, kindLabel: String, since: Date) -> [HistorySample] {
        HistoryMath.recent(samples, provider: provider, kindLabel: kindLabel, since: since)
    }

    /// Appends only the new samples — a few hundred bytes — rather than rewriting the file.
    private func append(_ fresh: [HistorySample]) {
        let encoder = JSONEncoder()
        var payload = Data()
        for sample in fresh {
            guard let line = try? encoder.encode(sample) else { continue }
            payload.append(line)
            payload.append(UInt8(ascii: "\n"))
        }
        guard !payload.isEmpty else { return }

        let url = self.url
        Self.io.async {
            let manager = FileManager.default
            guard manager.fileExists(atPath: url.path) else {
                try? payload.write(to: url, options: .atomic)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        }
    }

    /// Rewrites the file from the pruned in-memory samples, dropping everything expired. This
    /// is the only thing that shrinks the file, so it must run periodically.
    private func compact() {
        recordsSinceCompact = 0

        let encoder = JSONEncoder()
        var payload = Data()
        for sample in samples {
            guard let line = try? encoder.encode(sample) else { continue }
            payload.append(line)
            payload.append(UInt8(ascii: "\n"))
        }

        let url = self.url
        Self.io.async {
            try? payload.write(to: url, options: .atomic)
        }
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
                                         kindLabel: limit.kind.identity, percent: limit.percent,
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
