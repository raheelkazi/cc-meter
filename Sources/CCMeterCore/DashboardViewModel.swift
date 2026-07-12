import Foundation
import Combine

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

    public var compact: (percent: Int, color: MeterColor)? {
        [claude.compact, showsCodex ? codex.compact : nil]
            .compactMap { $0 }
            .max { $0.percent < $1.percent }
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
