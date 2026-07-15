import SwiftUI
import CCMeterCore

/// The Usage tab: tokens consumed in the current window, by project and model, with a small
/// hand-drawn bar chart and a notional dollar estimate. Provider- and window-scoped.
struct UsageTabView: View {
    @ObservedObject var model: UsageDetailViewModel
    let showsCodex: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            if !model.logsPresent(model.provider) {
                Text("No \(model.provider.displayName) usage logs found.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !model.hasIndexed {
                Text("Reading usage logs…").font(.caption).foregroundStyle(.secondary)
            } else if let b = model.breakdown {
                chart(b)
                if b.totalTokens == 0 {
                    Text("No usage recorded in this window yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    projectTable(b)
                    modelSplit(b)
                    costLine(b)
                }
            }
        }
        .onAppear { model.onAppear() }
    }

    private var controls: some View {
        HStack {
            if showsCodex {
                Picker("", selection: $model.provider) {
                    Text("Claude").tag(UsageProvider.claude)
                    Text("Codex").tag(UsageProvider.codex)
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            Spacer()
            Picker("", selection: $model.window) {
                Text("5h").tag(UsageWindow.fiveHour)
                Text("7d").tag(UsageWindow.sevenDay)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private func chart(_ b: UsageBreakdown) -> some View {
        let peak = max(1, b.buckets.map(\.tokens).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(b.buckets, id: \.index) { bucket in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: .systemBlue).opacity(0.55))
                    .frame(height: max(2, 34 * CGFloat(bucket.tokens) / CGFloat(peak)))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 34)
        .accessibilityLabel("\(Self.compact(b.totalTokens)) tokens this window")
    }

    private func projectTable(_ b: UsageBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(b.projects.prefix(5), id: \.project) { row in
                HStack {
                    Text(row.project).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Self.compact(row.tokens)).font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("\(Int((row.share * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    private func modelSplit(_ b: UsageBreakdown) -> some View {
        HStack(spacing: 8) {
            ForEach(b.models.prefix(3), id: \.model) { m in
                Text("\(shortModelToken(m.model)) \(Int((m.share * 100).rounded()))%")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func costLine(_ b: UsageBreakdown) -> some View {
        Text(b.notionalCost.map { "≈ \(Self.money($0)) on API rates" } ?? "≈ cost n/a (unpriced model)")
            .font(.caption2).foregroundStyle(.tertiary)
            .help("Estimate at public API prices as of \(ModelPriceTable.pricesAsOf). Notional on a subscription; token share approximates quota share. Unpriced models (e.g. Codex) show n/a.")
    }

    private static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private static func money(_ amount: Double) -> String { String(format: "$%.2f", amount) }
}
