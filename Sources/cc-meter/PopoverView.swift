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

            if let stale = viewModel.staleSnapshot {
                staleSnapshotView(stale)
            }

            if let hero = viewModel.hero {
                heroView(hero)
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
        .frame(width: 340)
    }

    @ViewBuilder private var content: some View {
        switch viewModel.state {
        case .loading:
            Text("Loading...").foregroundStyle(.secondary)
        case .error(let err):
            errorView(err)
        case .ok:
            let rows = viewModel.detailRows
            if viewModel.rows.isEmpty {
                Text("No active limits reported.").foregroundStyle(.secondary)
            } else {
                ForEach(rows) { rowView($0) }
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
            HStack {
                Text(row.countdown).font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            if let forecast = row.forecast {
                forecastView(forecast)
            }
        }
    }

    @ViewBuilder private func heroView(_ hero: MeterHero) -> some View {
        HStack(spacing: 12) {
            ZStack {
                MeterRing(fraction: hero.fraction,
                          color: hero.color.swiftUIColor,
                          trackColor: Color.gray.opacity(0.18))
                Text("\(hero.percent)%")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 5) {
                Text(hero.status)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(heroDetail(hero))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let forecast = hero.forecast {
                    forecastPills(forecast)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hero.color.swiftUIColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(hero.color.swiftUIColor.opacity(0.25), lineWidth: 1)
        )
    }

    private func heroDetail(_ hero: MeterHero) -> String {
        if let forecast = hero.forecast {
            return "At current pace, \(forecast.limitText.lowercased()). \(hero.countdown)."
        }
        return hero.countdown
    }

    @ViewBuilder private func forecastView(_ forecast: BurnForecast) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            forecastPills(forecast)
            Text(forecast.detailText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func forecastPills(_ forecast: BurnForecast) -> some View {
        HStack(spacing: 6) {
            forecastPill(forecast.rateText,
                         foreground: Color.secondary,
                         background: Color.gray.opacity(0.12))
            forecastPill(forecast.limitText,
                         foreground: forecast.isUrgent ? Color(nsColor: .systemRed) : Color.secondary,
                         background: (forecast.isUrgent ? Color(nsColor: .systemRed) : Color.gray).opacity(0.12))
        }
    }

    @ViewBuilder private func forecastPill(_ text: String,
                                           foreground: Color,
                                           background: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(background))
    }

    @ViewBuilder private func staleSnapshotView(_ stale: StaleSnapshot) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(stale.title)
                    .font(.caption.weight(.semibold))
                Text(stale.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .systemOrange).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .systemOrange).opacity(0.24), lineWidth: 1)
        )
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

private struct MeterRing: View {
    let fraction: Double
    let color: Color
    let trackColor: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
