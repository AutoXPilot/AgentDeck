import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = SessionsModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.stack",
                accessibilityDescription: "AgentDeck"
            )
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.contentViewController = NSHostingController(
            rootView: SessionListView(model: model)
        )
        popover.behavior = .transient
        model.onChange = { [weak self] in self?.refreshBadge() }
        model.start()
    }

    private func refreshBadge() {
        guard let button = statusItem.button else { return }
        let count = model.attentionCount
        button.title = count > 0 ? " \(count)" : ""
        button.contentTintColor = count > 0 ? .systemOrange : nil
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.reload()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
