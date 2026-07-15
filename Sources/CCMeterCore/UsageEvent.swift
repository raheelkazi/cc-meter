import Foundation

/// Token counts for one model turn. `reasoning` is Codex-only; Claude leaves it 0.
public struct TokenCounts: Equatable, Codable {
    public var input: Int
    public var output: Int
    public var cacheCreation: Int
    public var cacheRead: Int
    public var reasoning: Int

    public init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0,
                cacheRead: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.reasoning = reasoning
    }

    public var total: Int { input + output + cacheCreation + cacheRead } // reasoning excluded (subset of output)

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input,
                    output: lhs.output + rhs.output,
                    cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
                    cacheRead: lhs.cacheRead + rhs.cacheRead,
                    reasoning: lhs.reasoning + rhs.reasoning)
    }
}

/// One deduplicated model turn parsed from a local log, attributed to a project and model.
public struct UsageEvent: Equatable, Codable {
    public let provider: UsageProvider
    public let at: Date
    public let project: String
    public let model: String
    public let tokens: TokenCounts
    /// Stable identity used to drop the ~2x duplicates Claude writes and to survive re-parses.
    public let dedupKey: String

    public init(provider: UsageProvider, at: Date, project: String,
                model: String, tokens: TokenCounts, dedupKey: String) {
        self.provider = provider
        self.at = at
        self.project = project
        self.model = model
        self.tokens = tokens
        self.dedupKey = dedupKey
    }
}
