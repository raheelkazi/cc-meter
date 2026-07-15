import Foundation

public protocol UsageEventStoring: AnyObject {
    /// Appends events whose dedupKey is not already retained. Safe to call off the main thread.
    func append(_ events: [UsageEvent])
    /// Snapshot of retained events at or after `since`. Safe to call from any thread.
    func events(since: Date) -> [UsageEvent]
    /// Blocks until queued disk writes land (tests, clean shutdown).
    func flush()
}

private enum EventMath {
    static func pruned(_ events: [UsageEvent], now: Date, retention: TimeInterval) -> [UsageEvent] {
        let cutoff = now.addingTimeInterval(-retention)
        return events.filter { $0.at >= cutoff }
    }
}

/// Deduplicated JSON-Lines store of usage events, mirroring `FileHistoryStore`: append cheaply,
/// compact occasionally, prune to a retention window. Unlike `FileHistoryStore` it is guarded by
/// a lock, because the indexer appends from a background queue while the view-model reads on main.
public final class FileUsageEventStore: UsageEventStoring {
    private let url: URL
    private let retention: TimeInterval
    private let compactEvery: Int
    private let now: () -> Date
    private let lock = NSLock()
    private var events: [UsageEvent]
    private var keys: Set<String>
    private var recordsSinceCompact = 0
    private static let io = DispatchQueue(label: "cc-meter.usage-events.io", qos: .utility)

    public init(url: URL, retention: TimeInterval = 7*24*3600,
                compactEvery: Int = 500, now: @escaping () -> Date = { Date() }) {
        self.url = url
        self.retention = retention
        self.compactEvery = compactEvery
        self.now = now
        let loaded = Self.load(url)
        self.events = EventMath.pruned(loaded, now: now(), retention: retention)
        self.keys = Set(self.events.map(\.dedupKey))
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("cc-meter", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-events.json")
    }

    private static func load(_ url: URL) -> [UsageEvent] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(UsageEvent.self, from: Data($0)) }
    }

    public func flush() { Self.io.sync {} }

    public func append(_ incoming: [UsageEvent]) {
        lock.lock()
        let clock = now()
        // Prune expired events and rebuild the key set BEFORE deduping, so a dedupKey whose event
        // has aged out of retention is freed and a re-logged event with that key is accepted rather
        // than silently dropped (then the old copy pruned away, leaving nothing).
        events = EventMath.pruned(events, now: clock, retention: retention)
        keys = Set(events.map(\.dedupKey))
        var fresh: [UsageEvent] = []
        for event in incoming where !keys.contains(event.dedupKey) {
            keys.insert(event.dedupKey)
            fresh.append(event)
        }
        guard !fresh.isEmpty else { lock.unlock(); return }
        events.append(contentsOf: fresh)
        events = EventMath.pruned(events, now: clock, retention: retention)
        keys = Set(events.map(\.dedupKey))
        recordsSinceCompact += fresh.count
        let shouldCompact = recordsSinceCompact >= compactEvery
        let snapshot = events
        lock.unlock()

        if shouldCompact { compact(snapshot) } else { appendToDisk(fresh) }
    }

    public func events(since: Date) -> [UsageEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.at >= since }
    }

    private func appendToDisk(_ fresh: [UsageEvent]) {
        let payload = Self.encode(fresh)
        guard !payload.isEmpty else { return }
        let url = self.url
        Self.io.async {
            guard FileManager.default.fileExists(atPath: url.path) else {
                try? payload.write(to: url, options: .atomic); return
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        }
    }

    private func compact(_ snapshot: [UsageEvent]) {
        lock.lock(); recordsSinceCompact = 0; lock.unlock()
        let payload = Self.encode(snapshot)
        let url = self.url
        Self.io.async { try? payload.write(to: url, options: .atomic) }
    }

    private static func encode(_ events: [UsageEvent]) -> Data {
        let encoder = JSONEncoder()
        var payload = Data()
        for event in events {
            guard let line = try? encoder.encode(event) else { continue }
            payload.append(line); payload.append(UInt8(ascii: "\n"))
        }
        return payload
    }
}

/// In-memory event store for tests and previews.
public final class InMemoryUsageEventStore: UsageEventStoring {
    private let retention: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var events: [UsageEvent]
    private var keys: Set<String>

    public init(events: [UsageEvent] = [], retention: TimeInterval = 7*24*3600,
                now: @escaping () -> Date = { Date() }) {
        self.events = events
        self.retention = retention
        self.now = now
        self.keys = Set(events.map(\.dedupKey))
    }

    public func append(_ incoming: [UsageEvent]) {
        lock.lock(); defer { lock.unlock() }
        let clock = now()
        // Prune expired events and rebuild the key set BEFORE deduping, so a dedupKey whose event
        // has aged out of retention is freed and a re-logged event with that key is accepted.
        events = EventMath.pruned(events, now: clock, retention: retention)
        keys = Set(events.map(\.dedupKey))
        for event in incoming where !keys.contains(event.dedupKey) {
            keys.insert(event.dedupKey)
            events.append(event)
        }
        events = EventMath.pruned(events, now: clock, retention: retention)
        keys = Set(events.map(\.dedupKey))
    }

    public func events(since: Date) -> [UsageEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0.at >= since }
    }

    public func flush() {}
}
