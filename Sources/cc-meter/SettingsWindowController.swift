import AppKit
import SwiftUI
import CCMeterCore

/// Presents the SwiftUI `SettingsView` in a standalone window. A menu bar
/// accessory app has no default window, so we create and retain one on demand.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let loadPreferences: () -> Preferences
    private let onChange: (Preferences) -> Void

    init(loadPreferences: @escaping () -> Preferences,
         onChange: @escaping (Preferences) -> Void) {
        self.loadPreferences = loadPreferences
        self.onChange = onChange
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(initial: loadPreferences(), onChange: onChange)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "cc-meter Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
