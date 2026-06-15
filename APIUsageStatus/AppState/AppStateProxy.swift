import Foundation
import Combine
import SwiftUI

// MARK: - AppStateProxy

/// Bridges the AppState actor to SwiftUI views via @Published properties.
/// Must run on the MainActor.
@MainActor
final class AppStateProxy: ObservableObject {
    // MARK: - @Published Properties (driving SwiftUI updates)

    @Published private(set) var instances: [Instance] = []
    @Published private(set) var slotViewDataList: [SlotViewData] = []
    @Published private(set) var refreshState: RefreshState = .idle
    @Published private(set) var errorSummaries: [ErrorSummary] = []
    @Published private(set) var globalSettings: GlobalSettings = .default
    @Published private(set) var minimaxModelNames: [String] = []
    @Published private(set) var lastRefreshAt: Date? = nil

    // MARK: - Internal References

    private let appState: AppState
    private let refreshService: RefreshService
    private let persistenceService: PersistenceService

    private let logger = AppLogger(category: "app")

    // MARK: - Initialization

    init(
        appState: AppState,
        refreshService: RefreshService,
        persistenceService: PersistenceService
    ) {
        self.appState = appState
        self.refreshService = refreshService
        self.persistenceService = persistenceService
    }

    // MARK: - Startup

    func initialize() async {
        logger.info("AppStateProxy initializing")

        // Ensure the OpenCode placeholder keychain entry exists. The
        // keychainService is unreachable through `appState`, so we go
        // through `persistenceService`. Idempotent — safe to call on
        // every launch.
        do {
            try await persistenceService.ensureOpenCodePlaceholder()
        } catch {
            logger.warning("Failed to ensure OpenCode placeholder key: \(error.localizedDescription)")
        }

        // Load from disk
        let (loadedInstances, loadedSettings) = await persistenceService.loadInstances()
        await appState.setInstances(loadedInstances)
        await appState.updateSettings(loadedSettings)

        // Inject sync closure so RefreshService can push updates directly
        // — eliminates the race window between refresh finish and UI sync
        await refreshService.setOnRefreshComplete { [weak self] in
            guard let self = self else { return }
            await self.syncFromState()
        }

        // Sync to @Published properties for initial UI render
        await syncFromState()

        // Start the refresh service
        let interval = loadedSettings.refreshIntervalMinutes
        await refreshService.start(interval: TimeInterval(interval))

        logger.info("AppStateProxy initialized with \(loadedInstances.count) instances")
    }

    // MARK: - Sync from AppState to @Published

    func syncFromState() async {
        async let instancesTask = appState.getInstances()
        async let slotsTask = appState.getSlotViewDataList()
        async let refreshTask = appState.getRefreshState()
        async let errorsTask = appState.getErrorSummaries()
        async let settingsTask = appState.getGlobalSettings()
        async let modelsTask = appState.getMiniMaxModelNames()
        async let lastRefreshTask = appState.getLastRefreshAt()

        let (loadedInstances, loadedSlots, loadedRefresh, loadedErrors, loadedSettings, loadedModels, loadedLastRefresh) = await (
            instancesTask, slotsTask, refreshTask, errorsTask, settingsTask, modelsTask, lastRefreshTask
        )

        self.instances = loadedInstances
        self.slotViewDataList = loadedSlots
        self.refreshState = loadedRefresh
        self.errorSummaries = loadedErrors
        self.globalSettings = loadedSettings
        self.minimaxModelNames = loadedModels
        self.lastRefreshAt = loadedLastRefresh
    }

    // MARK: - Manual Refresh

    func triggerManualRefresh() async {
        await refreshService.triggerManualRefresh()
        // syncFromState() is automatically invoked via onRefreshComplete
    }

    // MARK: - Computed Properties

    var enabledCount: Int {
        instances.filter { $0.enabled }.count
    }

    var hasEnabledInstances: Bool {
        enabledCount > 0
    }

    var hasAnyInstances: Bool {
        !instances.isEmpty
    }

    var isRefreshing: Bool {
        refreshState == .refreshing
    }

    // MARK: - State Updates from Settings

    func updateInstances(_ newInstances: [Instance]) async {
        await appState.setInstances(newInstances)
        await syncFromState()
    }

    func updateGlobalSettings(_ newSettings: GlobalSettings) async {
        await appState.updateSettings(newSettings)
        await syncFromState()

        // Restart timer if interval changed
        let newInterval = TimeInterval(newSettings.refreshIntervalMinutes)
        await refreshService.restartTimer(interval: newInterval)
    }

    func updateInstance(_ instance: Instance) async {
        await appState.updateInstance(instance)
        await syncFromState()
    }
}