import Foundation

/// USD per single token, by token class.
public struct ModelPrice: Equatable {
    public let input: Double
    public let output: Double
    public let cacheWrite: Double
    public let cacheRead: Double
    public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }
}

/// Embedded, approximate public list prices used only for the "≈ $X on API rates" estimate.
/// These are notional for subscription users. Update the values and `pricesAsOf` when rates change.
/// Codex model names (e.g. gpt-5.6-sol) are intentionally absent - unknown => no dollar figure.
public enum ModelPriceTable {
    public static let pricesAsOf = "2026-07-15"

    private static let perMillion: [(match: String, price: ModelPrice)] = [
        ("opus",   ModelPrice(input: 15.0, output: 75.0, cacheWrite: 18.75, cacheRead: 1.50)),
        ("sonnet", ModelPrice(input: 3.0,  output: 15.0, cacheWrite: 3.75,  cacheRead: 0.30)),
        ("haiku",  ModelPrice(input: 0.80, output: 4.0,  cacheWrite: 1.0,   cacheRead: 0.08)),
    ]

    public static func price(for model: String) -> ModelPrice? {
        let lower = model.lowercased()
        guard let entry = perMillion.first(where: { lower.contains($0.match) }) else { return nil }
        // Convert per-million to per-token.
        let p = entry.price
        return ModelPrice(input: p.input / 1_000_000, output: p.output / 1_000_000,
                          cacheWrite: p.cacheWrite / 1_000_000, cacheRead: p.cacheRead / 1_000_000)
    }

    public static func notionalCost(_ tokens: TokenCounts, model: String) -> Double? {
        guard let p = price(for: model) else { return nil }
        return Double(tokens.input) * p.input
            + Double(tokens.output) * p.output
            + Double(tokens.cacheCreation) * p.cacheWrite
            + Double(tokens.cacheRead) * p.cacheRead
    }
}
