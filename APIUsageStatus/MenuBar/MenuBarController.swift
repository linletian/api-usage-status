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
    private var hostingView: NSView?

    // Cached latest data for re-rendering (e.g. during flashing animation)
    private var latestSlotData: [SlotViewData] = []
    private var latestRefreshState: RefreshState = .idle
    private var latestInstances: [Instance] = []
    private var latestSettings: GlobalSettings = .default
    private var latestErrorSummaries: [ErrorSummary] = []

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
            let view = NSHostingView(rootView: contentView)
            self.hostingView = view
            popover?.contentViewController = NSViewController()
            popover?.contentViewController?.view = view
        } else {
            let view = NSHostingView(rootView: PlaceholderContentView())
            self.hostingView = view
            popover?.contentViewController = NSViewController()
            popover?.contentViewController?.view = view
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

        let dataPublisher = proxy.$slotViewDataList
            .combineLatest(proxy.$refreshState, proxy.$instances, proxy.$globalSettings)

        dataPublisher
            .combineLatest(proxy.$errorSummaries)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tuple in
                let ((slots, state, instances, settings), errors) = tuple
                self?.updateCachedData(
                    slotDataList: slots,
                    refreshState: state,
                    instances: instances,
                    settings: settings,
                    errorSummaries: errors
                )
            }
            .store(in: &cancellables)
    }

    private func updateCachedData(
        slotDataList: [SlotViewData],
        refreshState: RefreshState,
        instances: [Instance],
        settings: GlobalSettings,
        errorSummaries: [ErrorSummary]
    ) {
        latestSlotData = slotDataList
        latestRefreshState = refreshState
        latestInstances = instances
        latestSettings = settings
        latestErrorSummaries = errorSummaries

        // Update flashing state based on new data
        iconRenderer?.updateFlashingState(slotViewDataList: slotDataList)

        renderIcon()
        updatePopoverSize()
    }

    private func updatePopoverSize() {
        // Avoid resizing while Popover is visible to prevent visible jitter.
        guard let popover = popover, !popover.isShown else { return }
        popover.contentSize = NSSize(width: 300, height: calculateContentHeight())
    }

    /// Attempts to measure the actual rendered height of the SwiftUI content via
    /// `hostingView.fittingSize`. Falls back to `estimatedContentHeight()` if the
    /// measurement is not yet available (e.g. before the first layout pass).
    private func calculateContentHeight() -> CGFloat {
        if let view = hostingView {
            // Ensure the view has laid out with the latest data so that
            // fittingSize reflects the current intrinsic content size.
            view.setNeedsLayout()
            view.layoutSubtreeIfNeeded()
            let measured = view.fittingSize.height
            if measured > 0 {
                return min(500, max(160, measured))
            }
        }
        return estimatedContentHeight()
    }

    /// Fallback estimation when actual measurement isn't ready.
    /// Keeps the per-component breakdown so deviations are localised.
    private func estimatedContentHeight() -> CGFloat {
        let buttonsHeight: CGFloat = 46
        let padding: CGFloat = 24

        if latestSlotData.isEmpty && latestInstances.isEmpty {
            return 220
        }

        // All instances failed or disabled — compact height for error bar + prompt + buttons
        if latestSlotData.isEmpty && !latestInstances.isEmpty {
            let promptHeight: CGFloat = 100  // icon + two lines of text
            let errorBarHeight: CGFloat = latestErrorSummaries.isEmpty ? 0 : 36
            return errorBarHeight + promptHeight + buttonsHeight + padding
        }

        var cardsHeight: CGFloat = 0
        for slot in latestSlotData {
            cardsHeight += estimatedCardHeight(for: slot)
        }
        if latestSlotData.count > 1 {
            cardsHeight += CGFloat(latestSlotData.count - 1) * 8
        }

        let errorBarHeight: CGFloat = latestErrorSummaries.isEmpty ? 0 : 36
        let total = cardsHeight + errorBarHeight + buttonsHeight + padding
        return min(500, max(160, total))
    }

    private func estimatedCardHeight(for slot: SlotViewData) -> CGFloat {
        let headerHeight: CGFloat = 24
        let padding: CGFloat = 16

        switch slot.instanceType {
        case .quota:
            let contentHeight: CGFloat = 40
            return headerHeight + contentHeight + padding

        case .balance(_, let totalBalance, let grantedBalance, let isAvailable, _):
            if !isAvailable {
                return headerHeight + 16 + padding
            }
            var contentHeight: CGFloat = 20
            if let today = slot.todayUsage, !today.isEmpty {
                contentHeight += 14
            }
            if let averages = slot.dailyAverages, !averages.isEmpty {
                contentHeight += 14
                contentHeight += CGFloat(averages.count) * 12
            }
            // Balance breakdown section
            contentHeight += 8
            contentHeight += 10 // Topped Up
            if !grantedBalance.isEmpty && grantedBalance != "0" && grantedBalance != "0.00" {
                contentHeight += 10 // Granted
            }
            contentHeight += 10 // Total
            return headerHeight + contentHeight + padding
        }
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
            // Recompute size right before showing so the Popover opens
            // with dimensions matching the latest data.
            popover.contentSize = NSSize(width: 300, height: calculateContentHeight())
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
        // Explicitly nil-out the renderer so its flashing Task is cancelled
        // before the status item is removed, avoiding any stray callbacks.
        iconRenderer = nil
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }
}
