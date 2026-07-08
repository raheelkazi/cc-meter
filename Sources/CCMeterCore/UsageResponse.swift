import Foundation

/// Mirrors the JSON returned by /api/oauth/usage. Only fields we use are decoded;
/// unknown fields are ignored by Codable.
public struct UsageResponse: Decodable {
    public let limits: [Limit]?
    public let spend: SpendWire?
    public let extraUsage: SpendWire?

    enum CodingKeys: String, CodingKey {
        case limits, spend
        case extraUsage = "extra_usage"
    }

    /// `limits` is decoded strictly (a shape change there is a real problem worth
    /// surfacing), but `spend`/`extra_usage` are best-effort with an unverified
    /// live shape, so any mismatch there is swallowed to nil. Letting a spend
    /// decode error propagate would fail the whole response and blank the meter -
    /// which is exactly the regression this guards against.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limits = try container.decodeIfPresent([Limit].self, forKey: .limits)
        spend = (try? container.decodeIfPresent(SpendWire.self, forKey: .spend)) ?? nil
        extraUsage = (try? container.decodeIfPresent(SpendWire.self, forKey: .extraUsage)) ?? nil
    }

    /// Provisional spend shape. The live field layout is not verified (the design
    /// doc lists `spend`/`extra_usage` as reported-but-unused), so this decodes
    /// several plausible keys and yields nil rather than failing the whole
    /// response when spend is absent or shaped differently than expected.
    public struct SpendWire: Decodable {
        let amount: Double?
        let used: Double?
        let usedCents: Double?
        let limit: Double?
        let limitCents: Double?
        let currency: String?

        enum CodingKeys: String, CodingKey {
            case amount, used, limit, currency
            case usedCents = "used_cents"
            case limitCents = "limit_cents"
        }

        func toSpend() -> Spend? {
            guard let usedAmount = amount ?? used ?? usedCents.map({ $0 / 100 }) else { return nil }
            let limitAmount = limit ?? limitCents.map { $0 / 100 }
            return Spend(amount: usedAmount, limit: limitAmount, currency: currency ?? "USD")
        }
    }

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
        let mapped = (limits ?? []).compactMap { l -> UsageLimit? in
            guard let kind = WindowKind(kindString: l.kind, scopeModel: l.scope?.model?.displayName),
                  let resetsRaw = l.resetsAt,
                  let resetsAt = ISODate.parse(resetsRaw) else { return nil }
            return UsageLimit(kind: kind,
                              percent: l.percent,
                              resetsAt: resetsAt,
                              isActive: l.isActive ?? false)
        }
        return Usage(limits: mapped, spend: (spend ?? extraUsage)?.toSpend(), fetchedAt: now)
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
