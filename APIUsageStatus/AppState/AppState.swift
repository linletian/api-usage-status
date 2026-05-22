import Foundation

// MARK: - AppState

actor AppState {
    private var _instances: [Instance] = []
    private var _slotViewDataList: [SlotViewData] = []
    private var _refreshState: RefreshState = .idle
    private var _errorSummaries: [ErrorSummary] = []
    private var _globalSettings: GlobalSettings = .default
    private var _miniMaxModelNames: [String] = []
    private var _lastRefreshAt: Date? = nil

    // MARK: - Getters

    func getInstances() -> [Instance] {
        _instances
    }

    func getSlotViewDataList() -> [SlotViewData] {
        _slotViewDataList
    }

    func getRefreshState() -> RefreshState {
        _refreshState
    }

    func getErrorSummaries() -> [ErrorSummary] {
        _errorSummaries
    }

    func getGlobalSettings() -> GlobalSettings {
        _globalSettings
    }

    func getMiniMaxModelNames() -> [String] {
        _miniMaxModelNames
    }

    func setMiniMaxModelNames(_ names: [String]) {
        _miniMaxModelNames = names
    }

    func getLastRefreshAt() -> Date? {
        _lastRefreshAt
    }

    // MARK: - Setters

    func setInstances(_ instances: [Instance]) {
        _instances = instances
    }

    func updateSlotData(_ slotViewDataList: [SlotViewData]) {
        _slotViewDataList = slotViewDataList
    }

    func setRefreshState(_ state: RefreshState) {
        _refreshState = state
    }

    func setErrorSummaries(_ summaries: [ErrorSummary]) {
        _errorSummaries = summaries
    }

    func updateSettings(_ settings: GlobalSettings) {
        _globalSettings = settings
    }

    func updateInstance(_ instance: Instance) {
        if let index = _instances.firstIndex(where: { $0.uuid == instance.uuid }) {
            _instances[index] = instance
        }
    }

    func setLastRefreshAt(_ date: Date?) {
        _lastRefreshAt = date
    }

    // MARK: - State Query

    func hasEnabledInstances() -> Bool {
        _instances.contains { $0.enabled }
    }

    func enabledInstanceCount() -> Int {
        _instances.filter { $0.enabled }.count
    }
}