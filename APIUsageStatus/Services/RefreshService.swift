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
            await self.performRefresh()
            // Periodic loop
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                if !Task.isCancelled {
                    await self.performRefresh()
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

    func triggerManualRefresh() async {
        await performRefresh()
    }

    // MARK: - Core Refresh Logic

    private func performRefresh() async {
        logger.info("Starting refresh cycle")

        // 1. Set refresh state to refreshing
        await appState.setRefreshState(.refreshing)

        let instances = await appState.getInstances()
        let enabledInstances = instances.filter { $0.enabled }

        if enabledInstances.isEmpty {
            // No enabled instances - update state and finish
            await appState.updateSlotData([])
            await appState.setRefreshState(.idle)
            lastRefreshAt = Date()
            logger.info("No enabled instances, refresh skipped")
            await onRefreshComplete?()
            return
        }

        // 2. Group instances by api_key_ref
        let groupedByKeyRef = Dictionary(grouping: enabledInstances) { $0.apiKeyRef }
        var allSlotData: [SlotViewData] = []
        var errorSummaries: [ErrorSummary] = []

        // 3. Process each api_key_ref group serially
        for (apiKeyRef, instancesInGroup) in groupedByKeyRef {
            // 3a. Get API key from Keychain
            guard let apiKey = await persistenceService.getApiKey(for: apiKeyRef) else {
                // No API key - mark all instances in this group as error
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

            // 3b. Get supplier for the first instance's provider
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

            // 3c. Fetch usage with retry
            do {
                let response = try await RetryPolicy.shared.withRetry {
                    try await supplier.fetchUsage(apiKey: apiKey)
                }

                // 3d. Map response to each instance's SlotViewData
                let fetchTime = Date()
                for instance in instancesInGroup {
                    var slotData = mapInstanceToSlotData(instance: instance, response: response)
                    slotData.lastFetchedAt = fetchTime
                    allSlotData.append(slotData)
                }

                // 3d-2. For OpenCode, keep the workspace-ID cache fresh so
                //        the "See details" deep link stays correct across
                //        account switches. Fire-and-forget; does not block
                //        the current refresh cycle.
                if let first = instancesInGroup.first,
                   first.provider == Provider.opencode.rawValue {
                    OpenCodeWorkspaceResolver.refreshCache()
                }

                // 3e. For MiniMax, extract model names for InstanceEditorView dimension picker
                if instancesInGroup.first?.provider == Provider.minimax.rawValue,
                   let modelNamesStr = response.rawData["_model_names"] {
                    let names = modelNamesStr.split(separator: ",").map(String.init)
                    await appState.setMiniMaxModelNames(names)

                    // Auto-discover: add 5h + weekly metrics for model names
                    // not yet tracked by any MiniMax instance in this group.
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
                        // Re-map slot data for instances whose metrics changed,
                        // so the menu bar picks up the newly discovered dimensions
                        // immediately instead of on the next refresh.
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
                // Handle fetch error - mark all instances in this group as error
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
            } catch {
                // Unknown error
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

        // 4. For balance-type instances, integrate balance tracking
        let instancesWithBalance = enabledInstances.filter { $0.isBalanceType }
        for instance in instancesWithBalance {
            // Find the corresponding slot data
            if let index = allSlotData.firstIndex(where: { $0.uuid == instance.uuid }) {
                let slot = allSlotData[index]
                if case .balance(let amount, let totalBalance, let grantedBalance, let isAvailable, _) = slot.instanceType {
                    // Load existing balance snapshot
                    let existingSnapshot = await persistenceService.loadBalanceSnapshot(for: instance.uuid)

                    // Determine retention days from thresholds
                    let retentionDays: Int
                    if case .balance(_, _, _, let days) = instance.thresholds {
                        retentionDays = days
                    } else {
                        retentionDays = 0
                    }

                    // Calculate updated snapshot and daily averages
                    let update = BalanceCalculator.update(
                        snapshot: existingSnapshot,
                        currentToppedUp: amount,
                        retentionDays: retentionDays
                    )

                    // Persist updated snapshot immediately
                    do {
                        try await persistenceService.saveBalanceSnapshot(update.snapshot, for: instance.uuid)
                    } catch {
                        logger.error("Failed to save balance snapshot for \(instance.uuid): \(error.localizedDescription)")
                    }

                    // Get configured periods for display
                    var displayPeriods: [AvgDailyPeriod] = []
                    if case .balance(_, _, let periods, _) = instance.thresholds {
                        displayPeriods = periods
                    }

                    // Filter averages to only configured periods
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

                    // Auto-correct currency if response has currency
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

        // 5. Evaluate thresholds and send notifications
        let globalSettings = await appState.getGlobalSettings()
        await notificationManager?.evaluateThresholds(
            instances: await appState.getInstances(),
            slotData: allSlotData,
            settings: globalSettings
        )

        // 6. Update AppState
        await appState.setErrorSummaries(errorSummaries)
        await appState.setRefreshState(.idle)
        await appState.setLastRefreshAt(Date())

        // 7. Merge this cycle's result into `_slotViewDataList` atomically.
        //    The merge reads `appState._instances` internally to detect
        //    deleted-instance UUIDs — no caller-side snapshot needed,
        //    so there's no TOCTOU window between reading instances and
        //    applying the merge. The actor boundary guarantees any
        //    concurrent settings change is serialized behind this call.
        let erroredUUIDs = Set(errorSummaries.map { $0.id })
        await appState.mergeCycleResult(
            cycleSuccesses: allSlotData,
            cycleErroredUUIDs: erroredUUIDs
        )

        lastRefreshAt = Date()
        logger.info("Refresh cycle completed: \(allSlotData.count) slots, \(errorSummaries.count) errors")

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

                // Compute cycle remaining seconds from interval end_time
                // (ms timestamp). The view layer formats this as "Xd" /
                // "Xh Ym" / "Xm" based on magnitude.
                let cycleRemainingSeconds: Int? = {
                    if let ets = response.value(forDimension: "\(key):end_time"),
                       let endTimeMs = Int64(ets), endTimeMs > 0 {
                        let endDate = Date(timeIntervalSince1970: TimeInterval(endTimeMs) / 1000.0)
                        let remaining = endDate.timeIntervalSinceNow
                        return max(0, Int(remaining))
                    }
                    return nil
                }()

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
                    shortName: metricConfig.shortName
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