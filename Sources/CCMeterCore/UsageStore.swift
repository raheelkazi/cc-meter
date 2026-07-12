import Foundation

/// A successful fetch persisted across app restarts, so startup can show
/// dated-but-real numbers instead of an error when the first fetch is
/// rate limited.
public struct SavedUsage: Equatable, Codable {
    public let usage: Usage
    public let savedAt: Date

    public init(usage: Usage, savedAt: Date) {
        self.usage = usage
        self.savedAt = savedAt
    }
}

public protocol UsageStoring {
    func save(_ saved: SavedUsage)
    func load() -> SavedUsage?
}

/// JSON-file store under Application Support. All failures are swallowed:
/// the cache is an optimization, never worth surfacing an error over.
public struct DiskUsageStore: UsageStoring {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location: ~/Library/Application Support/cc-meter/last-usage.json
    public static func standard(provider: UsageProvider = .claude) -> DiskUsageStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let filename = provider == .claude ? "last-usage.json" : "last-usage-codex.json"
        return DiskUsageStore(fileURL: base
            .appendingPathComponent("cc-meter", isDirectory: true)
            .appendingPathComponent(filename))
    }

    public func save(_ saved: SavedUsage) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    public func load() -> SavedUsage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SavedUsage.self, from: data)
    }
}
