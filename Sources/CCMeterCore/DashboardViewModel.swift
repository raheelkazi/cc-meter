import Foundation
import Combine

/// A limit that has crossed into `.red`, surfaced above the flat list.
public struct UsageAlert: Equatable {
    public let provider: UsageProvider
    public let label: String
    /// Follows the Used/Left toggle, like every row.
    public let percent: Int
    public let countdown: String
    /// Other limits also above green, counted rather than stacked into more banners.
    public let otherElevatedCount: Int

    public init(provider: UsageProvider, label: String, percent: Int,
                countdown: String, otherElevatedCount: Int) {
        self.provider = provider
        self.label = label
        self.percent = percent
        self.countdown = countdown
        self.otherElevatedCount = otherElevatedCount
    }
}

public struct ProviderCompactSummary: Equatable {
    public let provider: UsageProvider
    public let percent: Int
    public let color: MeterColor

    public init(provider: UsageProvider, percent: Int, color: MeterColor) {
        self.provider = provider
        self.percent = percent
        self.color = color
    }
}

@MainActor
public final class DashboardViewModel: ObservableObject {
    public let claude: MeterViewModel
    public let codex: MeterViewModel
    @Published public private(set) var showsCodex = false

    private var cancellables = Set<AnyCancellable>()

    public init(claude: MeterViewModel, codex: MeterViewModel) {
        self.claude = claude
        self.codex = codex

        claude.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        codex.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        codex.$state
            .sink { [weak self] state in self?.reconcileCodexVisibility(state) }
            .store(in: &cancellables)
    }

    public var displayMode: DisplayMode { claude.displayMode }

    public var compactProviders: [ProviderCompactSummary] {
        var summaries: [ProviderCompactSummary] = []
        if let compact = claude.compact {
            summaries.append(ProviderCompactSummary(provider: .claude,
                                                    percent: compact.percent,
                                                    color: compact.color))
        }
        if showsCodex, let compact = codex.compact {
            summaries.append(ProviderCompactSummary(provider: .codex,
                                                    percent: compact.percent,
                                                    color: compact.color))
        }
        return summaries
    }

    public var compact: (percent: Int, color: MeterColor)? {
        compactProviders
            .max { $0.percent < $1.percent }
            .map { (percent: $0.percent, color: $0.color) }
    }

    /// The one limit worth interrupting for, or nil when nothing is.
    ///
    /// The popover is a flat list with no hero, so a limit in trouble has to announce
    /// itself. "Trouble" is the app's existing `.red` severity — reusing `usageColor`
    /// rather than adding a second threshold that could drift away from the bars.
    public var alert: UsageAlert? {
        let meters = showsCodex ? [claude, codex] : [claude]
        let entries = meters.flatMap { meter in
            meter.rows.map { (provider: meter.provider, row: $0) }
        }

        // Rank on used%, never on the displayed number: 6% *left* is still critical.
        guard let worst = entries
            .filter({ $0.row.color == .red })
            .max(by: { $0.row.usedPercent < $1.row.usedPercent })
        else { return nil }

        let others = entries.filter {
            !($0.provider == worst.provider && $0.row.id == worst.row.id)
                && $0.row.color != .green
        }

        return UsageAlert(provider: worst.provider,
                          label: worst.row.label,
                          percent: worst.row.displayPercent,
                          countdown: worst.row.countdown,
                          otherElevatedCount: others.count)
    }

    public var isLoading: Bool {
        guard compact == nil else { return false }
        if case .loading = claude.state { return true }
        if showsCodex, case .loading = codex.state { return true }
        return false
    }

    public var hasError: Bool {
        guard compact == nil else { return false }
        if case .error = claude.state { return true }
        if showsCodex, case .error = codex.state { return true }
        return false
    }

    public func start() {
        claude.start()
        codex.start()
    }

    public func refreshNow() {
        Task { @MainActor in await self.refresh() }
    }

    public func refresh() async {
        async let claudeRefresh: Void = claude.refresh()
        async let codexRefresh: Void = codex.refresh()
        _ = await (claudeRefresh, codexRefresh)
    }

    public func toggleMode() {
        claude.toggleMode()
        codex.toggleMode()
    }

    public func apply(_ preferences: Preferences) {
        claude.apply(preferences)
        codex.apply(preferences)
    }

    private func reconcileCodexVisibility(_ state: MeterState) {
        switch state {
        case .ok:
            showsCodex = true
        case .error(.noCredentials), .error(.unauthorized):
            showsCodex = false
        case .loading, .error:
            break
        }
    }
}
