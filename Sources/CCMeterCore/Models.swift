import Foundation

/// "GPT-5.3-Codex-Spark" -> "Spark".
///
/// The `GPT-5.x` stem repeats on every limit and identifies nothing; the trailing token is
/// the only part that tells two models apart, and dropping the rest is what lets limits sit
/// side by side in the popover.
public func shortModelToken(_ model: String) -> String {
    model.split(separator: "-").last.map(String.init) ?? model
}

/// A friendly model label for the usage breakdown. Claude names collapse to their family
/// ("claude-opus-4-8" -> "opus"); everything else keeps its trailing token ("gpt-5.6-sol" ->
/// "sol"). `shortModelToken` alone returns "8"/"5" for Claude names - the version digit, which
/// tells the reader nothing.
public func modelFamilyLabel(_ model: String) -> String {
    let lower = model.lowercased()
    for family in ["opus", "sonnet", "haiku", "fable"] where lower.contains(family) {
        return family
    }
    return shortModelToken(model)
}

/// "5-hour" -> "5h", "7-day" -> "7d". Anything unrecognised is left alone.
public func compactWindowToken(_ window: String) -> String {
    for (suffix, short) in [("-hour", "h"), ("-day", "d")] {
        if let range = window.range(of: suffix), range.upperBound == window.endIndex {
            return String(window[window.startIndex..<range.lowerBound]) + short
        }
    }
    return window
}

/// "5-hour · GPT-5.6-Sol" -> "5h·Sol".
///
/// The window is always kept: Codex reports the same model in more than one window, so a
/// bare "Sol" would produce two cells that look identical.
public func compactScopedLabel(_ label: String) -> String {
    let parts = label.components(separatedBy: " · ")
    let window = compactWindowToken(parts[0])
    guard parts.count > 1 else { return window }
    return "\(window)·\(shortModelToken(parts[1]))"
}

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

    /// Short form for the popover's side-by-side cells: "5h", "7d", "7d·Sol".
    ///
    /// Only safe to show when it is unique within a provider's limits — see
    /// `MeterRow.compactLabel`, which falls back to `label` on a collision.
    public var compactLabel: String {
        switch self {
        case .session: return "5h"
        case .weeklyAll: return "7d"
        case .weeklyScoped(let model): return "7d·\(shortModelToken(model))"
        case .named(_, let label, _): return compactScopedLabel(label)
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
        // Clamped once, at the boundary. A limit can report overage (>100), and "Left" mode
        // computes 100 - used — so an unclamped 104 rendered as "-4%" in the popover, and
        // VoiceOver read it as "minus 4 percent". Three render sites were each clamping (or
        // forgetting to); the wire is the right place to do it.
        self.percent = min(100, max(0, percent))
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
