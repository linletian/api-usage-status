import AppKit
import SwiftUI

final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var quitMenu: NSMenu?

    override init() {
        super.init()
        setupStatusItem()
        setupPopover()
        setupRightClickMenu()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "?"
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover?.behavior = .transient
        popover?.contentSize = NSSize(width: 300, height: 400)

        // Placeholder content for Phase 0
        let placeholderView = NSHostingView(rootView: PlaceholderContentView())
        popover?.contentViewController = NSViewController()
        popover?.contentViewController?.view = placeholderView
    }

    private func setupRightClickMenu() {
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        quitMenu = menu
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            guard let button = statusItem?.button, let menu = quitMenu else { return }
            menu.popUp(positioning: menu.items.first, at: CGPoint(x: 0, y: -2), in: button)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if let popover = popover, popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem?.button, let popover = popover {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    deinit {
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }
}

// Placeholder SwiftUI view for Phase 0
struct PlaceholderContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Usage Panel")
                .font(.headline)
            Text("(Pending development)")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(width: 280, height: 200)
    }
}