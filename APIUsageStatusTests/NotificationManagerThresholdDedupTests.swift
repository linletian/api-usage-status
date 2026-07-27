import XCTest
import UserNotifications
@testable import APIUsageStatus

/// Tests for the dedup added to `NotificationManager.evaluateThresholds`.
///
/// Dedup semantic (revised from v1's pure rising-edge):
///   - Fire on the **rising edge** (not-critical → critical).
///   - Fire on **value change while sustained critical** (the displayed
///     value differs from the last fired value).
///   - Do NOT refire when sustained at the same displayed value
///     (prevents v1's per-refresh spam on a stuck-high quota).
///   - Recovery (was-critical → not-critical) clears the latch so a
///     later re-crossing fires again.
///
/// The v1 bug was a notification per refresh; the v1.1 fix above was
/// pure rising-edge; the **current** semantic is rising-edge + value
/// change so users also hear about the situation *getting worse*.
@MainActor
final class NotificationManagerThresholdDedupTests: XCTestCase {

    // MARK: - Stub scheduler

    private final class StubNotificationScheduler: NotificationScheduling {
        private(set) var addedRequests: [UNNotificationRequest] = []

        func add(
            _ request: UNNotificationRequest,
            withCompletionHandler completionHandler: ((Error?) -> Void)?
        ) {
            addedRequests.append(request)
            completionHandler?(nil)
        }
    }

    // MARK: - Fixtures

    private var stub: StubNotificationScheduler!
    private var manager: NotificationManager!

    override func setUp() async throws {
        try await super.setUp()
        stub = StubNotificationScheduler()
        manager = NotificationManager(openDetailPanel: { _ in }, scheduler: stub)
        manager._setPermissionGrantedForTesting(true)
    }

    private func settings() -> GlobalSettings {
        var s = GlobalSettings.default
        s.notificationsEnabled = true
        return s
    }

    private func makeSnapshot(key: String, window: String? = nil, percent: Double) -> MetricSnapshot {
        MetricSnapshot(
            key: key,
            group: nil,
            window: window,
            percent: percent,
            displayUsage: "\(Int(percent))%",
            displayLimit: "",
            cycleRemainingSeconds: nil,
            colorState: .normal
        )
    }

    private func makeQuotaSlot(
        uuid: String,
        displayName: String = "Test",
        shortName: String = "T",
        snapshots: [MetricSnapshot]
    ) -> SlotViewData {
        SlotViewData(
            uuid: uuid,
            displayName: displayName,
            shortName: shortName,
            sortOrder: 0,
            colorState: .normal,
            provider: "test",
            dimension: snapshots.first?.key ?? "",
            metricSnapshots: snapshots
        )
    }

    private func makeBalanceSlot(
        uuid: String,
        displayName: String = "Test",
        shortName: String = "T",
        amount: String
    ) -> SlotViewData {
        SlotViewData(
            uuid: uuid,
            displayName: displayName,
            shortName: shortName,
            instanceType: .balance(
                amount: amount,
                totalBalance: amount,
                grantedBalance: "0",
                isAvailable: true,
                currency: "CNY"
            ),
            sortOrder: 0,
            colorState: .normal,
            provider: "test",
            dimension: "balance"
        )
    }

    private func makeQuotaInstance(
        uuid: String,
        displayName: String = "Test",
        shortName: String = "T",
        criticalPercent: Int = 95
    ) -> Instance {
        Instance(
            uuid: uuid,
            provider: "test",
            dimension: "test",
            displayName: displayName,
            shortName: shortName,
            apiKeyRef: "key",
            enabled: true,
            sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: criticalPercent)
        )
    }

    private func makeBalanceInstance(
        uuid: String,
        displayName: String = "Test",
        shortName: String = "T",
        critical: Decimal = 10
    ) -> Instance {
        Instance(
            uuid: uuid,
            provider: "test",
            dimension: "balance",
            displayName: displayName,
            shortName: shortName,
            apiKeyRef: "key",
            enabled: true,
            sortOrder: 0,
            currency: "CNY",
            thresholds: .balance(warning: 50, critical: critical, avgDailyPeriods: [], historyRetentionDays: 30)
        )
    }

    // MARK: - Rising edge

    /// Below critical then above: exactly one notification. Mirrors the
    /// regression — without the dedup, this would still pass, but the
    /// `sustainedCriticalDoesNotRefire` test below is the one that locks
    /// the bug fix.
    func testRisingEdgeFiresOnce() {
        let instance = makeQuotaInstance(uuid: "u1")

        // First refresh: 90% — below critical (95%). Latch = false.
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", snapshots: [makeSnapshot(key: "k", percent: 90)])],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 0, "Below critical must not fire")

        // Second refresh: 96% — rising edge. Latch → true, fires.
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", snapshots: [makeSnapshot(key: "k", percent: 96)])],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1, "Crossing into critical must fire exactly once")
    }

    // MARK: - The regression: sustained critical

    // MARK: - Sustained critical at SAME value

    /// The original spam bug: an instance stuck at the same critical
    /// value across many refreshes should produce exactly one
    /// notification (the rising-edge fire), not one per refresh. This
    /// is what locks the original regression — under the OLD pure
    /// rising-edge dedup this still passed; under the NEW
    /// rising-edge + value-change dedup it MUST still pass (the value
    /// stays the same throughout, so no change-fires fire either).
    func testCriticalSameValueDoesNotRefire() {
        let instance = makeQuotaInstance(uuid: "u1")

        // Refresh 1: just over critical — fires (rising edge).
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", snapshots: [makeSnapshot(key: "k", percent: 96.0)])],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1)

        // Refreshes 2..5: still critical at SAME value (96.0) — must NOT refire.
        for _ in 0..<4 {
            manager.evaluateThresholds(
                instances: [instance],
                slotData: [makeQuotaSlot(uuid: "u1", snapshots: [makeSnapshot(key: "k", percent: 96.0)])],
                settings: settings()
            )
        }
        XCTAssertEqual(stub.addedRequests.count, 1, "Sustained critical at same value across 5 refreshes must produce 1 notification, got \(stub.addedRequests.count)")
    }

    // MARK: - Sustained critical at DIFFERENT value

    /// The behavior the user asked for: while still critical, each new
    /// displayed value should fire a fresh notification so they're
    /// kept informed the situation is changing (typically worsening).
    /// Under the OLD pure rising-edge dedup this would still produce
    /// only 1 fire, which is the case the user found unhelpful.
    func testCriticalValueChangeFiresForEachChange() {
        let instance = makeQuotaInstance(uuid: "u1")

        // 4 distinct critical values across 4 refreshes. Each renders
        // to a different `%.1f` string, so each should fire.
        let values: [Double] = [96.0, 97.5, 99.2, 100.0]
        for v in values {
            manager.evaluateThresholds(
                instances: [instance],
                slotData: [makeQuotaSlot(uuid: "u1", snapshots: [makeSnapshot(key: "k", percent: v)])],
                settings: settings()
            )
        }
        XCTAssertEqual(stub.addedRequests.count, values.count, "Each distinct critical value must fire; got \(stub.addedRequests.count) for \(values.count) changes")

        // Sanity: bodies reflect the changing values.
        let bodies = stub.addedRequests.map { $0.content.body }
        XCTAssertTrue(bodies.contains { $0.contains("96.0%") })
        XCTAssertTrue(bodies.contains { $0.contains("97.5%") })
        XCTAssertTrue(bodies.contains { $0.contains("99.2%") })
        XCTAssertTrue(bodies.contains { $0.contains("100.0%") })
    }

    /// Micro-changes that round to the same `%.1f` string should NOT
    /// refire (no user-visible change). 96.04 and 96.049 both round
    /// to "96.0", so the user wouldn't see a difference — no point
    /// notifying.
    func testCriticalValueRoundingDoesNotRefire() {
        let instance = makeQuotaInstance(uuid: "u1")

        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", snapshots: [makeSnapshot(key: "k", percent: 96.04)])],
            settings: settings()
        )
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", snapshots: [makeSnapshot(key: "k", percent: 96.049)])],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1, "Micro-deltas that round to the same displayed value must not refire")
    }

    // MARK: - Recovery + re-entry

    /// Critical (same value held) → not-critical → critical again. The
    /// recovery must clear BOTH the state latch and the value cache so
    /// the next rising edge fires — even if the re-entry value is the
    /// same as the first time we fired.
    func testRecoveryClearsAndReentryFires() {
        let instance = makeQuotaInstance(uuid: "u1")

        // 1. Enter critical at 97.
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", snapshots: [makeSnapshot(key: "k", percent: 97)])],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1)

        // 2. Stay critical at SAME value — no fire.
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", snapshots: [makeSnapshot(key: "k", percent: 97)])],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1, "Still critical at same value must not refire")

        // 3. Recover — clears latch + value cache, no fire.
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", snapshots: [makeSnapshot(key: "k", percent: 80)])],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1, "Recovery must not fire (clears state)")

        // 4. Re-enter at 97 (SAME value as step 1) — must fire (latch
        // was cleared by recovery, so the rising edge fires).
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", snapshots: [makeSnapshot(key: "k", percent: 97)])],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 2, "Re-crossing into critical after recovery must fire again, even at same value")
    }

    // MARK: - Multi-metric independent dedup

    /// 5h and weekly metrics on the same instance dedup **independently**
    /// — a value change in one metric must not refire the other. Without
    /// per-metric keys, two metrics sharing the same instance would
    /// collide and only one would fire.
    func testMultiMetricDedupIsIndependent() {
        let instance = makeQuotaInstance(uuid: "u1")

        // 5h critical at 96.0, weekly safe. Fires once for 5h.
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", snapshots: [
                makeSnapshot(key: "5h", window: "5h", percent: 96.0),
                makeSnapshot(key: "weekly", window: "weekly", percent: 40.0)
            ])],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1, "5h critical + weekly safe = 1 fire")

        // Next refresh: 5h stays at 96.0 (no change), weekly stays at
        // 40.0 (still safe). Zero additional fires.
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", snapshots: [
                makeSnapshot(key: "5h", window: "5h", percent: 96.0),
                makeSnapshot(key: "weekly", window: "weekly", percent: 40.0)
            ])],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1, "Same critical values across refreshes must not refire")

        // Next refresh: 5h changes to 97.5 (value change → fires), weekly
        // stays at 40.0 (still safe, no change → no fire). Total: 2.
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", snapshots: [
                makeSnapshot(key: "5h", window: "5h", percent: 97.5),
                makeSnapshot(key: "weekly", window: "weekly", percent: 40.0)
            ])],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 2, "5h value change must fire; weekly no-change must not")

        // Next refresh: 5h stays at 97.5 (no change), weekly rises into
        // critical at 96.0 (new critical, rising edge → fires). Total: 3.
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", snapshots: [
                makeSnapshot(key: "5h", window: "5h", percent: 97.5),
                makeSnapshot(key: "weekly", window: "weekly", percent: 96.0)
            ])],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 3, "Weekly rising into critical (independent) must fire; 5h no-change must not")
    }

    // MARK: - Balance instance dedup

    /// Balance type dedups by instance UUID. Same amount across refreshes
    /// does not refire; amount changes do.
    func testBalanceInstanceDedupByUUID() {
        let instance = makeBalanceInstance(uuid: "u1", critical: 10)

        // Drop to 8 — fires (rising edge).
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeBalanceSlot(uuid: "u1", amount: "8")],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1)

        // Same amount across two more refreshes — no refire.
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeBalanceSlot(uuid: "u1", amount: "8")],
            settings: settings()
        )
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeBalanceSlot(uuid: "u1", amount: "8")],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1, "Sustained balance-critical at same amount must not refire")

        // Amount changes to 7 — fires (value change).
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeBalanceSlot(uuid: "u1", amount: "7")],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 2, "Amount change while sustained-critical must fire")

        // Top up to 20 — clears latch, no fire.
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeBalanceSlot(uuid: "u1", amount: "20")],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 2, "Recovery must not fire")

        // Drop to 9 — fires (rising edge, post-recovery).
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeBalanceSlot(uuid: "u1", amount: "9")],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 3, "Re-crossing balance-critical after recovery must fire again")
    }

    /// Balance instance that becomes unavailable (`isAvailable == false`)
    /// must preserve the latch — when it comes back, the same critical
    /// value should NOT refire (no user-visible change). A different
    /// critical value when it returns SHOULD fire.
    func testBalanceUnavailablePreservesLatch() {
        let instance = makeBalanceInstance(uuid: "u1", critical: 10)

        // Critical at 5 — fires, latches with value="5".
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeBalanceSlot(uuid: "u1", amount: "5")],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1)

        // Now unavailable — the evaluate path skips on
        // `isAvailable == false`, so latch + value cache are preserved.
        let unavailableSlot = SlotViewData(
            uuid: "u1",
            displayName: "Test",
            shortName: "T",
            instanceType: .balance(
                amount: "5",
                totalBalance: "5",
                grantedBalance: "0",
                isAvailable: false,
                currency: "CNY"
            ),
            sortOrder: 0,
            colorState: .unavailable,
            provider: "test",
            dimension: "balance"
        )
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [unavailableSlot],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1, "Unavailable must not refire")

        // Comes back available at SAME value 5 — no refire (same value).
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeBalanceSlot(uuid: "u1", amount: "5")],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1, "Same value across unavailable span must not refire")

        // Then a different value 4 — fires (value change).
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeBalanceSlot(uuid: "u1", amount: "4")],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 2, "Different value after unavailable span must fire")
    }

    /// A balance reading that fails to parse (e.g. supplier returns "—",
    /// "N/A", or an HTML error page) is an **indeterminate** reading —
    /// same shape as `isAvailable == false`. The latch must be
    /// preserved; otherwise a later good reading at the SAME critical
    /// value would refire as a "rising edge" purely due to the parse
    /// glitch. Locks the v1.1 review fix that aligned this path with
    /// the unavailable path.
    func testBalanceBadStringReadingPreservesLatch() {
        let instance = makeBalanceInstance(uuid: "u1", critical: 10)

        // Critical at 5 — fires, latches value "5".
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeBalanceSlot(uuid: "u1", amount: "5")],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1)

        // Non-numeric string — preserve latch, no fire.
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeBalanceSlot(uuid: "u1", amount: "abc")],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1, "Non-numeric amount must preserve latch (matches unavailable)")

        // Empty string — also indeterminate, preserve latch.
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeBalanceSlot(uuid: "u1", amount: "")],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1, "Empty amount string must preserve latch")

        // Back to good reading at SAME value 5 — must NOT fire (latch
        // preserved, same value → no change fire). This is the
        // regression case: under the buggy version, this would have
        // fired as a spurious "rising edge" because the parse glitch
        // would have cleared the latch.
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeBalanceSlot(uuid: "u1", amount: "5")],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1, "Same critical value after bad-string gap must not refire")

        // Different value 4 — fires (value change).
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeBalanceSlot(uuid: "u1", amount: "4")],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 2, "Value change after bad-string gap must fire")
    }

    // MARK: - Settings gate still works

    /// The threshold path remains gated on `notificationsEnabled` even
    /// with dedup wired in.
    func testNotificationsDisabledSuppressesDedupPath() {
        let instance = makeQuotaInstance(uuid: "u1")
        var s = settings()
        s.notificationsEnabled = false

        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", snapshots: [makeSnapshot(key: "k", percent: 99)])],
            settings: s
        )
        XCTAssertEqual(stub.addedRequests.count, 0, "Disabled notifications must suppress")
    }

    // MARK: - Content sanity (one test is enough — structure is the same as before)

    /// The notification body should still report the percent and critical
    /// line — the dedup is purely behavioral, not a content change.
    func testThresholdNotificationContentUnchanged() {
        let instance = makeQuotaInstance(uuid: "u1", displayName: "MiniMax", criticalPercent: 95)
        manager.evaluateThresholds(
            instances: [instance],
            slotData: [makeQuotaSlot(uuid: "u1", displayName: "MiniMax", snapshots: [makeSnapshot(key: "k", percent: 97.5)])],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1)
        let content = stub.addedRequests[0].content
        XCTAssertTrue(content.title.contains("MiniMax"))
        XCTAssertTrue(content.title.contains("Critical"))
        XCTAssertTrue(content.body.contains("97.5%"))
        XCTAssertTrue(content.body.contains("95%"))
    }
}