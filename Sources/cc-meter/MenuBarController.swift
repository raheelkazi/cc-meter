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
    private let usageModel: UsageDetailViewModel?
    private var cancellables = Set<AnyCancellable>()

    init(dashboard: DashboardViewModel, usageModel: UsageDetailViewModel? = nil,
         onOpenSettings: @escaping () -> Void = {}) {
        self.dashboard = dashboard
        self.usageModel = usageModel
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    func install() {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        let root = PopoverView(dashboard: dashboard, usageModel: usageModel, onOpenSettings: { [weak self] in
            self?.popover.performClose(nil)
            self?.onOpenSettings()
        })
        let controller = NSHostingController(rootView: root)
        // The panel is now short at rest and grows only when a limit goes critical, so its
        // height has to follow the content. A pinned contentSize left ~250pt of dead space
        // under the list; .preferredContentSize keeps the popover fitted as the list changes.
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller

        // Re-render the status title on any published change.
        dashboard.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                DispatchQueue.main.async { [weak self] in self?.updateTitle() }
            }
            .store(in: &cancellables)

        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let presentation = MenuBarPresentation.make(
            summaries: dashboard.compactProviders,
            isLoading: dashboard.isLoading,
            hasError: dashboard.hasError,
            statuses: dashboard.statusLevels
        )
        button.attributedTitle = Self.titleString(for: presentation)
        button.toolTip = presentation.tooltip
    }

    static func titleString(for presentation: MenuBarPresentation) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for segment in presentation.segments {
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let color = segment.color {
                attributes[.foregroundColor] = color.nsColor
            }
            result.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return result
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
