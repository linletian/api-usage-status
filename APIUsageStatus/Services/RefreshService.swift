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

        refreshTask = Task {
            // Perform initial refresh immediately
            await performRefresh()

            // Then loop with timer
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                if !Task.isCancelled {
                    await performRefresh()
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
                for instance in instancesInGroup {
                    let slotData = mapInstanceToSlotData(instance: instance, response: response)
                    allSlotData.append(slotData)
                }

                // 3e. For MiniMax, extract model names for InstanceEditorView dimension picker
                if instancesInGroup[0].provider == "minimax",
                   let modelNamesStr = response.rawData["_model_names"] {
                    let names = modelNamesStr.split(separator: ",").map(String.init)
                    await appState.setMiniMaxModelNames(names)
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
                        todayUsage: update.snapshot.todayUsage,
                        dailyAverages: displayAverages
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
        await appState.updateSlotData(allSlotData)
        await appState.setErrorSummaries(errorSummaries)
        await appState.setRefreshState(.idle)
        await appState.setLastRefreshAt(Date())

        lastRefreshAt = Date()
        logger.info("Refresh cycle completed: \(allSlotData.count) slots, \(errorSummaries.count) errors")

        // Sync UI immediately — no race window because the closure is awaited directly
        await onRefreshComplete?()
    }

    // MARK: - Helper Methods

    private func mapInstanceToSlotData(instance: Instance, response: SupplierResponse) -> SlotViewData {
        let instanceType: InstanceType
        let colorState: ColorState
        var weekly: WeeklyQuota? = nil
#if DEBUG
        var weeklyDebug: String? = "isQuota=\(instance.isQuotaType) dim=\(instance.dimension)"
#else
        let weeklyDebug: String? = nil
#endif

        if instance.isQuotaType {
            // Quota-type instance
            let dim = instance.dimension
            let valueString = response.value(forDimension: dim) ?? "0"
            let percent = parsePercent(from: valueString)

            // Compute cycle remaining seconds from interval end_time (ms timestamp).
            // The view layer formats this as "Xd" / "Xh Ym" / "Xm" based on magnitude.
            let cycleRemainingSeconds: Int? = {
                if let ets = response.value(forDimension: "\(dim):end_time"),
                   let endTimeMs = Int64(ets), endTimeMs > 0 {
                    let endDate = Date(timeIntervalSince1970: TimeInterval(endTimeMs) / 1000.0)
                    let remaining = endDate.timeIntervalSinceNow
                    return max(0, Int(remaining))
                }
                return nil
            }()

            // Provider-specific display values. Copilot stores absolute
            // credit counts, so the panel shows used/total credits. Other
            // quota providers (MiniMax) only expose a percent from the API
            // — we pass an empty `displayLimit` so the view renders just
            // "<value>%" instead of "<value> / 100" (the "/ 100" is a
            // meaningless constant since the API doesn't expose a real
            // denominator for these providers).
            let displayUsage: String
            let displayLimit: String
            if instance.provider == Provider.githubCopilot.rawValue {
                let entitlement = Int(response.value(forDimension: "\(dim):entitlement") ?? "0") ?? 0
                let remaining = Int(response.value(forDimension: "\(dim):remaining") ?? "0") ?? 0
                let isUnlimited = response.value(forDimension: "\(dim):unlimited") == "true"
                if isUnlimited {
                    displayUsage = "∞"
                    displayLimit = String(entitlement)
                } else {
                    let used = max(0, entitlement - remaining)
                    displayUsage = String(used)
                    displayLimit = String(entitlement)
                }
            } else {
                displayUsage = valueString
                displayLimit = ""
            }

            instanceType = .quota(
                percent: percent,
                usageValue: displayUsage,
                limitValue: displayLimit,
                cycleRemainingSeconds: cycleRemainingSeconds
            )

            colorState = determineColorState(percent: percent, thresholds: instance.thresholds)
            weekly = WeeklyQuota.from(response: response, dimension: dim)
#if DEBUG
            // Build debug string for UI
            let wsKey = "\(dim):weekly_status"
            let wpKey = "\(dim):weekly_percent"
            let wrKey = "\(dim):weekly_remaining"
            let ws = response.value(forDimension: wsKey) ?? "nil"
            let wp = response.value(forDimension: wpKey) ?? "nil"
            let wr = response.value(forDimension: wrKey) ?? "nil"
            weeklyDebug = "dim=\(dim) ws=\(ws) wp=\(wp) wr=\(wr) totalKeys=\(response.rawData.count)"
#endif
        } else {
            // Balance-type instance
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
        }

        return SlotViewData(
            uuid: instance.uuid,
            displayName: instance.displayName,
            shortName: instance.shortName,
            instanceType: instanceType,
            sortOrder: instance.sortOrder,
            colorState: colorState,
            provider: instance.provider,
            weekly: weekly,
            weeklyDebug: weeklyDebug
        )
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