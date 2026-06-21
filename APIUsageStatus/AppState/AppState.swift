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

    /// Merge the just-completed refresh cycle into `_slotViewDataList` in
    /// one atomic operation. Handles three concerns that previously
    /// required a separate "last successful" buffer:
    ///
    ///   1. **Successful fetches** overwrite the existing entry for that
    ///      UUID (or append a new one). The new slot carries `isStale=false`
    ///      so its `colorState` returns the threshold color
    ///      (normal/warning/critical).
    ///   2. **Failed fetches** leave the existing entry in place but flip
    ///      `isStale = true`, which short-circuits the `colorState`
    ///      computed property to `.error`. The cached data is preserved
    ///      so the panel and menu bar can keep showing it (per
    ///      `docs/ARCHITECTURE.md §7.5`).
    ///   3. **Deleted instances** are evicted: any entry whose UUID is
    ///      no longer in `_instances` is dropped. The instance list is
    ///      read inside the actor so callers can't race against a
    ///      concurrent deletion — there is no `currentInstanceUUIDs`
    ///      parameter to capture-stale.
    ///
    /// Fully-failed cycles (empty `cycleSuccesses`) still preserve the
    /// previous buffer; the only effect is flipping each remaining
    /// entry's `isStale = true`.
    ///
    /// Concurrency notes:
    ///   * Actor isolation guarantees this method runs to completion
    ///     before any other call on `AppState` interleaves. The
    ///     `_instances` read below is the authoritative current list.
    ///   * `_slotViewDataList` is built via last-wins dict insertion
    ///     (`byUUID[uuid] = slot`) instead of
    ///     `Dictionary(uniqueKeysWithValues:)` — the latter would
    ///     `fatalError` if a duplicate UUID ever appeared in the
    ///     buffer (a defensive guard against invariant violations; the
    ///     invariant should hold in normal operation).
    func mergeCycleResult(
        cycleSuccesses: [SlotViewData],
        cycleErroredUUIDs: Set<String>
    ) {
        // Read `_instances` inside the actor — no caller-supplied snapshot
        // means no TOCTOU window between a `getInstances()` snapshot and
        // the merge call. A concurrent `updateInstance` from the settings
        // flow will be serialized behind this method.
        let currentUUIDs = Set(_instances.map(\.uuid))

        var byUUID: [String: SlotViewData] = [:]

        // 1. Carry forward existing cached slots (drop any whose
        //    instances were deleted, by UUID comparison to the live
        //    `_instances` snapshot).
        for slot in _slotViewDataList where currentUUIDs.contains(slot.uuid) {
            byUUID[slot.uuid] = slot
        }

        // 2. Apply this cycle's successful slots (isStale=false by default
        //    from `SlotViewData.init`). Last-wins in case the same UUID
        //    somehow appears twice — defensive against a caller bug.
        for slot in cycleSuccesses {
            byUUID[slot.uuid] = slot
        }

        // 3. Mark failed-cycle instances as stale. Keep the cached slot
        //    data so the user still sees their last known values. If the
        //    UUID isn't in the buffer (never succeeded before this
        //    cycle), there's nothing to mark — the entry will be created
        //    on a subsequent successful cycle.
        for uuid in cycleErroredUUIDs {
            guard var slot = byUUID[uuid] else { continue }
            slot.isStale = true
            byUUID[uuid] = slot
        }

        _slotViewDataList = Array(byUUID.values).sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: - State Query

    func hasEnabledInstances() -> Bool {
        _instances.contains { $0.enabled }
    }

    func enabledInstanceCount() -> Int {
        _instances.filter { $0.enabled }.count
    }
}