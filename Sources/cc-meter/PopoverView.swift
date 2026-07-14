import SwiftUI
import AppKit
import CCMeterCore

/// A flat list: one row per limit, and no hero unless a limit has earned one.
///
/// The panel's job is answering "am I about to hit a wall?", and almost always the answer
/// is no — so at rest it stays a plain list. A limit only gets a focal point when it goes
/// critical (`dashboard.alert`), which costs nothing in the state you are usually in.
struct PopoverView: View {
    @ObservedObject var dashboard: DashboardViewModel
    var onOpenSettings: () -> Void = {}

    private enum Metrics {
        static let barWidth: CGFloat = 64
        static let percentWidth: CGFloat = 34
        static let resetWidth: CGFloat = 48
        static let barHeight: CGFloat = 4
        /// Only a ceiling. The list is content-height until it exceeds this, then scrolls.
        static let maxListHeight: CGFloat = 420
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let alert = dashboard.alert {
                alertView(alert)
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    providerBlock(provider: .claude, viewModel: dashboard.claude)
                    if dashboard.showsCodex {
                        providerBlock(provider: .codex, viewModel: dashboard.codex)
                    }
                }
            }
            // A ScrollView is greedy along its scroll axis: given a 420pt ceiling it takes
            // all 420, which left a long gap under a short list. fixedSize pins it to its
            // content's height instead, and the ceiling only bites once the list is genuinely
            // taller than the cap — at which point it scrolls.
            .frame(maxHeight: Metrics.maxListHeight)
            .fixedSize(horizontal: false, vertical: true)

            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Text("Usage").font(.headline)
            Spacer()
            // A segmented control, not a bare word: as a plain label this toggle read as a
            // column header, which is why nobody could find it.
            Picker("", selection: modeBinding) {
                Text("Used").tag(DisplayMode.used)
                Text("Left").tag(DisplayMode.remaining)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show used or remaining")
        }
    }

    private var modeBinding: Binding<DisplayMode> {
        Binding(get: { dashboard.displayMode },
                set: { mode in
                    guard mode != dashboard.displayMode else { return }
                    dashboard.toggleMode()
                })
    }

    private var footer: some View {
        HStack {
            // One "updated" for the whole panel — it describes the fetch, not each provider.
            if let updated = dashboard.claude.lastUpdatedText {
                Text(updated).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Refresh") { dashboard.refreshNow() }
            Button("Settings…") { onOpenSettings() }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }

    // MARK: - Alert

    @ViewBuilder private func alertView(_ alert: UsageAlert) -> some View {
        HStack(spacing: 10) {
            Text("\(alert.percent)%")
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color(nsColor: .systemRed))

            VStack(alignment: .leading, spacing: 2) {
                Text("\(alert.provider.displayName) · \(alert.label)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(alert.countdown)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if alert.otherElevatedCount > 0 {
                Text("+\(alert.otherElevatedCount) near")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .systemRed).opacity(0.12))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .systemRed))
                .frame(width: 2.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(alert.provider.displayName) \(alert.label) at \(alert.percent) percent, \(alert.countdown)")
    }

    // MARK: - Provider

    @ViewBuilder private func providerBlock(provider: UsageProvider,
                                            viewModel: MeterViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: provider))
                    .frame(width: 6, height: 6)
                Text(provider.displayName.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 10)

            if let stale = viewModel.staleSnapshot {
                staleSnapshotView(stale)
            }

            providerContent(provider: provider, viewModel: viewModel)

            if let spend = viewModel.spend {
                spendView(spend)
            }
        }
    }

    private func color(for provider: UsageProvider) -> Color {
        switch provider {
        case .claude: return Color(nsColor: .systemOrange)
        case .codex: return Color(nsColor: .systemBlue)
        }
    }

    @ViewBuilder private func providerContent(provider: UsageProvider,
                                              viewModel: MeterViewModel) -> some View {
        switch viewModel.state {
        case .loading:
            Text("Loading…").font(.caption).foregroundStyle(.secondary)
        case .error(let err):
            errorView(err, provider: provider).font(.caption)
        case .ok:
            if viewModel.rows.isEmpty {
                Text("No active limits reported.").font(.caption).foregroundStyle(.secondary)
            } else {
                limits(viewModel.rows)

                // Forecasts are noise at 3%; they earn a line only when the pace actually
                // exhausts the window before it resets.
                ForEach(viewModel.rows.filter(\.burnUrgent)) { row in
                    if let forecast = row.forecast {
                        Text("\(row.compactLabel) · \(forecast.detailText)")
                            .font(.caption2)
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Limits, side by side

    /// A provider's limits on one line, divider-separated.
    ///
    /// Limits never re-sort by severity: the panel would rearrange under the cursor between
    /// refreshes, and the alert already does the pointing. If a provider ever reports enough
    /// windows that one line would overflow, the two-up grid takes over rather than clipping.
    @ViewBuilder private func limits(_ rows: [MeterRow]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { cellDivider }
                    cell(row)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading,
                      spacing: 3) {
                ForEach(rows) { cell($0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cellDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.28))
            .frame(width: 1, height: 11)
            .padding(.horizontal, 8)
    }

    @ViewBuilder private func cell(_ row: MeterRow) -> some View {
        HStack(spacing: 5) {
            Text(row.compactLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // The percentage IS the meter now that the bar is gone, so it carries the colour:
            // green under 50, amber from 50, red from 90. Severity is always read from used%,
            // so a low number in "Left" mode still shows red.
            Text("\(row.displayPercent)%")
                .font(.system(size: 12.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(row.color.swiftUIColor)

            Text(row.countdownShort)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .help(row.label)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.label), \(row.displayPercent) percent, \(row.countdown)")
    }

    @ViewBuilder private func bar(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.22))
                Capsule()
                    .fill(color)
                    // Clamp so an over-100% report cannot render wider than its track.
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
    }

    // MARK: - Supporting

    @ViewBuilder private func staleSnapshotView(_ stale: StaleSnapshot) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
                .font(.system(size: 11, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(stale.title).font(.caption2.weight(.semibold))
                Text(stale.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .systemOrange).opacity(0.10))
        )
    }

    @ViewBuilder private func spendView(_ spend: Spend) -> some View {
        HStack(spacing: 9) {
            Text("Spend").font(.system(size: 12.5))
            Spacer(minLength: 4)
            if let percent = spend.percent {
                bar(fraction: percent / 100, color: usageColor(percent: percent).swiftUIColor)
                    .frame(width: Metrics.barWidth, height: Metrics.barHeight)
            } else {
                Color.clear.frame(width: Metrics.barWidth, height: Metrics.barHeight)
            }
            Text(Self.money(spend.amount, currency: spend.currency)
                 + (spend.limit.map { " / " + Self.money($0, currency: spend.currency) } ?? ""))
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .frame(width: Metrics.percentWidth + Metrics.resetWidth + 9, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private static func money(_ amount: Double, currency: String) -> String {
        let symbol = currency.uppercased() == "USD" ? "$" : (currency + " ")
        return String(format: "\(symbol)%.2f", amount)
    }

    @ViewBuilder private func errorView(_ err: UsageError, provider: UsageProvider) -> some View {
        switch err {
        case .noCredentials:
            if provider == .claude {
                Text("Not signed in. Run `claude` to authenticate.").foregroundStyle(.secondary)
            } else {
                Text("Not signed in. Open Codex or run `codex login`.").foregroundStyle(.secondary)
            }
        case .unauthorized:
            if provider == .claude {
                Text("Session expired. Run `claude` to re-authenticate.").foregroundStyle(.secondary)
            } else {
                Text("Codex session expired. Open Codex or run `codex login`.").foregroundStyle(.secondary)
            }
        case .rateLimited:
            Text("Rate limited. Retrying shortly…").foregroundStyle(.secondary)
        case .network(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text("Network error. Retrying…").foregroundStyle(.secondary)
                Text(message).font(.caption2).foregroundStyle(.tertiary)
            }
        case .badResponse(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text("Unexpected response from the usage service.").foregroundStyle(.secondary)
                Text(message).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
