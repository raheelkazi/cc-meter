import SwiftUI
import CCMeterCore

/// Preferences form. Holds a working copy and pushes the whole `Preferences`
/// value up on every edit, so the app can persist + apply changes live.
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
        Form {
            Section("Polling") {
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

            Section("Notifications") {
                Toggle("Enable usage notifications", isOn: $prefs.notificationsEnabled)
                if prefs.notificationsEnabled {
                    Text("Alert when a limit crosses:")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Self.candidateThresholds, id: \.self) { t in
                        Toggle("\(Int(t))%", isOn: thresholdBinding(t))
                            .toggleStyle(.checkbox)
                    }
                    Toggle("Heads-up before the 5-hour window resets",
                           isOn: headsUpBinding)
                    if prefs.sessionResetHeadsUpMinutes != nil {
                        Stepper("\(prefs.sessionResetHeadsUpMinutes ?? 10) min before",
                                value: headsUpMinutesBinding, in: 1...60, step: 1)
                    }
                }
            }

            Section("Display") {
                Toggle("Show remaining instead of used by default",
                       isOn: $prefs.defaultShowRemaining)
                Toggle("Record usage history (trend sparklines)",
                       isOn: $prefs.historyEnabled)
            }

            Section("Startup") {
                Toggle("Launch cc-meter at login", isOn: $prefs.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 480)
        .onChange(of: prefs) { newValue in onChange(newValue) }
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
