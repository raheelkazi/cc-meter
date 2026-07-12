import Foundation

public struct MenuBarTitleSegment: Equatable {
    public let text: String
    public let color: MeterColor?

    public init(text: String, color: MeterColor? = nil) {
        self.text = text
        self.color = color
    }
}

public struct MenuBarPresentation: Equatable {
    public let segments: [MenuBarTitleSegment]
    public let tooltip: String?

    public var plainTitle: String { segments.map(\.text).joined() }

    public static func make(summaries: [ProviderCompactSummary],
                            isLoading: Bool,
                            hasError: Bool) -> MenuBarPresentation {
        guard !summaries.isEmpty else {
            let title = isLoading ? "CC ..." : (hasError ? "CC !" : "CC")
            return MenuBarPresentation(segments: [MenuBarTitleSegment(text: title)],
                                       tooltip: nil)
        }

        let tooltip = summaries
            .map { "\($0.provider.displayName) \($0.percent)% used" }
            .joined(separator: " · ")
        if summaries.count == 1, let summary = summaries.first {
            return MenuBarPresentation(segments: [
                MenuBarTitleSegment(text: "● ", color: summary.color),
                MenuBarTitleSegment(text: "\(summary.percent)%")
            ], tooltip: tooltip)
        }

        var segments: [MenuBarTitleSegment] = []
        for (index, summary) in summaries.enumerated() {
            if index > 0 { segments.append(MenuBarTitleSegment(text: " · ")) }
            segments.append(MenuBarTitleSegment(text: "\(abbreviation(for: summary.provider)) "))
            segments.append(MenuBarTitleSegment(text: "●", color: summary.color))
            segments.append(MenuBarTitleSegment(text: " \(summary.percent)%"))
        }
        return MenuBarPresentation(segments: segments, tooltip: tooltip)
    }

    private static func abbreviation(for provider: UsageProvider) -> String {
        switch provider {
        case .claude: return "Cl"
        case .codex: return "Cx"
        }
    }
}
