import AppKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy to accessory (no Dock icon, pure menu bar app)
        NSApp.setActivationPolicy(.accessory)

        // Initialize core services
        let keychainService = KeychainService()
        let persistenceService = PersistenceService(keychainService: keychainService)
        let appState = AppState()
        let refreshService = RefreshService(persistenceService: persistenceService, appState: appState)

        // Create AppStateProxy
        appStateProxy = AppStateProxy(
            appState: appState,
            refreshService: refreshService,
            persistenceService: persistenceService
        )

        // Create SettingsWindow (singleton, reused on open/close)
        settingsWindow = SettingsWindow(
            persistenceService: persistenceService,
            appState: appState,
            appStateProxy: appStateProxy!,
            refreshService: refreshService
        )

        // Initialize MenuBarController with AppStateProxy
        menuBarController = MenuBarController(
            appStateProxy: appStateProxy!,
            openSettings: { [weak self] in
                self?.settingsWindow?.open()
            }
        )

        // Start the app
        Task { @MainActor in
            await appStateProxy?.initialize()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Placeholder for cleanup logic (future use)
    }
}