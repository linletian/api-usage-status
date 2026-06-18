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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Placeholder for cleanup logic (future use)
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
}
