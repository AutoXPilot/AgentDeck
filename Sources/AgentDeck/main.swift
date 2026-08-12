import AgentDeckCore
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = SessionsModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Without an autosave name macOS re-places the item on every launch,
        // usually at the leftmost slot of the third-party area — the first
        // thing clipped on a notched display. With one, wherever the user
        // ⌘-drags it is remembered, so they only position it once.
        statusItem.autosaveName = "AgentDeckStatusItem"
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.contentViewController = NSHostingController(
            rootView: SessionListView(model: model)
        )
        popover.behavior = .transient
        popover.delegate = self
        model.onChange = { [weak self] in self?.refreshBadge() }
        model.onRequestClose = { [weak self] in self?.popover.performClose(nil) }
        model.start()
        refreshBadge()
        logStatusItemPlacement()
        // A brand-new install has no hooks and would otherwise look like an
        // app that simply does nothing — show it once, with instructions.
        if !model.helperInstalled || !model.claudeHooksInstalled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.popover.isShown else { return }
                self.togglePopover()
            }
        }
    }

    /// The glyph carries the most urgent state, so one errored session among
    /// ten finished ones doesn't look identical to nothing being wrong.
    private func symbolName(for state: SessionState?) -> String {
        switch state {
        case .error: return "exclamationmark.triangle.fill"
        case .waiting: return "hand.raised.fill"
        case .done: return "checkmark.circle"
        // Not `rectangle.stack`: at menu-bar size it reads as a box with a
        // divider, easily mistaken for Control Center's stacked toggles.
        // Layers are distinctive and match the "deck" metaphor.
        default: return "square.stack.3d.up"
        }
    }

    private func refreshBadge() {
        // Changing the title changes the status item's WIDTH, which slides
        // the anchored popover sideways — never resize while it's open.
        guard !popover.isShown else { return }
        guard let button = statusItem.button else { return }
        let urgent = model.mostUrgent
        let count = model.alertCount
        let image = NSImage(
            systemSymbolName: symbolName(for: urgent),
            accessibilityDescription: "AgentDeck"
        )
        button.image = image
        // An item with neither image nor title has zero width and is simply
        // invisible — never let that happen if a symbol fails to resolve.
        button.title = count > 0 ? " \(count)" : (image == nil ? "AD" : "")
        button.contentTintColor = count > 0
            ? (urgent == .error ? .systemRed : .systemOrange) : nil
        button.toolTip = count > 0
            ? "AgentDeck — \(count) session\(count == 1 ? "" : "s") need you"
            : "AgentDeck — nothing blocked"
    }

    /// Where macOS actually placed the icon. A zero width means the item
    /// drew nothing; an x beyond the screen (or no window at all) means the
    /// menu bar ran out of room and the item is in the hidden overflow.
    private func logStatusItemPlacement() {
        // give the menu bar a beat to lay the item out
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            var frameText = "NO WINDOW"
            if let frame = self.statusItem.button?.window?.frame {
                let x = Int(frame.origin.x), y = Int(frame.origin.y)
                let w = Int(frame.width), h = Int(frame.height)
                frameText = "\(x),\(y) \(w)x\(h)"
            }
            let screens = NSScreen.screens.map { screen -> String in
                let f = screen.frame
                return "\(Int(f.width))x\(Int(f.height))@\(Int(f.origin.x))"
            }.joined(separator: ",")
            let hasImage = self.statusItem.button?.image != nil
            let title = self.statusItem.button?.title ?? ""
            if let screen = NSScreen.main {
                // On notched Macs these are the usable menu-bar strips either
                // side of the camera housing; an item outside them is hidden.
                let left = screen.auxiliaryTopLeftArea
                let right = screen.auxiliaryTopRightArea
                let leftText = left.map { "\(Int($0.minX))–\(Int($0.maxX))" } ?? "none"
                let rightText = right.map { "\(Int($0.minX))–\(Int($0.maxX))" } ?? "none"
                SessionsModel.appLog(
                    "menubar: notch-left=\(leftText) notch-right=\(rightText) "
                    + "topInset=\(Int(screen.safeAreaInsets.top))"
                )
            }
            SessionsModel.appLog(
                "statusitem: visible=\(self.statusItem.isVisible) "
                + "length=\(self.statusItem.length) frame=\(frameText) "
                + "hasImage=\(hasImage) title='\(title)' screens=[\(screens)]"
            )
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.popoverOpened()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard !popover.isShown else { return }  // stale callback after a fast reopen
        model.popoverClosed()
        refreshBadge()
    }
}

/// `AgentDeck --render-popover <out.png>` draws the real popover, with the
/// real live session data, straight to a file. Lets UI changes be inspected
/// without a screenshot — and gives bug reporters a way to show the window
/// without capturing their whole screen.
@MainActor
func renderPopover(to path: String) -> Never {
    let model = SessionsModel()
    model.start(forRendering: true)
    model.popoverOpened()
    // let the async title fetch land before drawing
    RunLoop.main.run(until: Date().addingTimeInterval(2.5))
    let renderer = ImageRenderer(
        content: SessionListView(model: model, staticLayout: true).frame(width: 380)
    )
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("render failed\n".utf8))
        exit(1)
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
if CommandLine.arguments.dropFirst().first == "--render-popover" {
    guard CommandLine.arguments.count > 2 else {
        FileHandle.standardError.write(
            Data("usage: AgentDeck --render-popover <out.png>\n".utf8)
        )
        exit(64)
    }
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { renderPopover(to: CommandLine.arguments[2]) }
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
