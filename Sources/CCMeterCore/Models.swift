import Foundation

/// The one place a window label gets a model scope appended.
///
/// Claude's weekly-scoped windows and Codex's named windows both produce
/// "<window> · <model>" labels; formatting them separately let the two drift.
/// A middle dot rather than parentheses so a long model name truncates with an
/// ellipsis in the popover instead of wrapping the row onto a second line.
public func scopedWindowLabel(window: String, model: String?) -> String {
    guard let model, !model.isEmpty else { return window }
    return "\(window) · \(model)"
}

public enum WindowKind: Equatable, Codable {
    case session
    case weeklyAll
    case weeklyScoped(model: String)
    case named(id: String, label: String, isSession: Bool)

    public var label: String {
        switch self {
        case .session: return "5-hour"
        case .weeklyAll: return "7-day"
        case .weeklyScoped(let model): return scopedWindowLabel(window: "7-day", model: model)
        case .named(_, let label, _): return label
        }
    }

    public var identity: String {
        switch self {
        case .session, .weeklyAll, .weeklyScoped: return label
        case .named(let id, _, _): return id
        }
    }

    public var isSessionWindow: Bool {
        switch self {
        case .session: return true
        case .named(_, _, let isSession): return isSession
        case .weeklyAll, .weeklyScoped: return false
        }
    }
}

public struct UsageLimit: Equatable, Codable {
    public let kind: WindowKind
    public let percent: Double   // 0...100
    public let resetsAt: Date
    public let isActive: Bool

    public init(kind: WindowKind, percent: Double, resetsAt: Date, isActive: Bool) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
        self.isActive = isActive
    }
}

/// Extra / metered spend the endpoint reports alongside rate limits. Amounts are
/// in whole currency units (e.g. dollars).
public struct Spend: Equatable, Codable {
    public let amount: Double
    public let limit: Double?
    public let currency: String

    public init(amount: Double, limit: Double?, currency: String) {
        self.amount = amount
        self.limit = limit
        self.currency = currency
    }

    /// Fraction of the spend cap used (0...100), or nil when there is no cap.
    public var percent: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(100, amount / limit * 100)
    }
}

public struct Usage: Equatable, Codable {
    public let limits: [UsageLimit]
    public let spend: Spend?
    public let fetchedAt: Date

    public init(limits: [UsageLimit], spend: Spend? = nil, fetchedAt: Date) {
        self.limits = limits
        self.spend = spend
        self.fetchedAt = fetchedAt
    }
}

public enum UsageError: Error, Equatable {
    case noCredentials
    case unauthorized
    // Server-reported back-off (Retry-After header), in seconds, when present.
    // Polling before it elapses just burns more of the shared rate budget.
    case rateLimited(retryAfter: TimeInterval?)
    // Transient connectivity blip. Safe to keep showing last-known data and retry.
    case network(String)
    // Deterministic response problem (undecodable body, forbidden, unexpected
    // status). Retrying will not fix it, so it must surface, not be kept stale.
    case badResponse(String)
}

public enum MeterColor: Equatable {
    case green, amber, red
}
