import Foundation

public enum WindowKind: Equatable {
    case session
    case weeklyAll
    case weeklyScoped(model: String)

    /// Rolling window length used to compute elapsed fraction.
    public var length: TimeInterval {
        switch self {
        case .session: return 5 * 3600
        case .weeklyAll, .weeklyScoped: return 7 * 24 * 3600
        }
    }

    public var label: String {
        switch self {
        case .session: return "5-hour"
        case .weeklyAll: return "7-day"
        case .weeklyScoped(let model): return "7-day (\(model))"
        }
    }
}

public struct UsageLimit: Equatable {
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

public struct Usage: Equatable {
    public let limits: [UsageLimit]
    public let fetchedAt: Date

    public init(limits: [UsageLimit], fetchedAt: Date) {
        self.limits = limits
        self.fetchedAt = fetchedAt
    }
}

public enum UsageError: Error, Equatable {
    case noCredentials
    case unauthorized
    case rateLimited
    case network(String)
}

public enum MeterColor: Equatable {
    case green, amber, red
}
