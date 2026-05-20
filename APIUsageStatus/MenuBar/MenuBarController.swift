import AppKit
import SwiftUI
import Combine

final class MenuBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var rightClickMenu: NSMenu?
    private var appStateProxy: AppStateProxy?
    private var iconRenderer: MenuBarIconRenderer?
    private var cancellables = Set<AnyCancellable>()
    private var openSettings: () -> Void

    // Cached latest data for re-rendering (e.g. during flashing animation)
    private var latestSlotData: [SlotViewData] = []
    private var latestRefreshState: RefreshState = .idle
    private var latestInstances: [Instance] = []
    private var latestSettings: GlobalSettings = .default

    init(appStateProxy: AppStateProxy, openSettings: @escaping () -> Void) {
        self.appStateProxy = appStateProxy
        self.openSettings = openSettings
        super.init()
        setupStatusItem()
        setupPopover()
        setupRightClickMenu()
        setupRenderer()
        observeAppState()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = ""  // Pixel font uses image, not title
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
            let contentView = UsagePanelView(appStateProxy: proxy, openSettings: openSettings)
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

    private func setupRenderer() {
        let renderer = MenuBarIconRenderer()
        renderer.onNeedsDisplay = { [weak self] in
            self?.renderIcon()
        }
        iconRenderer = renderer
    }

    // MARK: - AppState observation

    private func observeAppState() {
        guard let proxy = appStateProxy else { return }

        proxy.$slotViewDataList
            .combineLatest(proxy.$refreshState, proxy.$instances, proxy.$globalSettings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] slotViewDataList, refreshState, instances, settings in
                self?.updateCachedData(
                    slotDataList: slotViewDataList,
                    refreshState: refreshState,
                    instances: instances,
                    settings: settings
                )
            }
            .store(in: &cancellables)
    }

    private func updateCachedData(
        slotDataList: [SlotViewData],
        refreshState: RefreshState,
        instances: [Instance],
        settings: GlobalSettings
    ) {
        latestSlotData = slotDataList
        latestRefreshState = refreshState
        latestInstances = instances
        latestSettings = settings

        // Update flashing state based on new data
        iconRenderer?.updateFlashingState(slotViewDataList: slotDataList)

        renderIcon()
    }

    private func renderIcon() {
        guard let button = statusItem?.button else { return }
        guard let renderer = iconRenderer else { return }

        let enabledCount = latestInstances.filter { $0.enabled }.count
        let totalCount = latestInstances.count

        let image = renderer.render(
            slotViewDataList: latestSlotData,
            colorMode: latestSettings.colorMode,
            refreshState: latestRefreshState,
            instancesCount: totalCount,
            enabledCount: enabledCount
        )

        button.image = image
        button.imagePosition = .imageOnly
        button.needsDisplay = true
    }

    // MARK: - Interaction

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
        openSettings()
    }

    deinit {
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }
}
