import SwiftUI
import CCMeterCore

/// Preferences pane. Holds a working copy and pushes the whole `Preferences`
/// value up on every edit, so the app can persist + apply changes live.
///
/// This is a hand-rolled layout rather than a SwiftUI `Form`: a grouped `Form`
/// is `NSTableView`-backed and, when hosted directly in a plain `NSWindow`
/// (no enclosing scroll/safe-area container), draws its cell content with a
/// negative leading inset that clips the first ~15px of every row. A plain
/// `ScrollView`/`VStack` hosts correctly, so we build the sectioned look
/// ourselves with styled "cards".
struct SettingsView: View {
    @State private var prefs: Preferences
    private let onChange: (Preferences) -> Void

    /// Threshold seams offered as toggles; arbitrary values are preserved if
    /// already stored but the common ones are one click away.
    private static let candidateThresholds: [Double] = [50, 80, 90, 95, 100]

    init(initial: Preferences, onChange: @escaping (Preferences) -> Void) {
        _prefs = State(initialValue: initial)
        self.onChange = onChange
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                card("Polling") {
                    HStack {
                        Text("Refresh every")
                        Spacer()
                        Stepper("\(Int(prefs.pollInterval))s",
                                value: $prefs.pollInterval,
                                in: Preferences.minPollInterval...600,
                                step: 15)
                            .fixedSize()
                    }
                }

                card("Notifications") {
                    Toggle("Enable usage notifications", isOn: $prefs.notificationsEnabled)
                    if prefs.notificationsEnabled {
                        Text("Alert when a limit crosses:")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Self.candidateThresholds, id: \.self) { t in
                            Toggle("\(Int(t))%", isOn: thresholdBinding(t))
                                .toggleStyle(.checkbox)
                        }
                        Divider()
                        Toggle("Heads-up before the 5-hour window resets",
                               isOn: headsUpBinding)
                        if prefs.sessionResetHeadsUpMinutes != nil {
                            HStack {
                                Text("Lead time")
                                Spacer()
                                Stepper("\(prefs.sessionResetHeadsUpMinutes ?? 10) min before",
                                        value: headsUpMinutesBinding, in: 1...60, step: 1)
                                    .fixedSize()
                            }
                        }
                    }
                }

                card("Display") {
                    Toggle("Show remaining instead of used by default",
                           isOn: $prefs.defaultShowRemaining)
                    Toggle("Record usage history (trend sparklines)",
                           isOn: $prefs.historyEnabled)
                }

                card("Startup") {
                    Toggle("Launch cc-meter at login", isOn: $prefs.launchAtLogin)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: prefs) { newValue in onChange(newValue) }
    }

    /// A titled section rendered as a rounded card, mimicking a grouped form
    /// section without the hosted-`Form` clipping bug.
    @ViewBuilder
    private func card<Content: View>(_ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    private func thresholdBinding(_ threshold: Double) -> Binding<Bool> {
        Binding(
            get: { prefs.notificationThresholds.contains(threshold) },
            set: { isOn in
                var set = Set(prefs.notificationThresholds)
                if isOn { set.insert(threshold) } else { set.remove(threshold) }
                prefs.notificationThresholds = set.sorted()
            }
        )
    }

    private var headsUpBinding: Binding<Bool> {
        Binding(
            get: { prefs.sessionResetHeadsUpMinutes != nil },
            set: { isOn in prefs.sessionResetHeadsUpMinutes = isOn ? 10 : nil }
        )
    }

    private var headsUpMinutesBinding: Binding<Int> {
        Binding(
            get: { prefs.sessionResetHeadsUpMinutes ?? 10 },
            set: { prefs.sessionResetHeadsUpMinutes = $0 }
        )
    }
}
