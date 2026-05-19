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

        // Initialize MenuBarController with AppStateProxy
        menuBarController = MenuBarController(appStateProxy: appStateProxy!)

        // Start the app
        Task { @MainActor in
            await appStateProxy?.initialize()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Placeholder for cleanup logic (future use)
    }
}