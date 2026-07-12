import Foundation

public struct CodexProtocolError: Error, Equatable, Decodable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public enum CodexResponseError: Error, Equatable {
    case missingResult
}

struct CodexConfigResponse: Decodable {
    let result: ResultPayload?

    struct ResultPayload: Decodable {
        let config: Config?
    }

    struct Config: Decodable {
        let model: String?
    }

    var activeModelID: String? {
        result?.config?.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

struct CodexModelListResponse: Decodable {
    let result: ResultPayload?

    struct ResultPayload: Decodable {
        let data: [Model]
    }

    struct Model: Decodable {
        let model: String
        let displayName: String
    }

    func displayName(for modelID: String) -> String? {
        result?.data.first { $0.model == modelID }?.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

public struct CodexRateLimitsResponse: Decodable {
    public let id: Int?
    public let result: ResultPayload?
    public let error: CodexProtocolError?

    public struct ResultPayload: Decodable {
        let rateLimits: RateLimitGroup?
        let rateLimitsByLimitId: [String: RateLimitGroup]?

        enum CodingKeys: String, CodingKey {
            case rateLimits, rateLimitsByLimitId
        }

        var orderedGroups: [(id: String, group: RateLimitGroup)] {
            if let byID = rateLimitsByLimitId, !byID.isEmpty {
                return byID.keys.sorted().compactMap { key in
                    byID[key].map { (key, $0) }
                }
            }
            guard let rateLimits else { return [] }
            return [(rateLimits.limitId ?? "codex", rateLimits)]
        }
    }

    public struct RateLimitGroup: Decodable {
        let limitId: String?
        let limitName: String?
        let primary: Window?
        let secondary: Window?
    }

    public struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int
        let resetsAt: TimeInterval
    }

    public func toUsage(now: Date, unnamedCodexModelName: String? = nil) throws -> Usage {
        if let error { throw error }
        guard let result else { throw CodexResponseError.missingResult }

        struct Candidate {
            let groupID: String
            let identity: String
            let baseLabel: String
            let window: Window
        }

        var candidates: [Candidate] = []
        for (dictionaryID, group) in result.orderedGroups {
            let groupID = group.limitId ?? dictionaryID
            for (role, optionalWindow) in [("primary", group.primary),
                                           ("secondary", group.secondary)] {
                guard let window = optionalWindow else { continue }
                let duration = Self.durationLabel(minutes: window.windowDurationMins)
                let explicitName = group.limitName?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                let fallbackName = groupID == "codex"
                    ? unnamedCodexModelName?
                        .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    : nil
                let name = explicitName ?? fallbackName
                let label = name.flatMap { $0.isEmpty ? nil : "\(duration) (\($0))" } ?? duration
                candidates.append(Candidate(groupID: groupID,
                                            identity: "codex:\(groupID):\(role)",
                                            baseLabel: label,
                                            window: window))
            }
        }

        let labelCounts = Dictionary(grouping: candidates, by: \.baseLabel).mapValues(\.count)
        let limits = candidates.map { candidate -> UsageLimit in
            let duplicate = (labelCounts[candidate.baseLabel] ?? 0) > 1
            let label = duplicate
                ? "\(candidate.baseLabel) [\(candidate.groupID)]"
                : candidate.baseLabel
            return UsageLimit(kind: .named(id: candidate.identity,
                                           label: label,
                                           isSession: candidate.window.windowDurationMins == 300),
                              percent: candidate.window.usedPercent,
                              resetsAt: Date(timeIntervalSince1970: candidate.window.resetsAt),
                              isActive: true)
        }
        return Usage(limits: limits, fetchedAt: now)
    }

    private static func durationLabel(minutes: Int) -> String {
        let week = 7 * 24 * 60
        let day = 24 * 60
        if minutes > 0, minutes.isMultiple(of: week) {
            return "\(minutes / day)-day"
        }
        if minutes > 0, minutes.isMultiple(of: day) {
            return "\(minutes / day)-day"
        }
        if minutes > 0, minutes.isMultiple(of: 60) {
            return "\(minutes / 60)-hour"
        }
        return "\(minutes)-minute"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
