import SwiftUI
import AppKit
import CCMeterCore

struct PopoverView: View {
    @ObservedObject var viewModel: MeterViewModel
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude Code Usage").font(.headline)
                Spacer()
                Button(viewModel.displayMode == .used ? "Used" : "Left") {
                    viewModel.toggleMode()
                }
                .buttonStyle(.borderless)
                .help("Toggle used vs remaining")
            }

            content

            if let spend = viewModel.spend {
                Divider()
                spendView(spend)
            }

            Divider()
            HStack {
                Button("Refresh") { viewModel.refreshNow() }
                Spacer()
                if let updated = viewModel.lastUpdatedText {
                    Text(updated).font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
                Button("Settings…") { onOpenSettings() }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 300)
    }

    @ViewBuilder private var content: some View {
        switch viewModel.state {
        case .loading:
            Text("Loading...").foregroundStyle(.secondary)
        case .error(let err):
            errorView(err)
        case .ok:
            if viewModel.rows.isEmpty {
                Text("No active limits reported.").foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.rows) { rowView($0) }
            }
        }
    }

    @ViewBuilder private func rowView(_ row: MeterRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.label).font(.subheadline)
                Spacer()
                Text("\(row.displayPercent)%").font(.subheadline).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(row.color.swiftUIColor)
                        // Clamp to [0, 1] so an over-100% usage report cannot
                        // render the fill wider than its track.
                        .frame(width: geo.size.width * min(1, max(0, row.barFraction)))
                }
            }
            .frame(height: 6)
            HStack(spacing: 6) {
                Text(row.countdown).font(.caption2).foregroundStyle(.secondary)
                if let burn = row.burn {
                    Text("·").font(.caption2).foregroundStyle(.tertiary)
                    Text(burn)
                        .font(.caption2)
                        .foregroundStyle(row.burnUrgent ? Color(nsColor: .systemRed) : .secondary)
                }
                Spacer()
                if row.series.count > 1 {
                    Sparkline(values: row.series, color: row.color.swiftUIColor)
                        .frame(width: 44, height: 12)
                }
            }
        }
    }

    @ViewBuilder private func spendView(_ spend: Spend) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Spend").font(.subheadline)
                Spacer()
                Text(Self.money(spend.amount, currency: spend.currency)
                     + (spend.limit.map { " / " + Self.money($0, currency: spend.currency) } ?? ""))
                    .font(.subheadline).monospacedDigit()
            }
            if let percent = spend.percent {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(usageColor(percent: percent).swiftUIColor)
                            .frame(width: geo.size.width * min(1, max(0, percent / 100)))
                    }
                }
                .frame(height: 6)
            }
        }
    }

    private static func money(_ amount: Double, currency: String) -> String {
        let symbol = currency.uppercased() == "USD" ? "$" : (currency + " ")
        return String(format: "\(symbol)%.2f", amount)
    }

    @ViewBuilder private func errorView(_ err: UsageError) -> some View {
        switch err {
        case .noCredentials:
            Text("Not signed in. Run `claude` to authenticate.").foregroundStyle(.secondary)
        case .unauthorized:
            Text("Session expired. Run `claude` to re-authenticate.").foregroundStyle(.secondary)
        case .rateLimited:
            Text("Rate limited. Retrying shortly...").foregroundStyle(.secondary)
        case .network(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text("Network error. Retrying...").foregroundStyle(.secondary)
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

/// Dependency-free sparkline: normalizes `values` to the view height and strokes
/// a polyline. Avoids pulling in the Charts framework for a 44pt trend line.
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1 else { return }
                let maxV = values.max() ?? 1
                let minV = values.min() ?? 0
                let span = max(1, maxV - minV)
                let stepX = geo.size.width / CGFloat(values.count - 1)
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    // Invert Y so higher usage sits higher in the sparkline.
                    let y = geo.size.height * (1 - CGFloat((v - minV) / span))
                    let point = CGPoint(x: x, y: y)
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
    }
}
