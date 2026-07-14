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
    private let updates: AutoUpdateController

    init(loadPreferences: @escaping () -> Preferences,
         onChange: @escaping (Preferences) -> Void,
         updates: AutoUpdateController) {
        self.loadPreferences = loadPreferences
        self.onChange = onChange
        self.updates = updates
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentSize = NSSize(width: 420, height: 560)
        let view = SettingsView(initial: loadPreferences(), onChange: onChange, updates: updates)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "cc-meter Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 380, height: 420)

        // Pin the SwiftUI view to the content view's bounds via Auto Layout.
        // Handing SwiftUI to the window through `contentViewController` (or an
        // autoresizing hosting view) left the grouped Form offset with its
        // leading edge clipped; explicit edge constraints force it to fill the
        // content area exactly, with no negative origin or horizontal overflow.
        let hosting = NSHostingView(rootView: view)
        // Default sizingOptions add intrinsic-size constraints that fight the
        // edge pins below and displace the content; let the pins fully own layout.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = window.contentView!
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        window.setContentSize(contentSize)
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
