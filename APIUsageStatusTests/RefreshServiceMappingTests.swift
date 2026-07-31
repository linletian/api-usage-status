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
        // `cycleEndTime` is the absolute `Date` version of the same
        // end_time ms the supplier reported. The view's live
        // countdown uses this with `TimelineView`; without it the
        // per-card "Xh Ym remaining" ticks once at refresh and freezes.
        XCTAssertNotNil(s0.cycleEndTime, "5h snapshot must carry cycleEndTime for live countdown")
        XCTAssertEqual(
            s0.cycleEndTime!.timeIntervalSince1970,
            TimeInterval(endTimeMs) / 1000.0,
            accuracy: 0.001,
            "cycleEndTime must match the supplier's end_time ms"
        )
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
        // Weekly window has no `general:weekly_percent:end_time` in
        // the rawData (only the 5h does) — `cycleEndTime` must be nil
        // and `cycleRemainingSeconds` must mirror that.
        XCTAssertNil(s1.cycleEndTime, "Weekly snapshot has no end_time → cycleEndTime is nil")
        XCTAssertNil(s1.cycleRemainingSeconds, "cycleRemainingSeconds must mirror cycleEndTime nil-ness")
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
        // All three OpenCode windows report `end_time` — every
        // snapshot must carry `cycleEndTime` so the live countdown
        // works on all of them.
        XCTAssertNotNil(s0.cycleEndTime, "5h snapshot must carry cycleEndTime")
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
        XCTAssertNotNil(s1.cycleEndTime, "Weekly snapshot must carry cycleEndTime")
        XCTAssertEqual(s1.configIndex, 2)

        // --- Snapshot 2: monthly ---
        let s2 = result.metricSnapshots[2]
        XCTAssertEqual(s2.key, "monthly")
        XCTAssertEqual(s2.window, "monthly")
        XCTAssertEqual(s2.percent, 58.3, accuracy: 0.01)
        XCTAssertEqual(s2.displayUsage, "$35.00")
        XCTAssertEqual(s2.displayLimit, "$60.00")
        XCTAssertNotNil(s2.cycleRemainingSeconds)
        XCTAssertNotNil(s2.cycleEndTime, "Monthly snapshot must carry cycleEndTime")
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

    /// Real-world 2026-07-30+ Copilot API shape: `remaining` is negative
    /// (over budget) and the authoritative total-used count comes from
    /// `credits_used`. RefreshService must NOT also add `overage_count`
    /// on top — `entitlement - remaining` already embeds it once
    /// `remaining` goes negative, so adding `overage_count` again would
    /// double-count by ~1000 in the live case (overage_count = 1000 vs
    /// the correct credits_used = 8054). See
    /// `docs/copilot-overage-stuck-at-100-percent.md`.
    func testCopilotOverageUsesCreditsUsedNotOverageCount() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )

        let metrics: [MetricConfig] = [
            MetricConfig(key: "premium_interactions", group: nil, window: nil),
        ]

        let instance = Instance(
            uuid: "copilot-overage-1",
            provider: Provider.githubCopilot.rawValue,
            dimension: "premium_interactions",
            metrics: metrics,
            displayName: "Copilot Overage",
            shortName: "CO",
            apiKeyRef: "copilot-key",
            enabled: true,
            sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )

        var rawData: [String: String] = [:]
        // 8054 / 7000 * 100 = 115.0571 → 115.1% (parser fills this in)
        rawData["premium_interactions"] = "115.1"
        rawData["premium_interactions:unlimited"] = "false"
        rawData["premium_interactions:entitlement"] = "7000"
        rawData["premium_interactions:remaining"] = "-1055"
        rawData["premium_interactions:overage_count"] = "1000"
        rawData["premium_interactions:overage_permitted"] = "false"
        rawData["premium_interactions:credits_used"] = "8054"

        let response = SupplierResponse(rawData: rawData, currency: nil, isAvailable: true)

        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response
        )

        let s = result.metricSnapshots[0]
        XCTAssertEqual(s.percent, 115.1, accuracy: 0.01)
        // Must be exactly credits_used (8054), not entitlement-remaining+overage_count
        // (which would be 7000 - (-1055) + 1000 = 9055, double-counting).
        XCTAssertEqual(s.displayUsage, "8054")
        XCTAssertEqual(s.displayLimit, "7000")
    }

    /// Copilot's parser writes the standard `<key>:end_time` ms key
    /// (derived from `quota_reset_date_utc`). `RefreshService` must
    /// pick it up and populate `cycleEndTime` so the per-card live
    /// "Xh Ym remaining" countdown works for Copilot — this is the
    /// integration test for that whole chain.
    func testCopilotEndTimeFlowsThroughToSnapshot() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )

        let metrics: [MetricConfig] = [
            MetricConfig(key: "premium_interactions", group: nil, window: nil),
        ]

        let instance = Instance(
            uuid: "copilot-endtime-1",
            provider: Provider.githubCopilot.rawValue,
            dimension: "premium_interactions",
            metrics: metrics,
            displayName: "Copilot",
            shortName: "CP",
            apiKeyRef: "copilot-key",
            enabled: true,
            sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )

        // 1 hour from now, in ms — matches what the Copilot parser
        // would have written for an ISO 8601 reset date 1h ahead.
        let endTimeMs: Int64 = Int64(
            Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        )

        var rawData: [String: String] = [:]
        rawData["premium_interactions"] = "30.0"
        rawData["premium_interactions:unlimited"] = "false"
        rawData["premium_interactions:entitlement"] = "300"
        rawData["premium_interactions:remaining"] = "210"
        rawData["premium_interactions:end_time"] = String(endTimeMs)

        let response = SupplierResponse(rawData: rawData, currency: nil, isAvailable: true)

        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response
        )

        let s = result.metricSnapshots[0]
        XCTAssertNotNil(
            s.cycleEndTime,
            "Copilot snapshots must carry cycleEndTime once the parser writes <key>:end_time"
        )
        XCTAssertEqual(
            s.cycleEndTime!.timeIntervalSince1970,
            TimeInterval(endTimeMs) / 1000.0,
            accuracy: 0.001
        )
        XCTAssertNotNil(s.cycleRemainingSeconds, "cycleRemainingSeconds mirrors cycleEndTime")
        // Roughly 1h remaining (allow ±5s for test execution drift).
        XCTAssertEqual(s.cycleRemainingSeconds!, 3600, accuracy: 5)
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

    // MARK: - Copilot weekly-window fallthrough to Copilot branch

    /// A Copilot MetricConfig with `window: "weekly"` and `group: nil` must
    /// fall through the MiniMax-weekly branch (which requires group != nil)
    /// and hit the Copilot `else if`, reading the `:unlimited` dimension.
    /// This locks in the if/else-if fallthrough contract for weekly Copilot
    /// configs that don't carry a group key.
    func testCopilotWeeklyWithoutGroupFallsThroughToCopilotBranch() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )

        let metrics: [MetricConfig] = [
            MetricConfig(key: "premium_weekly", group: nil, window: "weekly"),
        ]

        let instance = Instance(
            uuid: "copilot-weekly-no-group",
            provider: Provider.githubCopilot.rawValue,
            dimension: "premium_weekly",
            metrics: metrics,
            displayName: "Copilot Weekly (no group)",
            shortName: "CW",
            apiKeyRef: "copilot-key",
            enabled: true,
            sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )

        var rawData: [String: String] = [:]
        rawData["premium_weekly"] = "0.0"
        rawData["premium_weekly:unlimited"] = "true"

        let response = SupplierResponse(rawData: rawData, currency: nil, isAvailable: true)

        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response
        )

        XCTAssertEqual(result.metricSnapshots.count, 1)
    }

    // MARK: - Metric cycle-end policy (provider-neutral inheritance)

    /// A `retainPreviousIfResponseMissing` policy for a metric whose
    /// response does not provide a positive end time must inherit the
    /// matching previous snapshot's unexpired end time, recompute the
    /// remaining seconds against `now`, and keep the new percent / color
    /// from the response.
    func testRetainPreviousIfResponseMissingInheritsUnexpiredEndTime() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )
        let metrics: [MetricConfig] = [
            MetricConfig(key: "kimi", group: "kimi", window: "5h"),
        ]
        let instance = Instance(
            uuid: "kimi-1",
            provider: Provider.kimi.rawValue,
            dimension: "kimi",
            metrics: metrics,
            displayName: "Kimi",
            shortName: "KMI",
            apiKeyRef: "key-kimi-1",
            enabled: true,
            sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )

        let oldEnd = Date().addingTimeInterval(3_600)
        let previousSnapshot = MetricSnapshot(
            key: "kimi", group: "kimi", window: "5h",
            percent: 20, displayUsage: "20.0", displayLimit: "",
            cycleRemainingSeconds: 3_600, colorState: .normal,
            configIndex: 1, displayInMenuBar: true,
            isUnlimited: false, shortName: nil,
            cycleEndTime: oldEnd
        )
        let previousSlot = SlotViewData(
            uuid: instance.uuid,
            displayName: instance.displayName,
            shortName: instance.shortName,
            sortOrder: 0,
            provider: instance.provider,
            metricSnapshots: [previousSnapshot]
        )

        let response = SupplierResponse(
            rawData: [
                "kimi": "82.0",
                "kimi:status": "1",
                "kimi:remaining": "18.0",
                "kimi:end_time": "0",
            ],
            currency: nil,
            isAvailable: true,
            metricCycleEndPolicies: ["kimi": .retainPreviousIfResponseMissing]
        )

        let now = Date()
        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response,
            previousSlot: previousSlot, now: now
        )

        let snapshot = try? XCTUnwrap(result.metricSnapshots.first)
        XCTAssertEqual(snapshot?.cycleEndTime, oldEnd,
                       "5h snapshot must inherit the previous unexpired end time")
        XCTAssertEqual(snapshot?.percent ?? 0, 82.0, accuracy: 0.01,
                       "New percent must come from the response, not the cache")
        XCTAssertEqual(snapshot?.colorState, .warning,
                       "Color state must come from the response's threshold check")
        let remaining = snapshot?.cycleRemainingSeconds ?? 0
        XCTAssertGreaterThan(remaining, 0)
        XCTAssertLessThanOrEqual(remaining, 3_600)
    }

    /// A valid response end time must always win over a cached end time,
    /// regardless of any declared policy.
    func testValidResponseEndTimeOverridesCachedValue() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )
        let metrics = [MetricConfig(key: "kimi", group: "kimi", window: "5h")]
        let instance = Instance(
            uuid: "kimi-2", provider: Provider.kimi.rawValue,
            dimension: "kimi", metrics: metrics,
            displayName: "Kimi", shortName: "KMI",
            apiKeyRef: "k", enabled: true, sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )
        let oldEnd = Date().addingTimeInterval(7_200)
        let previousSnapshot = MetricSnapshot(
            key: "kimi", group: "kimi", window: "5h",
            percent: 0, displayUsage: "0", displayLimit: "",
            cycleRemainingSeconds: 7_200, colorState: .normal,
            configIndex: 1, displayInMenuBar: true,
            isUnlimited: false, shortName: nil,
            cycleEndTime: oldEnd
        )
        let previousSlot = SlotViewData(
            uuid: instance.uuid, displayName: "Kimi", shortName: "KMI",
            sortOrder: 0, provider: instance.provider,
            metricSnapshots: [previousSnapshot]
        )
        let newEndMs = Int64(Date().addingTimeInterval(1_800).timeIntervalSince1970 * 1000)
        let response = SupplierResponse(
            rawData: ["kimi": "30.0", "kimi:status": "1", "kimi:end_time": String(newEndMs)],
            currency: nil, isAvailable: true,
            metricCycleEndPolicies: ["kimi": .retainPreviousIfResponseMissing]
        )
        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response,
            previousSlot: previousSlot, now: Date()
        )
        let snapshot = try? XCTUnwrap(result.metricSnapshots.first)
        let expectedEnd = Date(timeIntervalSince1970: TimeInterval(newEndMs) / 1000.0)
        XCTAssertEqual(snapshot?.cycleEndTime, expectedEnd)
    }

    /// When the previous cache is already in the past, the inherited
    /// branch must not surface a stale end time.
    func testExpiredPreviousCacheIsNotInherited() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )
        let metrics = [MetricConfig(key: "kimi", group: "kimi", window: "5h")]
        let instance = Instance(
            uuid: "kimi-3", provider: Provider.kimi.rawValue,
            dimension: "kimi", metrics: metrics,
            displayName: "Kimi", shortName: "KMI",
            apiKeyRef: "k", enabled: true, sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )
        let expiredEnd = Date().addingTimeInterval(-60)
        let previousSnapshot = MetricSnapshot(
            key: "kimi", group: "kimi", window: "5h",
            percent: 0, displayUsage: "0", displayLimit: "",
            cycleRemainingSeconds: 0, colorState: .normal,
            configIndex: 1, displayInMenuBar: true,
            isUnlimited: false, shortName: nil,
            cycleEndTime: expiredEnd
        )
        let previousSlot = SlotViewData(
            uuid: instance.uuid, displayName: "Kimi", shortName: "KMI",
            sortOrder: 0, provider: instance.provider,
            metricSnapshots: [previousSnapshot]
        )
        let response = SupplierResponse(
            rawData: ["kimi": "30.0", "kimi:status": "1", "kimi:end_time": "0"],
            currency: nil, isAvailable: true,
            metricCycleEndPolicies: ["kimi": .retainPreviousIfResponseMissing]
        )
        let now = Date()
        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response,
            previousSlot: previousSlot, now: now
        )
        let snapshot = try? XCTUnwrap(result.metricSnapshots.first)
        XCTAssertNil(snapshot?.cycleEndTime, "Expired cache must not be inherited")
        XCTAssertNil(snapshot?.cycleRemainingSeconds)
    }

    /// Without the policy, the mapper must behave like the prior version
    /// and never inherit the previous end time, even when the response
    /// is missing and the cache is in the future. This protects other
    /// providers that never opt in.
    func testNoPolicyDoesNotInheritPreviousEndTime() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )
        let metrics = [MetricConfig(key: "kimi", group: "kimi", window: "5h")]
        let instance = Instance(
            uuid: "kimi-4", provider: Provider.kimi.rawValue,
            dimension: "kimi", metrics: metrics,
            displayName: "Kimi", shortName: "KMI",
            apiKeyRef: "k", enabled: true, sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )
        let goodEnd = Date().addingTimeInterval(3_600)
        let previousSnapshot = MetricSnapshot(
            key: "kimi", group: "kimi", window: "5h",
            percent: 0, displayUsage: "0", displayLimit: "",
            cycleRemainingSeconds: 3_600, colorState: .normal,
            configIndex: 1, displayInMenuBar: true,
            isUnlimited: false, shortName: nil,
            cycleEndTime: goodEnd
        )
        let previousSlot = SlotViewData(
            uuid: instance.uuid, displayName: "Kimi", shortName: "KMI",
            sortOrder: 0, provider: instance.provider,
            metricSnapshots: [previousSnapshot]
        )
        let response = SupplierResponse(
            rawData: ["kimi": "30.0", "kimi:status": "1", "kimi:end_time": "0"]
        )
        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response,
            previousSlot: previousSlot, now: Date()
        )
        let snapshot = try? XCTUnwrap(result.metricSnapshots.first)
        XCTAssertNil(snapshot?.cycleEndTime)
    }

    /// Inheritance matches by `key/group/window`, so a different metric
    /// identity never reuses another metric's end time.
    func testInheritanceOnlyMatchesIdenticalMetricIdentity() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )
        let metrics: [MetricConfig] = [
            MetricConfig(key: "kimi", group: "kimi", window: "5h"),
            MetricConfig(key: "kimi:weekly_percent", group: "kimi", window: "weekly"),
        ]
        let instance = Instance(
            uuid: "kimi-5", provider: Provider.kimi.rawValue,
            dimension: "kimi", metrics: metrics,
            displayName: "Kimi", shortName: "KMI",
            apiKeyRef: "k", enabled: true, sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )
        let oldFiveHour = Date().addingTimeInterval(3_600)
        let previousSnapshots = [
            MetricSnapshot(
                key: "kimi", group: "kimi", window: "5h",
                percent: 0, displayUsage: "0", displayLimit: "",
                cycleRemainingSeconds: 3_600, colorState: .normal,
                configIndex: 1, displayInMenuBar: true,
                isUnlimited: false, shortName: nil,
                cycleEndTime: oldFiveHour
            ),
            MetricSnapshot(
                key: "kimi:weekly_percent", group: "kimi", window: "weekly",
                percent: 0, displayUsage: "0", displayLimit: "",
                cycleRemainingSeconds: 86_400, colorState: .normal,
                configIndex: 2, displayInMenuBar: true,
                isUnlimited: false, shortName: nil,
                cycleEndTime: Date().addingTimeInterval(86_400)
            ),
        ]
        let previousSlot = SlotViewData(
            uuid: instance.uuid, displayName: "Kimi", shortName: "KMI",
            sortOrder: 0, provider: instance.provider,
            metricSnapshots: previousSnapshots
        )
        let response = SupplierResponse(
            rawData: [
                "kimi": "30.0", "kimi:status": "1", "kimi:end_time": "0",
                "kimi:weekly_percent": "10.0", "kimi:weekly_status": "1",
                "kimi:weekly_remaining": "90.0", "kimi:weekly_percent:end_time": "0",
            ],
            currency: nil, isAvailable: true,
            metricCycleEndPolicies: ["kimi": .retainPreviousIfResponseMissing]
        )
        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response,
            previousSlot: previousSlot, now: Date()
        )
        let fiveHour = result.metricSnapshots.first { $0.key == "kimi" }
        let weekly = result.metricSnapshots.first { $0.key == "kimi:weekly_percent" }
        XCTAssertEqual(fiveHour?.cycleEndTime, oldFiveHour)
        XCTAssertNil(weekly?.cycleEndTime,
                     "Weekly window must not borrow the 5h cached end time")
    }

    // MARK: - End-time rawData → MetricSnapshot translation

    /// The mapper is the single place that converts the supplier's
    /// `kimi:end_time` (string) into `MetricSnapshot.cycleEndTime` (Date?).
    /// Lock in the contract for every "no usable end time" rawData shape
    /// the Kimi parser may emit: `"0"`, negative numbers, empty strings,
    /// and non-numeric tokens must all resolve to `nil` so the policy
    /// branch can take over. This is the contract the AppState layer
    /// relies on when it sees a fresh successful slot — it must never
    /// receive a `cycleEndTime` whose value is `Date(timeIntervalSince1970: 0)`
    /// for the Kimi 5h metric.
    func testZeroOrInvalidEndTimeRawDataTranslatesToNilCycleEndTime() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )
        let metrics: [MetricConfig] = [
            MetricConfig(key: "kimi", group: "kimi", window: "5h"),
            MetricConfig(key: "kimi:weekly_percent", group: "kimi", window: "weekly"),
        ]
        let instance = Instance(
            uuid: "kimi-translate", provider: Provider.kimi.rawValue,
            dimension: "kimi", metrics: metrics,
            displayName: "Kimi", shortName: "KMI",
            apiKeyRef: "k", enabled: true, sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )
        let validWeeklyEnd = Int64(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000)

        let badEndTimeCases: [(label: String, value: String)] = [
            ("parser-written zero", "0"),
            ("negative epoch ms", "-1"),
            ("empty string", ""),
            ("non-numeric token", "not-a-date"),
        ]

        for (label, endTimeValue) in badEndTimeCases {
            let response = SupplierResponse(
                rawData: [
                    "kimi": "12.0", "kimi:status": "1", "kimi:remaining": "88.0",
                    "kimi:end_time": endTimeValue,
                    "kimi:weekly_percent": "30.0", "kimi:weekly_status": "1",
                    "kimi:weekly_remaining": "70.0",
                    "kimi:weekly_percent:end_time": String(validWeeklyEnd),
                ],
                currency: nil, isAvailable: true
            )
            let result = await service.mapInstanceToSlotData(
                instance: instance, response: response
            )
            let fiveHour = result.metricSnapshots.first { $0.key == "kimi" }
            let weekly = result.metricSnapshots.first { $0.key == "kimi:weekly_percent" }
            XCTAssertNil(fiveHour?.cycleEndTime, "5h cycleEndTime must be nil for \(label)")
            XCTAssertNil(fiveHour?.cycleRemainingSeconds, "5h cycleRemainingSeconds must mirror nil for \(label)")
            XCTAssertNotNil(weekly?.cycleEndTime, "Weekly cycleEndTime must be unaffected by 5h rawData shape for \(label)")
        }
    }

    /// When the response itself can supply a positive end time the
    /// mapper must decode the ms string into the expected `Date`, even
    /// for non-Kimi providers. This pins the inverse direction of the
    /// `end_time → cycleEndTime` translation that the previous test
    /// covers for the nil side.
    func testValidEndTimeRawDataTranslatesToMatchingDate() async {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )
        let metrics: [MetricConfig] = [
            MetricConfig(key: "kimi", group: "kimi", window: "5h"),
        ]
        let instance = Instance(
            uuid: "kimi-valid", provider: Provider.kimi.rawValue,
            dimension: "kimi", metrics: metrics,
            displayName: "Kimi", shortName: "KMI",
            apiKeyRef: "k", enabled: true, sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )
        let endTimeMs = Int64(Date().addingTimeInterval(7_200).timeIntervalSince1970 * 1000)
        let response = SupplierResponse(
            rawData: ["kimi": "10.0", "kimi:status": "1", "kimi:end_time": String(endTimeMs)],
            currency: nil, isAvailable: true
        )
        let result = await service.mapInstanceToSlotData(
            instance: instance, response: response
        )
        let snapshot = result.metricSnapshots.first
        XCTAssertEqual(snapshot?.cycleEndTime,
                       Date(timeIntervalSince1970: TimeInterval(endTimeMs) / 1000.0),
                       "Valid end_time ms string must decode to the matching absolute Date")
    }

    /// End-to-end: Kimi parser emits `kimi:end_time = "0"` and the
    /// `retainPreviousIfResponseMissing` policy, the mapper must read
    /// `"0"` as `nil`, take the inheritance path, and surface the
    /// unexpired previous end time. This is the single contract the
    /// AppState merge layer depends on, exercised from the rawData
    /// emitted by the actual Kimi parser fixture (no hand-rolled policy
    /// injection in the test).
    func testKimiParserEndToEndInvalidResetTimeInheritsPreviousEndTime() async throws {
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: AppState()
        )
        let metrics: [MetricConfig] = [
            MetricConfig(key: "kimi", group: "kimi", window: "5h"),
        ]
        let instance = Instance(
            uuid: "kimi-e2e", provider: Provider.kimi.rawValue,
            dimension: "kimi", metrics: metrics,
            displayName: "Kimi", shortName: "KMI",
            apiKeyRef: "k", enabled: true, sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )
        let unexpiredEnd = Date().addingTimeInterval(3_600)
        let previousSnapshot = MetricSnapshot(
            key: "kimi", group: "kimi", window: "5h",
            percent: 12, displayUsage: "12.0", displayLimit: "",
            cycleRemainingSeconds: 3_600, colorState: .normal,
            configIndex: 1, displayInMenuBar: true,
            isUnlimited: false, shortName: nil,
            cycleEndTime: unexpiredEnd
        )
        let previousSlot = SlotViewData(
            uuid: instance.uuid, displayName: "Kimi", shortName: "KMI",
            sortOrder: 0, provider: instance.provider,
            metricSnapshots: [previousSnapshot]
        )

        let rawJSON = """
        {
          "limits": [
            { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
              "detail": { "limit": "100", "used": "12", "resetTime": "not-a-date" } }
          ]
        }
        """
        let parser = KimiResponseParser()
        let parsed = try parser.parse(rawJSON.data(using: .utf8)!)
        XCTAssertEqual(parsed.rawData["kimi:end_time"], "0",
                       "Precondition: parser must publish the zero ms sentinel")
        XCTAssertEqual(parsed.metricCycleEndPolicies["kimi"], .retainPreviousIfResponseMissing,
                       "Precondition: parser must declare the retain policy")

        let result = await service.mapInstanceToSlotData(
            instance: instance,
            response: parsed,
            previousSlot: previousSlot,
            now: Date()
        )
        let snapshot = result.metricSnapshots.first
        XCTAssertEqual(snapshot?.cycleEndTime, unexpiredEnd,
                       "End-to-end: parser's zero end_time + policy must inherit the previous unexpired end time")
        XCTAssertEqual(snapshot?.percent ?? 0, 12.0, accuracy: 0.01,
                       "End-to-end: new percent still comes from the parser's response")
    }
}
