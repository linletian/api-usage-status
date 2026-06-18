import XCTest
@testable import APIUsageStatus

/// Behavior-lock tests for RefreshService.mapInstanceToSlotData under the
/// 1:N mapping model: Instance.metrics → SlotViewData.metricSnapshots.
///
/// Each test constructs SupplierResponse fixtures mirroring actual supplier
/// output shapes and verifies that every MetricConfig produces one
/// MetricSnapshot with correct runtime values.
final class RefreshServiceMappingTests: XCTestCase {

    // MARK: - MiniMax: 2 MetricConfigs → 2 MetricSnapshots

    func testMiniMaxTwoMetricsProducesTwoSnapshots() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )

        let metrics: [MetricConfig] = [
            MetricConfig(key: "general", group: "general", window: nil),
            MetricConfig(key: "general:weekly_percent", group: "general", window: "weekly"),
        ]

        let instance = Instance(
            uuid: "mini-general-1",
            provider: Provider.minimax.rawValue,
            dimension: "general",
            metrics: metrics,
            displayName: "MiniMax General",
            shortName: "MG",
            apiKeyRef: "minimax-key",
            enabled: true,
            sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )

        let endTimeMs: Int64 = Int64(
            Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        )
        var rawData: [String: String] = [:]
        rawData["general"] = "99.0"
        rawData["general:status"] = "1"
        rawData["general:remaining"] = "99.0"
        rawData["general:weekly_status"] = "3"
        rawData["general:weekly_percent"] = "100"
        rawData["general:weekly_remaining"] = "100.0"
        rawData["general:end_time"] = String(endTimeMs)

        let response = SupplierResponse(rawData: rawData, currency: nil, isAvailable: true)

        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response
        )

        // Identity
        XCTAssertEqual(result.uuid, "mini-general-1")
        XCTAssertEqual(result.provider, Provider.minimax.rawValue)

        // 1:N mapping: 2 MetricConfigs → 2 MetricSnapshots
        XCTAssertEqual(result.metricSnapshots.count, 2,
                       "2 MetricConfigs should produce 2 MetricSnapshots")

        // --- First snapshot: 5h quota (key="general") ---
        let s0 = result.metricSnapshots[0]
        XCTAssertEqual(s0.key, "general")
        XCTAssertEqual(s0.group, "general")
        XCTAssertNil(s0.window)
        XCTAssertEqual(s0.percent, 99.0, accuracy: 0.01)
        XCTAssertEqual(s0.displayUsage, "99.0")
        XCTAssertEqual(s0.displayLimit, "")
        XCTAssertNotNil(s0.cycleRemainingSeconds)
        XCTAssertGreaterThan(s0.cycleRemainingSeconds!, 0)
        XCTAssertEqual(s0.colorState, .critical, "99% ≥ 95 critical threshold")
        XCTAssertEqual(s0.configIndex, 1)

        // --- Second snapshot: weekly window ---
        let s1 = result.metricSnapshots[1]
        XCTAssertEqual(s1.key, "general:weekly_percent")
        XCTAssertEqual(s1.group, "general")
        XCTAssertEqual(s1.window, "weekly")
        XCTAssertEqual(s1.percent, 100.0, accuracy: 0.01)
        XCTAssertEqual(s1.displayUsage, "100")
        XCTAssertEqual(s1.displayLimit, "")
        XCTAssertEqual(s1.configIndex, 2)

        // --- Computed properties derive from first snapshot ---
        XCTAssertEqual(result.dimension, "general")
        XCTAssertEqual(result.colorState, .critical)
        guard case .quota(let p, let u, let l, let crs) = result.instanceType else {
            XCTFail("Expected quota instance type, got \(result.instanceType)")
            return
        }
        XCTAssertEqual(p, 99.0, accuracy: 0.01)
        XCTAssertEqual(u, "99.0")
        XCTAssertEqual(l, "")
        XCTAssertNotNil(crs)
    }

    // MARK: - OpenCode: 3 MetricConfigs → 3 MetricSnapshots

    func testOpenCodeThreeMetricsProducesThreeSnapshots() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )

        let metrics: [MetricConfig] = [
            MetricConfig(key: "5h", group: nil, window: "5h"),
            MetricConfig(key: "weekly", group: nil, window: "weekly"),
            MetricConfig(key: "monthly", group: nil, window: "monthly"),
        ]

        let instance = Instance(
            uuid: "oc-1",
            provider: Provider.opencode.rawValue,
            dimension: "5h",
            metrics: metrics,
            displayName: "OpenCode",
            shortName: "OC",
            apiKeyRef: "opencode-placeholder",
            enabled: true,
            sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )

        let endTimeMs: Int64 = Int64(
            Date().addingTimeInterval(7200).timeIntervalSince1970 * 1000
        )
        var rawData: [String: String] = [:]

        rawData["5h"] = "70.8"
        rawData["5h:used"] = "8.50"
        rawData["5h:limit"] = "12.00"
        rawData["5h:end_time"] = String(endTimeMs)

        rawData["weekly"] = "50.0"
        rawData["weekly:used"] = "15.00"
        rawData["weekly:limit"] = "30.00"
        rawData["weekly:end_time"] = String(endTimeMs)

        rawData["monthly"] = "58.3"
        rawData["monthly:used"] = "35.00"
        rawData["monthly:limit"] = "60.00"
        rawData["monthly:end_time"] = String(endTimeMs)

        let response = SupplierResponse(
            rawData: rawData, currency: "USD", isAvailable: true
        )

        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response
        )

        // 1:N mapping: 3 MetricConfigs → 3 MetricSnapshots
        XCTAssertEqual(result.metricSnapshots.count, 3,
                       "3 MetricConfigs should produce 3 MetricSnapshots")

        XCTAssertEqual(result.uuid, "oc-1")
        XCTAssertEqual(result.provider, Provider.opencode.rawValue)

        // --- Snapshot 0: 5h ---
        let s0 = result.metricSnapshots[0]
        XCTAssertEqual(s0.key, "5h")
        XCTAssertEqual(s0.window, "5h")
        XCTAssertEqual(s0.percent, 70.8, accuracy: 0.01)
        XCTAssertEqual(s0.displayUsage, "$8.50")
        XCTAssertEqual(s0.displayLimit, "$12.00")
        XCTAssertNotNil(s0.cycleRemainingSeconds)
        XCTAssertEqual(s0.colorState, .normal)
        XCTAssertEqual(s0.configIndex, 1)

        // --- Snapshot 1: weekly ---
        let s1 = result.metricSnapshots[1]
        XCTAssertEqual(s1.key, "weekly")
        XCTAssertEqual(s1.window, "weekly")
        XCTAssertEqual(s1.percent, 50.0, accuracy: 0.01)
        XCTAssertEqual(s1.displayUsage, "$15.00")
        XCTAssertEqual(s1.displayLimit, "$30.00")
        XCTAssertNotNil(s1.cycleRemainingSeconds)
        XCTAssertEqual(s1.configIndex, 2)

        // --- Snapshot 2: monthly ---
        let s2 = result.metricSnapshots[2]
        XCTAssertEqual(s2.key, "monthly")
        XCTAssertEqual(s2.window, "monthly")
        XCTAssertEqual(s2.percent, 58.3, accuracy: 0.01)
        XCTAssertEqual(s2.displayUsage, "$35.00")
        XCTAssertEqual(s2.displayLimit, "$60.00")
        XCTAssertNotNil(s2.cycleRemainingSeconds)
        XCTAssertEqual(s2.configIndex, 3)

        // --- Computed: first snapshot drives instanceType / colorState ---
        guard case .quota(let p, let u, let l, let crs) = result.instanceType else {
            XCTFail("Expected quota instance type, got \(result.instanceType)")
            return
        }
        XCTAssertEqual(p, 70.8, accuracy: 0.01)
        XCTAssertEqual(u, "$8.50")
        XCTAssertEqual(l, "$12.00")
        XCTAssertNotNil(crs)
        XCTAssertEqual(result.colorState, .normal)
        XCTAssertEqual(result.dimension, "5h")
    }

    // MARK: - DeepSeek balance: old path (no metricSnapshots, init fallback)

    func testDeepSeekBalanceInstanceMapsBalanceFields() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )

        let instance = Instance(
            uuid: "ds-balance-1",
            provider: Provider.deepseek.rawValue,
            dimension: "balance",
            displayName: "DeepSeek Balance",
            shortName: "DS",
            apiKeyRef: "deepseek-key",
            enabled: true,
            sortOrder: 0,
            currency: "CNY",
            thresholds: .balance(
                warning: Decimal(string: "10.00")!,
                critical: Decimal(string: "2.00")!,
                avgDailyPeriods: [],
                historyRetentionDays: 0
            )
        )

        var rawData: [String: String] = [:]
        rawData["balance"] = "50.00"
        rawData["total_balance"] = "100.00"
        rawData["granted_balance"] = "10.00"

        let response = SupplierResponse(
            rawData: rawData, currency: "CNY", isAvailable: true
        )

        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response
        )

        XCTAssertEqual(result.uuid, "ds-balance-1")
        XCTAssertEqual(result.provider, Provider.deepseek.rawValue)
        XCTAssertEqual(result.dimension, "balance")

        // Balance path uses old-style init fallback → 1 synthetic snapshot
        XCTAssertEqual(result.metricSnapshots.count, 1)
        let s = result.metricSnapshots[0]
        XCTAssertEqual(s.key, "balance")
        XCTAssertEqual(s.displayUsage, "50.00")
        XCTAssertEqual(s.displayLimit, "")

        // Computed instanceType preserves .balance via balanceInstanceType
        guard case .balance(let amount, let totalBalance, let grantedBalance, let isAvailable, let currency) = result.instanceType else {
            XCTFail("Expected balance instance type, got \(result.instanceType)")
            return
        }
        XCTAssertEqual(amount, "50.00")
        XCTAssertEqual(totalBalance, "100.00")
        XCTAssertEqual(grantedBalance, "10.00")
        XCTAssertTrue(isAvailable)
        XCTAssertEqual(currency, "CNY")

        // Color state: 50.00 > 10.00 warning → normal
        XCTAssertEqual(result.colorState, .normal)

        // Balance instances have no weekly snapshot → weekly is nil
        XCTAssertNil(result.weekly)
    }

    // MARK: - Empty metricSnapshots (init fallback creates synthetic snapshot)

    func testEmptyMetricSnapshotsFallbackToSyntheticSnapshot() {
        // When metricSnapshots is empty, the init creates a single
        // synthetic MetricSnapshot from instanceType/colorState params.
        let slot = SlotViewData(
            uuid: "empty-1",
            displayName: "Empty",
            shortName: "EM",
            sortOrder: 0,
            provider: "test"
        )

        // Not empty — the fallback created a synthetic snapshot
        XCTAssertEqual(slot.metricSnapshots.count, 1)
        let s = slot.metricSnapshots[0]
        XCTAssertEqual(s.key, "")
        XCTAssertEqual(s.configIndex, 0)

        // Default computed values from the synthetic snapshot
        XCTAssertEqual(slot.dimension, "")
        XCTAssertEqual(slot.colorState, .loading)

        guard case .quota(let p, let u, let l, let crs) = slot.instanceType else {
            XCTFail("Expected quota instance type, got \(slot.instanceType)")
            return
        }
        XCTAssertEqual(p, 0.0)
        XCTAssertEqual(u, "")
        XCTAssertEqual(l, "")
        XCTAssertNil(crs)
        XCTAssertNil(slot.weekly)
    }

    // MARK: - Unknown metric key defaults to zero percent

    func testUnknownMetricKeyDefaultsToZero() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )

        let metrics: [MetricConfig] = [
            MetricConfig(key: "nonexistent_key", group: nil, window: nil),
        ]

        let instance = Instance(
            uuid: "unknown-1",
            provider: Provider.minimax.rawValue,
            dimension: "nonexistent_key",
            metrics: metrics,
            displayName: "Unknown",
            shortName: "UK",
            apiKeyRef: "some-key",
            enabled: true,
            sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )

        let rawData: [String: String] = ["some_other_key": "42.0"]
        let response = SupplierResponse(rawData: rawData)

        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response
        )

        XCTAssertEqual(result.metricSnapshots.count, 1)
        let s = result.metricSnapshots[0]
        XCTAssertEqual(s.key, "nonexistent_key")
        XCTAssertEqual(s.percent, 0.0, "Missing key should default to 0%")
        XCTAssertEqual(s.displayUsage, "0")
        XCTAssertEqual(s.displayLimit, "")
        XCTAssertNil(s.cycleRemainingSeconds)
        // 0% is below warning(80) → normal
        XCTAssertEqual(s.colorState, .normal)
        XCTAssertEqual(s.configIndex, 1)
    }

    // MARK: - Copilot unlimited → MetricSnapshot.isUnlimited

    /// When the Copilot API reports `unlimited: true`, the MetricSnapshot
    /// must carry `isUnlimited: true` so the menu bar renderer can show ∞
    /// instead of 0%.
    func testCopilotUnlimitedPropagatesToSnapshot() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )

        let metrics: [MetricConfig] = [
            MetricConfig(key: "premium_interactions", group: nil, window: nil),
        ]

        let instance = Instance(
            uuid: "copilot-ul-1",
            provider: Provider.githubCopilot.rawValue,
            dimension: "premium_interactions",
            metrics: metrics,
            displayName: "Copilot Unlimited",
            shortName: "CU",
            apiKeyRef: "copilot-key",
            enabled: true,
            sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )

        var rawData: [String: String] = [:]
        rawData["premium_interactions"] = "0.0"
        rawData["premium_interactions:unlimited"] = "true"
        rawData["premium_interactions:entitlement"] = "1000"
        rawData["premium_interactions:remaining"] = "1000"

        let response = SupplierResponse(rawData: rawData, currency: nil, isAvailable: true)

        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response
        )

        XCTAssertEqual(result.metricSnapshots.count, 1)
        let s = result.metricSnapshots[0]
        XCTAssertTrue(s.isUnlimited, "Copilot unlimited plan must set isUnlimited on snapshot")
        XCTAssertEqual(s.displayUsage, "∞", "Unlimited Copilot should show ∞ usage")
        XCTAssertEqual(s.displayLimit, "1000")
        XCTAssertEqual(s.percent, 0.0)
    }

    /// Copilot limited plans must NOT set isUnlimited.
    func testCopilotLimitedDoesNotSetUnlimited() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )

        let metrics: [MetricConfig] = [
            MetricConfig(key: "premium_interactions", group: nil, window: nil),
        ]

        let instance = Instance(
            uuid: "copilot-limited-1",
            provider: Provider.githubCopilot.rawValue,
            dimension: "premium_interactions",
            metrics: metrics,
            displayName: "Copilot Limited",
            shortName: "CL",
            apiKeyRef: "copilot-key",
            enabled: true,
            sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )

        var rawData: [String: String] = [:]
        rawData["premium_interactions"] = "30.0"
        rawData["premium_interactions:unlimited"] = "false"
        rawData["premium_interactions:entitlement"] = "300"
        rawData["premium_interactions:remaining"] = "210"

        let response = SupplierResponse(rawData: rawData, currency: nil, isAvailable: true)

        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response
        )

        XCTAssertEqual(result.metricSnapshots.count, 1)
        let s = result.metricSnapshots[0]
        XCTAssertFalse(s.isUnlimited, "Copilot limited plan must not set isUnlimited")
        // 300 - 210 = 90 used, percent = 30%
        XCTAssertEqual(s.percent, 30.0, accuracy: 0.01)
        XCTAssertEqual(s.displayUsage, "90")
    }

    // MARK: - MiniMax weekly unlimited → MetricSnapshot.isUnlimited

    /// When MiniMax weekly_status != 1, the weekly MetricSnapshot must carry
    /// isUnlimited: true so the menu bar renders ∞ instead of 0%.
    func testMiniMaxWeeklyUnlimitedPropagatesToSnapshot() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )

        let metrics: [MetricConfig] = [
            MetricConfig(key: "general", group: "general", window: nil),
            MetricConfig(key: "general:weekly_percent", group: "general", window: "weekly"),
        ]

        let instance = Instance(
            uuid: "mini-weekly-ul-1",
            provider: Provider.minimax.rawValue,
            dimension: "general",
            metrics: metrics,
            displayName: "MiniMax Weekly UL",
            shortName: "MW",
            apiKeyRef: "minimax-key",
            enabled: true,
            sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )

        let endTimeMs: Int64 = Int64(
            Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        )
        var rawData: [String: String] = [:]
        rawData["general"] = "30.0"
        rawData["general:status"] = "1"
        rawData["general:remaining"] = "70.0"
        rawData["general:weekly_status"] = "3"       // status != 1 → unlimited
        rawData["general:weekly_remaining"] = "100.0"
        rawData["general:weekly_percent"] = "0.0"
        rawData["general:end_time"] = String(endTimeMs)

        let response = SupplierResponse(rawData: rawData, currency: nil, isAvailable: true)

        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response
        )

        XCTAssertEqual(result.metricSnapshots.count, 2)
        // First snapshot (5h quota) — not unlimited
        XCTAssertFalse(result.metricSnapshots[0].isUnlimited)

        // Second snapshot (weekly) — unlimited
        let weeklySnapshot = result.metricSnapshots[1]
        XCTAssertTrue(weeklySnapshot.isUnlimited,
                       "MiniMax weekly_status=3 must set isUnlimited on weekly snapshot")
        XCTAssertEqual(weeklySnapshot.window, "weekly")
    }

    /// When MiniMax weekly_status == 1, weekly is limited.
    func testMiniMaxWeeklyLimitedNotUnlimited() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )

        let metrics: [MetricConfig] = [
            MetricConfig(key: "general:weekly_percent", group: "general", window: "weekly"),
        ]

        let instance = Instance(
            uuid: "mini-weekly-lim-1",
            provider: Provider.minimax.rawValue,
            dimension: "general",
            metrics: metrics,
            displayName: "MiniMax Weekly Limited",
            shortName: "ML",
            apiKeyRef: "minimax-key",
            enabled: true,
            sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )

        var rawData: [String: String] = [:]
        rawData["general:weekly_percent"] = "50.0"
        rawData["general:weekly_status"] = "1"       // status == 1 → limited
        rawData["general:weekly_remaining"] = "50.0"

        let response = SupplierResponse(rawData: rawData, currency: nil, isAvailable: true)

        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response
        )

        XCTAssertEqual(result.metricSnapshots.count, 1)
        let s = result.metricSnapshots[0]
        XCTAssertFalse(s.isUnlimited, "MiniMax weekly_status=1 must not be unlimited")
        XCTAssertEqual(s.percent, 50.0, accuracy: 0.01)
    }
}
