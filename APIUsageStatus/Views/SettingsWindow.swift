import AppKit
import SwiftUI

// MARK: - SettingsWindow

final class SettingsWindow: NSObject {
    private var windowController: NSWindowController?
    private var viewModel: SettingsViewModel?

    private let persistenceService: PersistenceService
    private let appState: AppState
    private let appStateProxy: AppStateProxy
    private let refreshService: RefreshService
    private let notificationManager: NotificationManager
    private let appLaunchService: AppLaunchService

    init(
        persistenceService: PersistenceService,
        appState: AppState,
        appStateProxy: AppStateProxy,
        refreshService: RefreshService,
        notificationManager: NotificationManager,
        appLaunchService: AppLaunchService
    ) {
        self.persistenceService = persistenceService
        self.appState = appState
        self.appStateProxy = appStateProxy
        self.refreshService = refreshService
        self.notificationManager = notificationManager
        self.appLaunchService = appLaunchService
        super.init()
    }

    /// Brings the settings window to the front, creating it if necessary.
    /// Reloads data each time to ensure the latest state is displayed.
    func open() {
        Task { @MainActor in
            if windowController == nil {
                let vm = SettingsViewModel(
                    persistenceService: persistenceService,
                    appState: appState,
                    appStateProxy: appStateProxy,
                    refreshService: refreshService,
                    notificationManager: notificationManager,
                    appLaunchService: appLaunchService
                )
                self.viewModel = vm

                let settingsView = SettingsView(viewModel: vm)
                let hostingController = NSHostingController(rootView: settingsView)

                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "Settings — API Usage Status"
                window.contentViewController = hostingController
                window.minSize = NSSize(width: 560, height: 420)
                window.center()
                window.delegate = self

                windowController = NSWindowController(window: window)
            }

            await viewModel?.load()
            windowController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Closes the settings window.
    func close() {
        windowController?.close()
    }
}

// MARK: - NSWindowDelegate

extension SettingsWindow: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let vm = viewModel else {
            return true
        }

        // If a save is already in progress, prevent re-entrant close attempts
        if vm.isSaving {
            return false
        }

        guard vm.hasUnsavedChanges else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Unsaved Changes"
        alert.informativeText = "You have unsaved changes. Do you want to save them before closing?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: // Save
            Task { @MainActor in
                let success = await vm.save()
                if success {
                    sender.close()
                }
                // If save fails, keep window open so user sees the error
            }
            return false
        case .alertSecondButtonReturn: // Don't Save
            vm.discardChanges()
            return true
        default: // Cancel
            return false
        }
    }
}
