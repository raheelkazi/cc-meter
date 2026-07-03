import SwiftUI
import AppKit
import CCMeterCore

struct PopoverView: View {
    @ObservedObject var viewModel: MeterViewModel

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

            Divider()
            HStack {
                Button("Refresh") { viewModel.refreshNow() }
                Spacer()
                if let updated = viewModel.lastUpdatedText {
                    Text(updated).font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
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
            Text(row.countdown).font(.caption2).foregroundStyle(.secondary)
        }
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
