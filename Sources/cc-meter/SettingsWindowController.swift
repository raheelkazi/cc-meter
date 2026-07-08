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

        let contentSize = NSSize(width: 420, height: 560)
        let view = SettingsView(initial: loadPreferences(), onChange: onChange)
        let hosting = NSHostingController(rootView: view)
        hosting.preferredContentSize = contentSize

        // Build the window with an explicit content rect and styleMask up front.
        // Setting styleMask after `NSWindow(contentViewController:)` was resizing
        // the frame out from under the hosted view, clipping the form.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "cc-meter Settings"
        window.isReleasedWhenClosed = false
        window.setContentSize(contentSize)
        window.contentMinSize = NSSize(width: 380, height: 420)
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
