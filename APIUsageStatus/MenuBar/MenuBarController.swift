import AppKit
import SwiftUI
import Combine

final class MenuBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var rightClickMenu: NSMenu?
    private var appStateProxy: AppStateProxy?
    private var cancellables = Set<AnyCancellable>()

    init(appStateProxy: AppStateProxy) {
        self.appStateProxy = appStateProxy
        super.init()
        setupStatusItem()
        setupPopover()
        setupRightClickMenu()
        observeAppState()
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

        if let proxy = appStateProxy {
            let contentView = UsagePanelView(appStateProxy: proxy)
            let hostingView = NSHostingView(rootView: contentView)
            popover?.contentViewController = NSViewController()
            popover?.contentViewController?.view = hostingView
        } else {
            let placeholderView = NSHostingView(rootView: PlaceholderContentView())
            popover?.contentViewController = NSViewController()
            popover?.contentViewController?.view = placeholderView
        }
    }

    private func setupRightClickMenu() {
        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(handleRefresh(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(handleOpenSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        rightClickMenu = menu
    }

    private func observeAppState() {
        guard let proxy = appStateProxy else { return }

        // Observe slot data changes to update menu bar icon
        proxy.$slotViewDataList
            .combineLatest(proxy.$refreshState, proxy.$instances, proxy.$globalSettings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] slotDataList, refreshState, instances, settings in
                self?.updateMenuBarIcon(
                    slotDataList: slotDataList,
                    refreshState: refreshState,
                    instances: instances,
                    settings: settings
                )
            }
            .store(in: &cancellables)
    }

    private func updateMenuBarIcon(
        slotDataList: [SlotViewData],
        refreshState: RefreshState,
        instances: [Instance],
        settings: GlobalSettings
    ) {
        guard let button = statusItem?.button else { return }

        let enabledCount = instances.filter { $0.enabled }.count
        let totalCount = instances.count

        if totalCount == 0 {
            button.title = "?"
        } else if enabledCount == 0 {
            button.title = "NO API"
        } else if refreshState == .refreshing {
            button.title = "..."
        } else {
            // Normal state - render slots
            // For Phase 1, just show the count as a simple indicator
            // Full pixel rendering will be implemented in Phase 2
            let enabledSlots = slotDataList.filter { data in
                instances.contains { $0.uuid == data.uuid && $0.enabled }
            }

            if enabledSlots.isEmpty {
                button.title = "?"
            } else {
                // Show first 2 short names concatenated
                let displayText = enabledSlots.prefix(2).map { $0.shortName.isEmpty ? "??" : $0.shortName }.joined(separator: " ")
                button.title = displayText
            }
        }

        button.needsDisplay = true
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            guard let button = statusItem?.button, let menu = rightClickMenu else { return }
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

    @objc private func handleRefresh(_ sender: Any?) {
        Task { @MainActor in
            await appStateProxy?.triggerManualRefresh()
        }
    }

    @objc private func handleOpenSettings(_ sender: Any?) {
        // Settings window will be implemented in Phase 4
    }

    deinit {
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }
}