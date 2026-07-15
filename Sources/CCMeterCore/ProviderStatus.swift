import Foundation

/// Severity of a provider's reported status. `ok` shows no cue.
public enum StatusLevel: Int, Comparable {
    case ok = 0, degraded = 1, major = 2
    public static func < (lhs: StatusLevel, rhs: StatusLevel) -> Bool { lhs.rawValue < rhs.rawValue }
    /// The menu-bar / banner color; nil when there is nothing to show.
    public var color: MeterColor? {
        switch self {
        case .ok: return nil
        case .degraded: return .amber
        case .major: return .red
        }
    }
}

/// A provider's current incident/status, derived from its status page.
public struct ProviderStatus: Equatable {
    public let provider: UsageProvider
    public let level: StatusLevel
    public let headline: String?
    public let detail: String?
    public let url: URL?
    public init(provider: UsageProvider, level: StatusLevel,
                headline: String? = nil, detail: String? = nil, url: URL? = nil) {
        self.provider = provider
        self.level = level
        self.headline = headline
        self.detail = detail
        self.url = url
    }
}
