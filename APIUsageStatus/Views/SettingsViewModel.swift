import Foundation
import Combine

// MARK: - SidebarItem

enum SidebarItem: String, CaseIterable {
    case services
    case general
    case about
}

// MARK: - SettingsViewModel

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var instances: [Instance] = []
    @Published var settings: GlobalSettings = .default
    @Published var isPresentingEditor = false
    @Published var editingInstance: Instance?
    @Published var isConfirmingDelete = false
    @Published var instanceToDelete: Instance?
    @Published var saveError: String?
    @Published var isSaving = false
    @Published var launchAtLoginError: String?
    @Published var selectedSidebarItem: SidebarItem = .services

    private var originalInstances: [Instance] = []
    private var originalSettings: GlobalSettings = .default
    private var apiKeys: [String: String] = [:]

    private let persistenceService: PersistenceService
    private let appState: AppState
    private let appStateProxy: AppStateProxy
    private let refreshService: RefreshService
    private let notificationManager: NotificationManager
    private let appLaunchService: AppLaunchService
    private let logger = AppLogger(category: "settings")

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
    }

    // MARK: - Load / Save

    var hasUnsavedChanges: Bool {
        instances != originalInstances || settings != originalSettings || !apiKeys.isEmpty
    }

    var miniMaxModelNames: [String] {
        appStateProxy.minimaxModelNames
    }

    func load() async {
        let (loadedInstances, loadedSettings, _) = await persistenceService.loadInstances()
        let sortedInstances = loadedInstances.sorted { $0.sortOrder < $1.sortOrder }
        instances = sortedInstances
        settings = loadedSettings
        originalInstances = sortedInstances
        originalSettings = loadedSettings
        apiKeys = [:]
        saveError = nil
        launchAtLoginError = nil
        logger.info("SettingsViewModel loaded \(sortedInstances.count) instances")
    }

    func discardChanges() {
        instances = originalInstances
        settings = originalSettings
        apiKeys = [:]
        saveError = nil
        launchAtLoginError = nil
        logger.info("SettingsViewModel discarded unsaved changes")
    }

    func save() async -> Bool {
        isSaving = true
        defer { isSaving = false }

        // Validate all instances
        for instance in instances {
            if !instance.shortName.isValidShortName {
                saveError = "Short name for \"\(instance.displayName)\" must be 2 or 3 uppercase letters or digits"
                return false
            }

            switch instance.thresholds {
            case .quota(let w, let c):
                if w >= c {
                    saveError = "Warning must be less than critical for \"\(instance.displayName)\""
                    return false
                }
            case .balance(let w, let c, _, _):
                if w <= c {
                    saveError = "Warning must be greater than critical for \"\(instance.displayName)\""
                    return false
                }
            }
        }

        do {
            // 1. Save new/changed API keys to Keychain first (most likely to fail)
            for (uuid, key) in apiKeys {
                if let instance = instances.first(where: { $0.uuid == uuid }) {
                    try await persistenceService.saveApiKey(key, for: instance.apiKeyRef)
                }
            }

            // 2. Clean up deleted instances (file + Keychain)
            let deletedInstances = originalInstances.filter { original in
                !instances.contains(where: { $0.uuid == original.uuid })
            }
            for instance in deletedInstances {
                try await persistenceService.deleteInstance(instance, allInstances: instances)
            }

            // 3. Atomically commit instances.json as the final step
            try await persistenceService.saveInstances(instances, settings: settings)

            // 4. Update runtime AppState only after all disk ops succeed
            await appState.setInstances(instances)
            await appState.updateSettings(settings)
            await appStateProxy.syncFromState()

            // Restart refresh timer if interval changed
            if settings.refreshIntervalMinutes != originalSettings.refreshIntervalMinutes {
                await refreshService.restartTimer(interval: TimeInterval(settings.refreshIntervalMinutes))
            }

            // Trigger an immediate refresh so newly added/edited instances
            // show up right away instead of waiting for the next timer tick.
            await refreshService.triggerManualRefresh()

            // Reload instances to pick up auto-discovered MiniMax metrics
            // (added during the refresh above). Retry up to 3 times with
            // increasing delay; if all attempts fail, log a warning but
            // keep the pre-reload state — the save already succeeded and
            // the new metrics will appear on the next load/refresh.
            var reloadSucceeded = false
            for attempt in 1...3 {
                do {
                    let (refreshed, _, _) = try await persistenceService.loadInstances()
                    instances = refreshed.sorted { $0.sortOrder < $1.sortOrder }
                    reloadSucceeded = true
                    break
                } catch {
                    logger.warning("Reload after save attempt \(attempt)/3 failed: \(error.localizedDescription)")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 100_000_000)
                    }
                }
            }
            if !reloadSucceeded {
                logger.warning("Reload after save failed after 3 attempts; keeping pre-reload state")
            }

            // Sync launch-at-login registration if changed
            if settings.launchAtLogin != originalSettings.launchAtLogin {
                if settings.launchAtLogin {
                    if !appLaunchService.register() {
                        launchAtLoginError = "Could not enable launch at login. You may need to add it manually in System Settings."
                    }
                } else {
                    if !appLaunchService.unregister() {
                        launchAtLoginError = "Could not disable launch at login. You may need to remove it manually in System Settings."
                    }
                }
            }

            originalInstances = instances
            originalSettings = settings
            apiKeys = [:]
            saveError = nil
            logger.info("Settings saved successfully")
            return true
        } catch {
            logger.error("Failed to save settings: \(error.localizedDescription)")
            saveError = error.localizedDescription
            // Rollback local state to prevent corruption
            instances = originalInstances
            settings = originalSettings
            apiKeys = [:]
            return false
        }
    }

    // MARK: - Instance Management

    func addInstance(_ instance: Instance, apiKey: String) {
        var newInstance = instance
        newInstance.sortOrder = instances.count
        instances.append(newInstance)
        if !apiKey.isEmpty {
            apiKeys[newInstance.uuid] = apiKey
        }
    }

    func updateInstance(_ instance: Instance, apiKey: String?) {
        if let index = instances.firstIndex(where: { $0.uuid == instance.uuid }) {
            instances[index] = instance
        }
        if let key = apiKey, !key.isEmpty {
            apiKeys[instance.uuid] = key
        }
    }

    func requestDelete(_ instance: Instance) {
        instanceToDelete = instance
        isConfirmingDelete = true
    }

    func deleteInstance(_ instance: Instance) async {
        instances.removeAll { $0.uuid == instance.uuid }
        apiKeys.removeValue(forKey: instance.uuid)
        recomputeSortOrders()
    }

    func moveInstances(fromOffsets source: IndexSet, toOffset destination: Int) {
        instances.move(fromOffsets: source, toOffset: destination)
        recomputeSortOrders()
    }

    func setInstanceTrackingEnabled(uuid: String, enabled: Bool) {
        if let index = instances.firstIndex(where: { $0.uuid == uuid }) {
            instances[index].trackingEnabled = enabled
        }
    }

    @available(*, deprecated, message: "Use setInstanceTrackingEnabled instead")
    func setInstanceEnabled(uuid: String, enabled: Bool) {
        setInstanceTrackingEnabled(uuid: uuid, enabled: enabled)
    }

    // MARK: - Notifications

    /// Called when the notifications toggle changes in the UI.
    /// Requests permission immediately when the user turns notifications on.
    func onNotificationsEnabledChanged(_ enabled: Bool) {
        if enabled {
            notificationManager.requestPermission()
        }
    }

    // MARK: - Helpers

    private func recomputeSortOrders() {
        for index in instances.indices {
            instances[index].sortOrder = index
        }
    }
}
