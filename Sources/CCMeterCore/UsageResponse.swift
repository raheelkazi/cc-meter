import Foundation

/// Mirrors the JSON returned by /api/oauth/usage. Only fields we use are decoded;
/// unknown fields are ignored by Codable.
public struct UsageResponse: Decodable {
    public let limits: [Limit]?

    public struct Limit: Decodable {
        public let kind: String
        public let percent: Double
        public let resetsAt: String?
        public let isActive: Bool?
        public let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }

        public struct Scope: Decodable {
            public let model: Model?
            public struct Model: Decodable {
                public let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" }
            }
        }
    }

    public func toUsage(now: Date) -> Usage {
        var out: [UsageLimit] = []
        for l in (limits ?? []) {
            guard let kind = WindowKind(kindString: l.kind, scopeModel: l.scope?.model?.displayName),
                  let resetsRaw = l.resetsAt,
                  let resetsAt = ISODate.parse(resetsRaw) else { continue }
            out.append(UsageLimit(kind: kind,
                                  percent: l.percent,
                                  resetsAt: resetsAt,
                                  isActive: l.isActive ?? false))
        }
        return Usage(limits: out, fetchedAt: now)
    }
}

extension WindowKind {
    /// Maps the endpoint's `kind` string. Unknown kinds are dropped in v1.
    init?(kindString: String, scopeModel: String?) {
        switch kindString {
        case "session": self = .session
        case "weekly_all": self = .weeklyAll
        case "weekly_scoped": self = .weeklyScoped(model: scopeModel ?? "scoped")
        default: return nil
        }
    }
}
