import AppKit
import SwiftUI
import Combine
import CCMeterCore

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let dashboard: DashboardViewModel
    private let onOpenSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(dashboard: DashboardViewModel, onOpenSettings: @escaping () -> Void = {}) {
        self.dashboard = dashboard
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    func install() {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 560)
        let root = PopoverView(dashboard: dashboard, onOpenSettings: { [weak self] in
            self?.popover.performClose(nil)
            self?.onOpenSettings()
        })
        popover.contentViewController = NSHostingController(rootView: root)

        // Re-render the status title on any published change.
        dashboard.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateTitle() }
            .store(in: &cancellables)

        updateTitle()
    }

    private func updateTitle() {
        statusItem.button?.attributedTitle = Self.titleString(for: dashboard)
    }

    static func titleString(for dashboard: DashboardViewModel) -> NSAttributedString {
        if let compact = dashboard.compact {
            let result = NSMutableAttributedString(
                string: "\u{25CF} ",
                attributes: [.foregroundColor: compact.color.nsColor]
            )
            result.append(NSAttributedString(string: "\(compact.percent)%"))
            return result
        }
        if dashboard.isLoading { return NSAttributedString(string: "CC ...") }
        if dashboard.hasError { return NSAttributedString(string: "CC !") }
        return NSAttributedString(string: "CC")
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            pinPopover(to: button)
            DispatchQueue.main.async { [weak self, weak button] in
                guard let self, let button else { return }
                self.pinPopover(to: button)
            }
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func pinPopover(to button: NSStatusBarButton) {
        guard let window = popover.contentViewController?.view.window,
              let buttonWindow = button.window else { return }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonFrame = buttonWindow.convertToScreen(buttonRectInWindow)
        let screen = buttonWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame
        let gap: CGFloat = 3

        var frame = window.frame
        frame.origin.y = buttonFrame.minY - gap - frame.height

        if let visibleFrame {
            let inset: CGFloat = 4
            frame.origin.x = min(max(frame.origin.x, visibleFrame.minX + inset),
                                 visibleFrame.maxX - frame.width - inset)
            frame.origin.y = max(frame.origin.y, visibleFrame.minY + inset)
        }

        window.setFrame(frame, display: true)
    }
}
