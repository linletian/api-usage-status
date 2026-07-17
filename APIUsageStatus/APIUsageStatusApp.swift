import AppKit
import UserNotifications

@main
struct APIUsageStatusApp {
    static func main() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        NSApp.delegate = delegate
        NSApp.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var appStateProxy: AppStateProxy?
    private var settingsWindow: SettingsWindow?
    private var notificationManager: NotificationManager?
    private var detailPanelController: InstanceDetailPanelController?

    /// Retained observer tokens for NSWorkspace / NSApplication lifecycle
    /// notifications, paired with the NotificationCenter that registered
    /// them — `removeObserver(_:)` is a no-op on the wrong center, so
    /// we must remember where each token lives. Block-based observers
    /// are torn down when their tokens are deallocated; we hold them
    /// for the AppDelegate's lifetime.
    private var lifecycleObservers: [(NSObjectProtocol, NotificationCenter)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.lifecycle.info("app launched at \(Date())")
        observeLifecycle()

        // Set activation policy to accessory (no Dock icon, pure menu bar app)
        NSApp.setActivationPolicy(.accessory)

        // Create main menu with Edit items so Cmd+C/V work through the app's
        // own responder chain (needed for LSUIElement apps where the menu bar
        // belongs to the previously active application).
        setupMainMenu()

        // Initialize core services
        let keychainService = KeychainService()
        let persistenceService = PersistenceService(keychainService: keychainService)
        let appState = AppState()
        let refreshService = RefreshService(persistenceService: persistenceService, appState: appState)
        let appLaunchService = AppLaunchService()

        // Create AppStateProxy
        appStateProxy = AppStateProxy(
            appState: appState,
            refreshService: refreshService,
            persistenceService: persistenceService
        )

        // Create detail panel controller for notification clicks
        guard let proxy = appStateProxy else { return }
        detailPanelController = InstanceDetailPanelController(appStateProxy: proxy)

        // Create notification manager and register delegate
        let manager = NotificationManager { [weak self] uuid in
            self?.detailPanelController?.show(for: uuid)
        }
        notificationManager = manager
        UNUserNotificationCenter.current().delegate = manager

        // Create SettingsWindow (singleton, reused on open/close)
        settingsWindow = SettingsWindow(
            persistenceService: persistenceService,
            appState: appState,
            appStateProxy: proxy,
            refreshService: refreshService,
            notificationManager: manager,
            appLaunchService: appLaunchService
        )

        // Initialize MenuBarController with AppStateProxy
        menuBarController = MenuBarController(
            appStateProxy: proxy,
            openSettings: { [weak self] in
                self?.settingsWindow?.open()
            }
        )

        // Start the app in a single sequential @MainActor task to avoid races
        Task { @MainActor in
            // 1. Sync current notification authorization status so
            //    evaluateThresholds knows whether it can schedule.
            await manager.fetchCurrentPermissionStatus()

            // 2. Inject notification manager before any refresh can run
            await refreshService.setNotificationManager(manager)

            // 3. Initialize loads persisted state and triggers the first refresh
            await proxy.initialize()

            // 4. Ensure launch-at-login registration state is consistent
            if proxy.globalSettings.launchAtLogin {
                appLaunchService.register()
            }

            // 5. If the user has never been prompted (status == .notDetermined),
            //    request permission when the setting is enabled.
            if proxy.globalSettings.notificationsEnabled {
                manager.requestPermission()
            }
        }

        // 6. Pre-warm the OpenCode workspace ID cache off the main thread so
        //    the popup "See details" button never has to block on the grep
        //    scan. The view layer reads `cachedWorkspaceID()` only; this
        //    populates that cache.
        OpenCodeWorkspaceResolver.prewarm()

        // 7. Diagnostic snapshot for the "auto-refresh stops after hours"
        //    investigation — thermal/power state transitions are sparse
        //    events but strong correlators with App Nap throttling.
        let pi = ProcessInfo.processInfo
        AppLogger.lifecycle.info("ProcessInfo initial: thermal=\(pi.thermalState.rawValue) lowPowerMode=\(pi.isLowPowerModeEnabled)")
        let thermalToken = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            AppLogger.lifecycle.info("ProcessInfo thermalState changed → \(ProcessInfo.processInfo.thermalState.rawValue)")
        }
        lifecycleObservers.append((thermalToken, NotificationCenter.default))
        let powerToken = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { _ in
            AppLogger.lifecycle.info("ProcessInfo isLowPowerModeEnabled → \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        }
        lifecycleObservers.append((powerToken, NotificationCenter.default))
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.lifecycle.info("app will terminate at \(Date())")
        for (token, center) in lifecycleObservers {
            center.removeObserver(token)
        }
        lifecycleObservers.removeAll()
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    }

    /// Subscribe to system and display sleep/wake events plus app focus
    /// changes. These are the diagnostic breadcrumbs for the
    /// "auto-refresh stops after hours" investigation — pairing them with
    /// the `cycle tick` log in `RefreshService` lets us correlate timer
    /// suspensions with system state transitions (App Nap, system sleep,
    /// display sleep, focus loss).
    ///
    /// Note: `NSWorkspace` notifications route through
    /// `NSWorkspace.shared.notificationCenter`, while `NSApplication`
    /// active/resign notifications route through `NotificationCenter.default`.
    /// Mixing them on the wrong center silently drops events — the
    /// `didResignActive` signal that maps a focus-loss window onto a
    /// `sleep drift` spike is exactly the App Nap diagnosis we need.
    private func observeLifecycle() {
        let workspaceEvents: [(NotificationCenter, Notification.Name, String)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, "system willSleep"),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, "system didWake"),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification, "screens didSleep"),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification, "screens didWake"),
        ]
        let appEvents: [(NotificationCenter, Notification.Name, String)] = [
            (NotificationCenter.default, NSApplication.didBecomeActiveNotification, "app didBecomeActive"),
            (NotificationCenter.default, NSApplication.didResignActiveNotification, "app didResignActive"),
        ]
        for (center, name, label) in workspaceEvents + appEvents {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                AppLogger.lifecycle.info("\(label) at \(Date())")
                if label == "system didWake" {
                    Task { [weak self] in
                        guard let proxy = self?.appStateProxy else { return }
                        await proxy.triggerManualRefresh()
                    }
                }
            }
            lifecycleObservers.append((token, center))
        }
    }
}
