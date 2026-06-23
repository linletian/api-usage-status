import Foundation

// MARK: - RefreshService

actor RefreshService {
    private let persistenceService: PersistenceService
    private let appState: AppState
    private var notificationManager: NotificationManager?
    private var refreshTask: Task<Void, Never>?
    private var refreshInterval: TimeInterval = 300 // 5 minutes default
    private var lastRefreshAt: Date?
    private var onRefreshComplete: (@Sendable () async -> Void)?

    /// Currently in-flight `performRefresh` task. There is at most ONE
    /// cycle running at a time — manual Refresh preempts by cancelling
    /// the previous one, while the periodic timer and per-instance click
    /// either wait or no-op (see `runPeriodicCycle` /
    /// `triggerInstanceRefresh`).
    private var cycleTask: Task<Void, Error>?

    /// Identity of the currently in-flight cycle, or `nil` when idle.
    /// Each cycle launches with a fresh `CycleToken`; the coordinator
    /// flips the previous token's `isPreempted` flag before assigning the
    /// new one, so the pre-empted cycle's `performRefresh` can detect
    /// that its slot has been taken over and skip its cleanup writes.
    private var currentToken: CycleToken?

    /// Identity + preemptability of a single in-flight cycle. Replaces
    /// the previous `cycleGeneration: Int` counter — `isPreempted` is set
    /// by the coordinator (`runPreemptiveCycle`) when a newer cycle takes
    /// over, and `performRefresh` skips cleanup writes once it observes
    /// the flag. Reference semantics let the cleanup sites compare with
    /// `token.isPreempted` without passing a separate generation number.
    private final class CycleToken {
        let targetUUID: String?
        private(set) var isPreempted: Bool = false

        init(targetUUID: String?) {
            self.targetUUID = targetUUID
        }

        /// Called by the coordinator synchronously when this token is
        /// being replaced. After this returns, `performRefresh` must skip
        /// every cleanup write — a newer owner already holds the slot.
        func markPreempted() {
            isPreempted = true
        }
    }

    /// Adopt a newly launched cycle as the current slot. Both
    /// `currentToken` and `cycleTask` move together so callers never see
    /// one without the other.
    private func adoptCycle(token: CycleToken, task: Task<Void, Error>) {
        currentToken = token
        cycleTask = task
    }

    /// Clear the slot only if `token` is still the current owner. A newer
    /// cycle that took over during this one's unwind would have replaced
    /// both `currentToken` and `cycleTask`, so the identity check is what
    /// prevents the pre-empted cycle from clobbering the new owner.
    private func clearCycleIfStill(_ token: CycleToken) {
        if currentToken === token {
            currentToken = nil
            cycleTask = nil
        }
    }

    private let logger = AppLogger(category: "refresh")

    init(persistenceService: PersistenceService, appState: AppState) {
        self.persistenceService = persistenceService
        self.appState = appState
    }

    /// Injects the notification manager so threshold alerts can be dispatched
    /// after each refresh cycle. Setter avoids circular dependency during init.
    func setNotificationManager(_ manager: NotificationManager) {
        self.notificationManager = manager
    }

    /// Inject a closure to be called after every refresh cycle completes.
    /// Used by AppStateProxy to sync @Published properties immediately.
    func setOnRefreshComplete(_ handler: (@Sendable () async -> Void)?) {
        self.onRefreshComplete = handler
    }

    // MARK: - Timer Control

    func start(interval: TimeInterval? = nil) {
        if let interval = interval {
            refreshInterval = interval * 60 // Convert minutes to seconds
        }

        stop() // Cancel any existing task

        // Capture the interval locally so the Task doesn't read the actor
        // property across isolation domains. The captured value stays
        // stable for the lifetime of this timer cycle — restartTimer
        // always calls stop()+start() to begin a fresh cycle.
        let intervalSeconds = refreshInterval

        refreshTask = Task { [weak self] in
            guard let self = self else { return }
            // Initial refresh immediately
            await self.runPeriodicCycle()
            // Periodic loop
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                if !Task.isCancelled {
                    await self.runPeriodicCycle()
                }
            }
        }

        logger.info("RefreshService started with interval: \(self.refreshInterval)s")
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        logger.info("RefreshService stopped")
    }

    func restartTimer(interval: TimeInterval) {
        refreshInterval = interval * 60
        start() // Will stop existing and restart
    }

    // MARK: - Manual Trigger

    /// User-initiated refresh from the panel button. Always preemptive —
    /// any in-flight cycle (whether started by the periodic timer, a
    /// prior manual click, or a per-instance click) is cancelled and a
    /// fresh full refresh begins. Awaited synchronously so the caller
    /// knows when the click has been fully processed.
    func triggerManualRefresh() async {
        await runPreemptiveCycle(targetUUID: nil)
    }

    /// User-initiated refresh of a single instance from its status dot.
    /// No-op if any refresh is already running — the dot is a "补刷新"
    /// gesture and must not preempt a cycle (per design decision:
    /// preemption is reserved for the explicit Refresh button). This
    /// preserves the user's expectation that a periodic or other manual
    /// refresh they just started will finish uninterrupted.
    func triggerInstanceRefresh(instanceUUID: String) async {
        guard currentToken == nil else { return }
        await runPreemptiveCycle(targetUUID: instanceUUID)
    }

    /// Periodic timer entry point. Non-preemptive: if a cycle is
    /// already in flight (e.g., a manual click started one), this
    /// iteration is skipped — the next tick will check again. This
    /// avoids duplicate cycles when a user clicks manual right before
    /// the periodic tick fires.
    private func runPeriodicCycle() async {
        guard currentToken == nil else { return }
        let token = CycleToken(targetUUID: nil)
        let task = Task<Void, Error> { try await self.performRefresh(targetUUID: nil, token: token) }
        adoptCycle(token: token, task: task)
        do {
            try await task.value
        } catch {
            // Cancellation from a manual preempt, or a thrown
            // CancellationError from cooperative checks. Don't propagate —
            // the manual path that cancelled us owns the slot now.
            logger.info("Periodic cycle ended: \(error)")
        }
        clearCycleIfStill(token)
    }

    /// Manual / per-instance entry point. Preemptive: cancels any
    /// in-flight cycle, waits for it to unwind, then starts a new one
    /// targeting `targetUUID` (nil = full refresh, non-nil = per-instance).
    ///
    /// Order is important: the old token is marked preempted BEFORE the
    /// new token is created, so any cleanup the old task does after
    /// observing its token's flag will skip writes. The slot is adopted
    /// BEFORE awaiting the cancelled old one, so during the await window
    /// `runPeriodicCycle` sees a non-nil slot and skips its tick.
    private func runPreemptiveCycle(targetUUID: String?) async {
        // 1. Mark the previous owner preempted synchronously. This runs
        //    before any `await`, so by the time the old cycle gets a
        //    chance to observe its token it is already flagged and its
        //    cleanup writes will skip.
        currentToken?.markPreempted()

        // 2. Capture old task handle for later await + cancel.
        let oldTask = cycleTask

        // 3. Build the new cycle.
        let newToken = CycleToken(targetUUID: targetUUID)
        let task = Task<Void, Error> { try await self.performRefresh(targetUUID: targetUUID, token: newToken) }

        // 4. Publish the new owner before any await — `runPeriodicCycle`
        //    racing in via `currentToken == nil` will now see this one
        //    and skip.
        adoptCycle(token: newToken, task: task)

        // 5. Cancel the old task. Its `performRefresh` may still be
        //    running; cancellation is cooperative and may take effect
        //    at the next `Task.checkCancellation()` or `await` on
        //    URLSession / Shell.
        oldTask?.cancel()

        // 6. Wait for the old task to unwind. We capture non-cancellation
        //    errors here: previously `try?` silently dropped them, so a
        //    genuine fault (e.g. Keychain crash, parse bug) that surfaced
        //    while being pre-empted was lost with no log. Cancellation
        //    itself is the expected path and stays quiet.
        if let oldTask = oldTask {
            do {
                try await oldTask.value
            } catch is CancellationError {
                // Expected: the cycle was pre-empted.
            } catch {
                logger.error("Pre-empted cycle threw non-cancellation error: \(error)")
            }
        }

        // 7. Wait for the new cycle. The only expected throw is
        //    CancellationError (when ANOTHER manual click came in while
        //    we were running). The newer click already owns the slot —
        //    we just log.
        do {
            try await task.value
        } catch {
            logger.info("Preemptive cycle ended: \(error)")
        }

        // 8. Clear the slot only if we're still the current owner.
        clearCycleIfStill(newToken)
    }

    // MARK: - Core Refresh Logic

    private func performRefresh(targetUUID: String? = nil, token: CycleToken) async throws {
        logger.info("Starting refresh cycle targetUUID=\(targetUUID ?? "all") token=\(ObjectIdentifier(token))")

        // 1. Set refresh state to refreshing
        await appState.setRefreshState(.refreshing)

        let instances = await appState.getInstances()
        let enabledInstances = instances.filter { $0.enabled }

        // 2. Resolve targets — full cycle (targetUUID == nil) or single
        //    instance (targetUUID set). For per-instance, if the target is
        //    missing or disabled, we silently bail without touching any
        //    other state.
        let targetInstances: [Instance]
        if let uuid = targetUUID {
            targetInstances = enabledInstances.filter { $0.uuid == uuid }
            if targetInstances.isEmpty {
                logger.info("Target instance \(uuid) not found or not enabled; skipping")
                // Token-preempted: if a newer cycle pre-empted us, it
                // owns `refreshState`. Don't reset it on their behalf.
                if !token.isPreempted {
                    await appState.setRefreshState(.idle)
                    await onRefreshComplete?()
                }
                return
            }
        } else {
            targetInstances = enabledInstances
        }

        let targetUUIDs = Set(targetInstances.map { $0.uuid })
        await appState.setRefreshingInstanceUUIDs(targetUUIDs)
        // Push the new "refreshing" set to the UI BEFORE doing any work,
        // otherwise the per-instance dot spinner never appears — UI only
        // observes this field via `AppStateProxy.syncFromState()`,
        // which historically ran only at cycle end (by then the set is
        // already cleared back to []). See ARCHITECTURE.md §9.2.
        await onRefreshComplete?()
        // Cleanup is done explicitly at every exit point (no `defer`):
        // Swift 5.9 doesn't allow `await` inside a `defer` body, and a
        // `Task { }` wrapper would race against the next cycle's set
        // and clobber its UUID set.

        if targetInstances.isEmpty {
            // Global path with no enabled instances — reset everything,
            // but only if we're still the current cycle. If a newer
            // cycle pre-empted us (token.isPreempted), it owns the
            // state — touching it here would clobber its writes.
            if !token.isPreempted {
                await appState.setRefreshingInstanceUUIDs([])
                await onRefreshComplete?()
                await appState.updateSlotData([])
                await appState.setRefreshState(.idle)
                await onRefreshComplete?()
            }
            lastRefreshAt = Date()
            logger.info("No enabled instances, refresh skipped")
            return
        }

        // 3. Group targets by api_key_ref. Note: a supplier call fetches
        //    data for the whole key group, but `instancesInGroup` is
        //    already filtered to `targetInstances` — siblings outside the
        //    target (for per-instance) are NOT in this group and won't
        //    have their slot data refreshed.
        let groupedByKeyRef = Dictionary(grouping: targetInstances) { $0.apiKeyRef }
        var allSlotData: [SlotViewData] = []
        var errorSummaries: [ErrorSummary] = []

        // 4. Process each api_key_ref group serially
        for (apiKeyRef, instancesInGroup) in groupedByKeyRef {
            // Cooperative cancellation — propagate Task.cancel() promptly
            // so a manual Refresh can interrupt within one supplier call.
            try Task.checkCancellation()

            // 4a. Get API key from Keychain
            guard let apiKey = await persistenceService.getApiKey(for: apiKeyRef) else {
                for instance in instancesInGroup {
                    let error = ErrorSummary(
                        id: instance.uuid,
                        displayName: instance.displayName.isEmpty ? instance.shortName : instance.displayName,
                        errorType: .authFailed
                    )
                    errorSummaries.append(error)
                }
                logger.warning("No API key found for ref: \(apiKeyRef)")
                continue
            }

            // 4b. Get supplier for the first instance's provider
            guard let supplier = SupplierRegistry.getSupplier(for: instancesInGroup[0].provider) else {
                for instance in instancesInGroup {
                    let error = ErrorSummary(
                        id: instance.uuid,
                        displayName: instance.displayName.isEmpty ? instance.shortName : instance.displayName,
                        errorType: .apiError(code: 0)
                    )
                    errorSummaries.append(error)
                }
                continue
            }

            // 4c. Fetch usage with retry
            do {
                let response = try await RetryPolicy.shared.withRetry {
                    try await supplier.fetchUsage(apiKey: apiKey)
                }

                // 4d. Map response to each instance in the (already
                //     filtered) group. Only target instances get slot data.
                let fetchTime = Date()
                for instance in instancesInGroup {
                    var slotData = mapInstanceToSlotData(instance: instance, response: response)
                    slotData.lastFetchedAt = fetchTime
                    allSlotData.append(slotData)
                }

                // 4d-2. OpenCode workspace cache refresh — fire-and-forget,
                //        doesn't mutate other instances' state. Keep for
                //        both global and per-instance paths.
                if let first = instancesInGroup.first,
                   first.provider == Provider.opencode.rawValue {
                    OpenCodeWorkspaceResolver.refreshCache()
                }

                // 4e. MiniMax model auto-discover — only on global path.
                //     Per-instance refresh must not mutate other instances'
                //     metrics, so we skip this branch when targeting a
                //     single instance.
                if targetUUID == nil,
                   instancesInGroup.first?.provider == Provider.minimax.rawValue,
                   let modelNamesStr = response.rawData["_model_names"] {
                    let names = modelNamesStr.split(separator: ",").map(String.init)
                    await appState.setMiniMaxModelNames(names)

                    var autoDiscoveredUUIDs: Set<String> = []
                    for var instance in instancesInGroup where instance.provider == Provider.minimax.rawValue {
                        let existingGroups = Set(instance.metrics.compactMap { $0.group }).filter { !$0.isEmpty }
                        let newGroups = names.filter { !existingGroups.contains($0) }
                        guard !newGroups.isEmpty else { continue }
                        for name in newGroups {
                            instance.metrics.append(MetricConfig(key: name, group: name, window: "5h"))
                            instance.metrics.append(MetricConfig(key: "\(name):weekly_percent", group: name, window: "weekly"))
                        }
                        await appState.updateInstance(instance)
                        autoDiscoveredUUIDs.insert(instance.uuid)
                        logger.info("Auto-discovered \(newGroups.count) MiniMax model(s) for \(instance.shortName): \(newGroups.joined(separator: ", "))")
                    }
                    if !autoDiscoveredUUIDs.isEmpty {
                        let updatedInstances = await appState.getInstances()
                        for uuid in autoDiscoveredUUIDs {
                            guard let updated = updatedInstances.first(where: { $0.uuid == uuid }) else { continue }
                            var newSlot = mapInstanceToSlotData(instance: updated, response: response)
                            newSlot.lastFetchedAt = fetchTime
                            if let idx = allSlotData.firstIndex(where: { $0.uuid == uuid }) {
                                allSlotData[idx] = newSlot
                            }
                        }

                        let settings = await appState.getGlobalSettings()
                        try? await persistenceService.saveInstances(updatedInstances, settings: settings)
                    }
                }
            } catch let error as RefreshError {
                let errorType = error.errorType
                for instance in instancesInGroup {
                    let summary = ErrorSummary(
                        id: instance.uuid,
                        displayName: instance.displayName.isEmpty ? instance.shortName : instance.displayName,
                        errorType: errorType
                    )
                    errorSummaries.append(summary)
                }
                logger.error("Refresh failed for \(apiKeyRef): \(error)")
            } catch is CancellationError {
                // Propagate cancellation so the cycleTask wrapper can
                // observe it. Clean up refreshing UUIDs and refreshState
                // before re-throwing — we won't reach the success-path
                // cleanup. Both writes are token-preempted: if a newer
                // cycle pre-empted us, it already owns these fields and
                // touching them would clobber its set.
                if !token.isPreempted {
                    await appState.setRefreshingInstanceUUIDs([])
                    await appState.setRefreshState(.idle)
                    // Push the cleared state to UI before propagating;
                    // the cycleTask wrapper that catches our rethrow
                    // only logs, so without this the spinner stays stuck
                    // and `refreshState` stays at `.refreshing`.
                    await onRefreshComplete?()
                }
                throw CancellationError()
            } catch {
                for instance in instancesInGroup {
                    let summary = ErrorSummary(
                        id: instance.uuid,
                        displayName: instance.displayName.isEmpty ? instance.shortName : instance.displayName,
                        errorType: .apiError(code: 0)
                    )
                    errorSummaries.append(summary)
                }
                logger.error("Unexpected error during refresh: \(error.localizedDescription)")
            }
        }

        // 5. For balance-type instances — only targets.
        let instancesWithBalance = targetInstances.filter { $0.isBalanceType }
        for instance in instancesWithBalance {
            if let index = allSlotData.firstIndex(where: { $0.uuid == instance.uuid }) {
                let slot = allSlotData[index]
                if case .balance(let amount, let totalBalance, let grantedBalance, let isAvailable, _) = slot.instanceType {
                    let existingSnapshot = await persistenceService.loadBalanceSnapshot(for: instance.uuid)

                    let retentionDays: Int
                    if case .balance(_, _, _, let days) = instance.thresholds {
                        retentionDays = days
                    } else {
                        retentionDays = 0
                    }

                    let update = BalanceCalculator.update(
                        snapshot: existingSnapshot,
                        currentToppedUp: amount,
                        retentionDays: retentionDays
                    )

                    do {
                        try await persistenceService.saveBalanceSnapshot(update.snapshot, for: instance.uuid)
                    } catch {
                        logger.error("Failed to save balance snapshot for \(instance.uuid): \(error.localizedDescription)")
                    }

                    var displayPeriods: [AvgDailyPeriod] = []
                    if case .balance(_, _, let periods, _) = instance.thresholds {
                        displayPeriods = periods
                    }

                    let displayAverages: [AvgDailyPeriod: Decimal]
                    if displayPeriods.isEmpty {
                        displayAverages = [:]
                    } else {
                        displayAverages = update.dailyAverages.filter { displayPeriods.contains($0.key) }
                    }

                    let updatedSlot = SlotViewData(
                        uuid: slot.uuid,
                        displayName: instance.displayName,
                        shortName: slot.shortName,
                        instanceType: .balance(
                            amount: amount,
                            totalBalance: totalBalance,
                            grantedBalance: grantedBalance,
                            isAvailable: isAvailable,
                            currency: instance.currency
                        ),
                        sortOrder: slot.sortOrder,
                        colorState: slot.colorState,
                        provider: instance.provider,
                        dimension: slot.dimension,
                        todayUsage: update.snapshot.todayUsage,
                        dailyAverages: displayAverages,
                        lastFetchedAt: slot.lastFetchedAt ?? Date()
                    )
                    allSlotData[index] = updatedSlot

                    if let responseCurrency = getCurrencyFromSlotData(allSlotData, instanceUUID: instance.uuid) {
                        if instance.currency != responseCurrency {
                            var updatedInstance = instance
                            updatedInstance.currency = responseCurrency
                            await appState.updateInstance(updatedInstance)
                            logger.info("Auto-corrected currency from \(instance.currency ?? "nil") to \(responseCurrency)")
                        }
                    }
                }
            }
        }

        // Sort by sortOrder
        allSlotData.sort { $0.sortOrder < $1.sortOrder }

        // 6. Evaluate thresholds and send notifications. Use the full
        //    instance list (not just targets) so per-instance refresh can
        //    still trigger notifications for that instance if a threshold
        //    was crossed by the fresh data.
        let globalSettings = await appState.getGlobalSettings()
        await notificationManager?.evaluateThresholds(
            instances: await appState.getInstances(),
            slotData: allSlotData,
            settings: globalSettings
        )

        // 7. Update error summaries. For global refresh we replace
        //    wholesale; for per-instance we must preserve other
        //    instances' errors so a click on one dot doesn't clear
        //    another instance's failure state. Token-preempted: a
        //    pre-empted old cycle must not overwrite a newer cycle's
        //    error set.
        if !token.isPreempted {
            if targetUUID == nil {
                await appState.setErrorSummaries(errorSummaries)
            } else {
                let currentErrors = await appState.getErrorSummaries()
                let otherErrors = currentErrors.filter { $0.id != targetUUID }
                await appState.setErrorSummaries(otherErrors + errorSummaries)
            }

            await appState.setRefreshState(.idle)
            await appState.setLastRefreshAt(Date())
        }

        // 8. Merge this cycle's result into `_slotViewDataList` atomically.
        //    For per-instance, `allSlotData` only contains the target so
        //    siblings' cached slots are preserved unchanged.
        //    Token-preempted so a pre-empted old cycle does not overwrite
        //    a newer cycle's merged slots.
        if !token.isPreempted {
            let erroredUUIDs = Set(errorSummaries.map { $0.id })
            await appState.mergeCycleResult(
                cycleSuccesses: allSlotData,
                cycleErroredUUIDs: erroredUUIDs
            )
        }

        lastRefreshAt = Date()
        logger.info("Refresh cycle completed: \(allSlotData.count) slots, \(errorSummaries.count) errors")

        // Clear the in-flight spinner before notifying the UI so the
        // sync picks up `refreshingInstanceUUIDs == []` instead of an
        // inconsistent intermediate state. Token-preempted for the same
        // reason as above.
        if !token.isPreempted {
            await appState.setRefreshingInstanceUUIDs([])
        }

        // Sync UI immediately — no race window because the closure is awaited directly
        await onRefreshComplete?()
    }

    // MARK: - Helper Methods

    func mapInstanceToSlotData(instance: Instance, response: SupplierResponse) -> SlotViewData {
#if DEBUG
        var weeklyDebug: String? = "isQuota=\(instance.isQuotaType) dim=\(instance.dimension)"
#else
        let weeklyDebug: String? = nil
#endif

        if instance.isQuotaType {
            // Quota-type instance: iterate instance.metrics to produce one
            // MetricSnapshot per MetricConfig (1:N mapping). The first
            // snapshot drives instanceType, dimension, colorState; the
            // first snapshot with window=="weekly" drives the weekly bar.
            var metricSnapshots: [MetricSnapshot] = []

            for (index, metricConfig) in instance.metrics.enumerated() {
                let configIndex = index + 1
                let key = metricConfig.key

                let valueString = response.value(forDimension: key) ?? "0"
                let percent = parsePercent(from: valueString)

                // Resolve the window's absolute end time from the supplier's
                // `<key>:end_time` rawData (ms epoch). The view layer uses
                // `cycleEndTime` with `TimelineView` to render a live
                // "Xh Ym remaining" countdown; `cycleRemainingSeconds` is
                // the static-at-refresh derived copy kept for callers
                // (e.g. `SlotViewData.instanceType`) that don't have a
                // current `Date()` to subtract against.
                let cycleEndTime: Date? = {
                    guard let ets = response.value(forDimension: "\(key):end_time"),
                          let endTimeMs = Int64(ets), endTimeMs > 0 else { return nil }
                    return Date(timeIntervalSince1970: TimeInterval(endTimeMs) / 1000.0)
                }()
                let cycleRemainingSeconds: Int? = cycleEndTime.map {
                    max(0, Int($0.timeIntervalSinceNow))
                }

                // Provider-specific display values. Copilot stores absolute
                // credit counts, so the panel shows used/total credits.
                // OpenCode exposes both used and limit in dollars (the
                // supplier pre-formats them as "%.2f" strings). MiniMax
                // only exposes a percent from the API — we pass an empty
                // `displayLimit` so the view renders just "<value>%" instead
                // of "<value> / 100" (the "/ 100" is a meaningless constant
                // since the API doesn't expose a real denominator for these
                // providers).
                let displayUsage: String
                let displayLimit: String
                if instance.provider == Provider.githubCopilot.rawValue {
                    let entitlement = Int(response.value(forDimension: "\(key):entitlement") ?? "0") ?? 0
                    let remaining = Int(response.value(forDimension: "\(key):remaining") ?? "0") ?? 0
                    let isUnlimited = response.value(forDimension: "\(key):unlimited") == "true"
                    if isUnlimited {
                        displayUsage = "∞"
                        displayLimit = String(entitlement)
                    } else {
                        let used = max(0, entitlement - remaining)
                        displayUsage = String(used)
                        displayLimit = String(entitlement)
                    }
                } else if instance.provider == Provider.opencode.rawValue {
                    let used = response.value(forDimension: "\(key):used") ?? "0"
                    let limit = response.value(forDimension: "\(key):limit") ?? "0"
                    displayUsage = "$\(used)"
                    displayLimit = "$\(limit)"
                } else {
                    displayUsage = valueString
                    displayLimit = ""
                }

                let colorState = determineColorState(percent: percent, thresholds: instance.thresholds)

                // Unlimited-plan detection for weekly windows.
                // MiniMax: current_weekly_status != 1 means the plan
                // does not enforce a weekly limit (e.g. legacy / grandfathered
                // plans). The UI renders a flowing glow bar instead of a
                // progress bar.
                let isUnlimited: Bool
                if metricConfig.window == "weekly", let group = metricConfig.group {
                    let statusKey = "\(group):weekly_status"
                    let statusString = response.value(forDimension: statusKey) ?? "1"
                    isUnlimited = Int(statusString) != 1
                } else if instance.provider == Provider.githubCopilot.rawValue {
                    isUnlimited = response.value(forDimension: "\(key):unlimited") == "true"
                } else {
                    isUnlimited = false
                }

                metricSnapshots.append(MetricSnapshot(
                    key: key,
                    group: metricConfig.group,
                    window: metricConfig.window,
                    percent: percent,
                    displayUsage: displayUsage,
                    displayLimit: displayLimit,
                    cycleRemainingSeconds: cycleRemainingSeconds,
                    colorState: colorState,
                    configIndex: configIndex,
                    displayInMenuBar: metricConfig.displayInMenuBar,
                    isUnlimited: isUnlimited,
                    shortName: metricConfig.shortName,
                    cycleEndTime: cycleEndTime
                ))
            }

#if DEBUG
            // Build debug string for UI
            let dim = instance.dimension
            let wsKey = "\(dim):weekly_status"
            let wpKey = "\(dim):weekly_percent"
            let wrKey = "\(dim):weekly_remaining"
            let ws = response.value(forDimension: wsKey) ?? "nil"
            let wp = response.value(forDimension: wpKey) ?? "nil"
            let wr = response.value(forDimension: wrKey) ?? "nil"
            weeklyDebug = "dim=\(dim) ws=\(ws) wp=\(wp) wr=\(wr) totalKeys=\(response.rawData.count)"
#endif

            return SlotViewData(
                uuid: instance.uuid,
                displayName: instance.displayName,
                shortName: instance.shortName,
                sortOrder: instance.sortOrder,
                provider: instance.provider,
                metricSnapshots: metricSnapshots,
                weeklyDebug: weeklyDebug
            )
        } else {
            // Balance-type instance
            let instanceType: InstanceType
            let colorState: ColorState

            let balance = response.value(forDimension: "balance") ?? "0"
            let totalBalance = response.value(forDimension: "total_balance") ?? balance
            let grantedBalance = response.value(forDimension: "granted_balance") ?? "0"

            if !response.isAvailable {
                instanceType = .balance(
                    amount: balance,
                    totalBalance: totalBalance,
                    grantedBalance: grantedBalance,
                    isAvailable: false,
                    currency: response.currency
                )
                colorState = .unavailable
            } else {
                instanceType = .balance(
                    amount: balance,
                    totalBalance: totalBalance,
                    grantedBalance: grantedBalance,
                    isAvailable: true,
                    currency: response.currency
                )
                colorState = determineBalanceColorState(balance: balance, thresholds: instance.thresholds)
            }

            return SlotViewData(
                uuid: instance.uuid,
                displayName: instance.displayName,
                shortName: instance.shortName,
                instanceType: instanceType,
                sortOrder: instance.sortOrder,
                colorState: colorState,
                provider: instance.provider,
                dimension: instance.dimension,
                weeklyDebug: weeklyDebug
            )
        }
    }

    private func parsePercent(from value: String) -> Double {
        // Handle formats like "85", "85.5", "85.5%"
        let cleaned = value.replacingOccurrences(of: "%", with: "").trimmed
        return Double(cleaned) ?? 0.0
    }

    private func determineColorState(percent: Double, thresholds: Thresholds) -> ColorState {
        switch thresholds {
        case .quota(let warningPercent, let criticalPercent):
            if percent >= Double(criticalPercent) {
                return .critical
            } else if percent >= Double(warningPercent) {
                return .warning
            }
            return .normal
        case .balance:
            return .normal
        }
    }

    private func determineBalanceColorState(balance: String, thresholds: Thresholds) -> ColorState {
        guard case .balance(let warning, let critical, _, _) = thresholds else {
            return .normal
        }

        guard let balanceDecimal = Decimal(string: balance) else {
            return .normal
        }

        if balanceDecimal < critical {
            return .critical
        } else if balanceDecimal < warning {
            return .warning
        }
        return .normal
    }

    private func getCurrencyFromSlotData(_ slots: [SlotViewData], instanceUUID: String) -> String? {
        slots.first { $0.uuid == instanceUUID }.flatMap { slot in
            if case .balance(_, _, _, _, let currency) = slot.instanceType {
                return currency
            }
            return nil
        }
    }
}