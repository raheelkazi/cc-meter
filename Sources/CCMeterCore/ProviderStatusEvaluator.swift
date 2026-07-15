import Foundation

/// Derives a single `ProviderStatus` from a provider's Statuspage summary, filtered to the
/// components that provider actually depends on. Conservative: any active incident with impact
/// >= minor counts, and component status gives the precise signal when no incident is present.
public enum ProviderStatusEvaluator {
    private static func relevantSubstrings(for provider: UsageProvider) -> [String] {
        switch provider {
        case .claude: return ["claude code", "claude api"]
        case .codex: return ["codex"]
        }
    }

    private static func level(componentStatus: String) -> StatusLevel {
        switch componentStatus {
        case "degraded_performance", "partial_outage": return .degraded
        case "major_outage": return .major
        default: return .ok   // operational, under_maintenance, or anything unknown
        }
    }

    private static func level(impact: String) -> StatusLevel {
        switch impact {
        case "minor": return .degraded
        case "major", "critical": return .major
        default: return .ok   // none, or anything unknown
        }
    }

    public static func evaluate(_ summary: StatusSummary, provider: UsageProvider, statusURL: URL) -> ProviderStatus {
        let needles = relevantSubstrings(for: provider)
        let matched = summary.components.filter { comp in
            let lower = comp.name.lowercased()
            return needles.contains { lower.contains($0) }
        }

        // Component signal: worst matched component, or - if nothing matched - the overall indicator.
        let componentLevel: StatusLevel
        if matched.isEmpty {
            componentLevel = level(impact: summary.status.indicator)   // indicator vocab == impact vocab
        } else {
            componentLevel = matched.map { level(componentStatus: $0.status) }.max() ?? .ok
        }

        // Incident signal: worst active incident (summary.json only lists unresolved incidents).
        let worstIncident = summary.incidents.max { level(impact: $0.impact) < level(impact: $1.impact) }
        let incidentLevel = worstIncident.map { level(impact: $0.impact) } ?? .ok

        let overall = max(componentLevel, incidentLevel)
        guard overall > .ok else {
            return ProviderStatus(provider: provider, level: .ok, url: statusURL)
        }

        if let incident = worstIncident, level(impact: incident.impact) > .ok {
            let link = incident.shortlink.flatMap(URL.init(string:)) ?? statusURL
            return ProviderStatus(provider: provider, level: overall, headline: incident.name,
                                  detail: summary.status.description, url: link)
        }
        // Degraded via component status, no incident object.
        let worstComp = matched.max { level(componentStatus: $0.status) < level(componentStatus: $1.status) }
        return ProviderStatus(provider: provider, level: overall,
                              headline: worstComp.map { "\($0.name) \($0.status.replacingOccurrences(of: "_", with: " "))" },
                              detail: summary.status.description, url: statusURL)
    }
}
