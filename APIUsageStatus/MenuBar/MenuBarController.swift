import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController: NSObject, ObservableObject, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var usageWindow: NSWindow?
    private var rightClickMenu: NSMenu?
    private var appStateProxy: AppStateProxy?
    private var iconRenderer: MenuBarIconRenderer?
    private var cancellables = Set<AnyCancellable>()
    private var openSettings: () -> Void
    private var hostingView: NSView?

    // Cached latest data for re-rendering (e.g. during breathing animation)
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
        setupWindow()
        setupRightClickMenu()
        setupRenderer()
        observeAppState()
        observeSystemAppearance()
    }

    // MARK: - System Appearance Observation

    private func observeSystemAppearance() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleAppearanceChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func handleAppearanceChange() {
        renderIcon()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = ""
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.stationary]
        window.minSize = NSSize(width: 300, height: 160)
        window.delegate = self

        let contentView: NSView
        if let proxy = appStateProxy {
            contentView = NSHostingView(rootView: UsagePanelView(appStateProxy: proxy, openSettings: openSettings))
        } else {
            contentView = NSHostingView(rootView: PlaceholderContentView())
        }
        self.hostingView = contentView
        window.contentView = contentView

        usageWindow = window
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

        iconRenderer?.updateBreathingState(slotViewDataList: slotDataList)
        if let renderer = iconRenderer {
            if renderer.needsBreathingAnimation(), !renderer.isBreathingAnimationRunning() {
                renderer.startBreathingAnimation()
            } else if !renderer.needsBreathingAnimation(), renderer.isBreathingAnimationRunning() {
                renderer.stopBreathingAnimation()
            }
        }

        renderIcon()
        updateWindowSize()
    }

    private func updateWindowSize() {
        guard let window = usageWindow else { return }
        let height = calculateContentHeight()
        var frame = window.frame
        frame.size.height = height

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            window.animator().setFrame(frame, display: true)
        }
    }

    private func calculateContentHeight() -> CGFloat {
        if let view = hostingView {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            let measured = view.fittingSize.height
            // Subtract title bar safe area inset (~28pt) since .ignoresSafeArea(edges: .top)
            // moves content up but fittingSize still includes the reserved space
            let topInset = view.safeAreaInsets.top
            let adjusted = measured - topInset
            if adjusted > 0 {
                return min(500, max(160, adjusted))
            }
        }
        return estimatedContentHeight()
    }

    private func estimatedContentHeight() -> CGFloat {
        let buttonsHeight: CGFloat = 46
        let padding: CGFloat = 24

        if latestSlotData.isEmpty && latestInstances.isEmpty {
            return 220
        }

        if latestSlotData.isEmpty && !latestInstances.isEmpty {
            let promptHeight: CGFloat = 100
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

        // Multi-metric cards render one row per additional metric snapshot.
        // ~22pt covers the per-metric label + value line at our standard typography.
        let extraMetricsHeight = max(0, CGFloat(slot.metricSnapshots.count - 1)) * 22

        switch slot.instanceType {
        case .quota:
            // 40pt for 5h bar + text, ~20pt for optional weekly bar
            let contentHeight: CGFloat = 60
            return headerHeight + contentHeight + padding + extraMetricsHeight

        case .balance(_, _, let grantedBalance, let isAvailable, _):
            if !isAvailable {
                return headerHeight + 16 + padding + extraMetricsHeight
            }
            var contentHeight: CGFloat = 20
            if let today = slot.todayUsage, !today.isEmpty {
                contentHeight += 14
            }
            if let averages = slot.dailyAverages, !averages.isEmpty {
                contentHeight += 14
                contentHeight += CGFloat(averages.count) * 12
            }
            contentHeight += 8
            contentHeight += 10
            if !grantedBalance.isEmpty && grantedBalance != "0" && grantedBalance != "0.00" {
                contentHeight += 10
            }
            contentHeight += 10
            return headerHeight + contentHeight + padding + extraMetricsHeight
        }
    }

    private func renderIcon() {
        guard let button = statusItem?.button else { return }
        guard let renderer = iconRenderer else { return }

        let enabledCount = latestInstances.filter { $0.trackingEnabled }.count
        let totalCount = latestInstances.count

        let isDarkBackground: Bool = {
            if let name = statusItem?.button?.effectiveAppearance.name {
                return name == .darkAqua || name == .vibrantDark ||
                       name == .accessibilityHighContrastDarkAqua ||
                       name == .accessibilityHighContrastVibrantDark
            }
            return false
        }()

        let image = renderer.render(
            slotViewDataList: latestSlotData,
            colorMode: latestSettings.colorMode,
            refreshState: latestRefreshState,
            instancesCount: totalCount,
            enabledCount: enabledCount,
            isDarkBackground: isDarkBackground
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
            toggleWindow()
        }
    }

    private func toggleWindow() {
        guard let window = usageWindow, let button = statusItem?.button else { return }

        if window.isVisible {
            window.close()
        } else {
            let height = calculateContentHeight()
            var frame = window.frame
            frame.size.width = 300
            frame.size.height = height

            let buttonFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
            let originX = buttonFrame.midX - frame.width / 2
            let originY = buttonFrame.minY - frame.height - 4
            frame.origin = CGPoint(x: originX, y: originY)

            window.setFrame(frame, display: false)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        usageWindow?.close()
    }

    // MARK: - Actions

    @objc private func handleRefresh(_ sender: Any?) {
        Task { @MainActor in
            await appStateProxy?.triggerManualRefresh()
        }
    }

    @objc private func handleOpenSettings(_ sender: Any?) {
        openSettings()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        iconRenderer = nil
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }
}
