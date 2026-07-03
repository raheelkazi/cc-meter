import AppKit
import SwiftUI
import Combine
import CCMeterCore

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let viewModel: MeterViewModel
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: MeterViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    func install() {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 260)
        popover.contentViewController = NSHostingController(rootView: PopoverView(viewModel: viewModel))

        // Re-render the status title on any published change.
        viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateTitle() }
            .store(in: &cancellables)

        updateTitle()
    }

    private func updateTitle() {
        statusItem.button?.attributedTitle = Self.titleString(for: viewModel)
    }

    static func titleString(for vm: MeterViewModel) -> NSAttributedString {
        switch vm.state {
        case .loading:
            return NSAttributedString(string: "CC ...")
        case .error:
            return NSAttributedString(string: "CC !")
        case .ok:
            guard let compact = vm.compact else { return NSAttributedString(string: "CC") }
            let result = NSMutableAttributedString(
                string: "\u{25CF} ",
                attributes: [.foregroundColor: compact.color.nsColor]
            )
            result.append(NSAttributedString(string: "\(compact.percent)%"))
            return result
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
