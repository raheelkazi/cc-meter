import AppKit

// Top-level code in main.swift runs on the process's main thread, but is not
// implicitly MainActor-isolated to the compiler. AppDelegate/MenuBarController
// are @MainActor per the brief's design, so assert the isolation we already
// hold rather than changing that design.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // menu bar only, no dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
