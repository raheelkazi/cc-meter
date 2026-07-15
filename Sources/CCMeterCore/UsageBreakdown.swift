import Foundation

public enum UsageWindow: String, CaseIterable, Equatable {
    case fiveHour, sevenDay
    public var length: TimeInterval { self == .fiveHour ? 5 * 3600 : 7 * 24 * 3600 }
    public var bucketCount: Int { self == .fiveHour ? 5 : 7 }
    public var shortLabel: String { self == .fiveHour ? "5h" : "7d" }
}

public struct ProjectUsage: Equatable {
    public let project: String; public let tokens: Int; public let share: Double
    public init(project: String, tokens: Int, share: Double) {
        self.project = project; self.tokens = tokens; self.share = share
    }
}

public struct ModelUsage: Equatable {
    public let model: String; public let tokens: Int; public let share: Double
    public init(model: String, tokens: Int, share: Double) {
        self.model = model; self.tokens = tokens; self.share = share
    }
}

public struct UsageBucket: Equatable {
    public let index: Int; public let tokens: Int
    public init(index: Int, tokens: Int) { self.index = index; self.tokens = tokens }
}

public struct UsageBreakdown: Equatable {
    public let provider: UsageProvider
    public let window: UsageWindow
    public let totalTokens: Int
    public let notionalCost: Double?
    public let projects: [ProjectUsage]
    public let models: [ModelUsage]
    public let buckets: [UsageBucket]
    public init(provider: UsageProvider, window: UsageWindow, totalTokens: Int, notionalCost: Double?,
                projects: [ProjectUsage], models: [ModelUsage], buckets: [UsageBucket]) {
        self.provider = provider; self.window = window; self.totalTokens = totalTokens
        self.notionalCost = notionalCost; self.projects = projects; self.models = models; self.buckets = buckets
    }
}

public enum UsageBreakdownBuilder {
    public static func build(events: [UsageEvent], provider: UsageProvider, window: UsageWindow,
                             windowStart: Date, now: Date) -> UsageBreakdown {
        let inWindow = events.filter {
            $0.provider == provider && $0.at >= windowStart && $0.at <= now
        }
        let total = inWindow.reduce(0) { $0 + $1.tokens.total }

        var projectTokens: [String: Int] = [:]
        var modelTokens: [String: Int] = [:]
        var cost = 0.0
        var anyPriced = false
        var anyUnpriced = false
        for e in inWindow {
            projectTokens[e.project, default: 0] += e.tokens.total
            modelTokens[e.model, default: 0] += e.tokens.total
            if let c = ModelPriceTable.notionalCost(e.tokens, model: e.model) {
                cost += c; anyPriced = true
            } else {
                anyUnpriced = true
            }
        }

        let denom = Double(max(total, 1))
        let projects = projectTokens.sorted { $0.value > $1.value }
            .map { ProjectUsage(project: $0.key, tokens: $0.value, share: Double($0.value) / denom) }
        let models = modelTokens.sorted { $0.value > $1.value }
            .map { ModelUsage(model: $0.key, tokens: $0.value, share: Double($0.value) / denom) }

        let bucketSize = window.length / Double(window.bucketCount)
        var bucketTokens = Array(repeating: 0, count: window.bucketCount)
        for e in inWindow {
            let offset = e.at.timeIntervalSince(windowStart)
            let idx = min(window.bucketCount - 1, max(0, Int(offset / bucketSize)))
            bucketTokens[idx] += e.tokens.total
        }
        let buckets = bucketTokens.enumerated().map { UsageBucket(index: $0.offset, tokens: $0.element) }

        return UsageBreakdown(provider: provider, window: window, totalTokens: total,
                              notionalCost: (anyPriced && !anyUnpriced) ? cost : nil,
                              projects: projects, models: models, buckets: buckets)
    }
}
