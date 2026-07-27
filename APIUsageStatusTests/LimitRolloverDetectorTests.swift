import XCTest
@testable import APIUsageStatus

/// Unit tests for `LimitRolloverDetector` — the pure detection function
/// that powers limit-cycle rollover notifications.
///
/// The detector is intentionally pure (no `Date()`, no `UNUserNotificationCenter`)
/// so these tests are deterministic — every case constructs fixed input arrays
/// and asserts on the output dict.
final class LimitRolloverDetectorTests: XCTestCase {

    /// Standard refresh interval used by tests that aren't exercising the
    /// dynamic-threshold logic. Matches the production default (5 min)
    /// in `GlobalSettings.refreshIntervalMinutes`.
    private let standardRefreshIntervalSeconds = 300

    // MARK: - Fixtures

    private func makeSnapshot(
        key: String,
        window: String?,
        percent: Double = 0,
        remainingSeconds: Int? = nil,
        endTime: Date? = nil
    ) -> MetricSnapshot {
        MetricSnapshot(
            key: key,
            group: nil,
            window: window,
            percent: percent,
            displayUsage: "\(Int(percent))%",
            displayLimit: "",
            cycleRemainingSeconds: remainingSeconds,
            colorState: .normal,
            cycleEndTime: endTime
        )
    }

    private func makeSlot(
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

    private func makeInstance(
        uuid: String,
        enabled: Bool = true
    ) -> Instance {
        Instance(
            uuid: uuid,
            provider: "test",
            dimension: "test",
            displayName: "Test",
            shortName: "T",
            apiKeyRef: "key",
            enabled: enabled,
            sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )
    }

    /// Thin wrapper over `LimitRolloverDetector.detect` that defaults the
    /// refresh interval to the production-standard 5 min so existing tests
    /// don't have to thread the parameter through every call site. Tests
    /// exercising the dynamic-threshold logic pass an explicit override.
    private func runDetect(
        oldSlots: [SlotViewData],
        newSlots: [SlotViewData],
        instances: [Instance],
        lastFired: [String: Date],
        refreshIntervalSeconds: Int? = nil
    ) -> [String: LimitRolloverDetector.DetectedRollover] {
        LimitRolloverDetector.detect(
            oldSlots: oldSlots,
            newSlots: newSlots,
            instances: instances,
            lastFired: lastFired,
            refreshIntervalSeconds: refreshIntervalSeconds ?? standardRefreshIntervalSeconds
        )
    }

    // MARK: - Detection signal cases

    /// Mid-cycle refresh: `remaining` decreases by roughly the refresh
    /// interval (here 5 min). Must NOT be classified as a rollover.
    func testNormalMonotonicDecreaseDoesNotTrigger() {
        let snap = makeSnapshot(key: "k", window: "5h", remainingSeconds: 16_700, endTime: .distantFuture)
        let prevSnap = makeSnapshot(key: "k", window: "5h", remainingSeconds: 17_000, endTime: .distantFuture)
        let slot = makeSlot(uuid: "u", snapshots: [snap])
        let prev = makeSlot(uuid: "u", snapshots: [prevSnap])
        let instance = makeInstance(uuid: "u")

        let result = runDetect(
            oldSlots: [prev], newSlots: [slot], instances: [instance], lastFired: [:]
        )
        XCTAssertTrue(result.isEmpty, "Monotonic decrease must not trigger; got: \(result)")
    }

    /// 5h rolling window just rolled: `remaining` went from ~5 min to ~5 h.
    func testFiveHourRollingWindowRolloverTriggers() {
        let snap = makeSnapshot(key: "k", window: "5h", percent: 12, remainingSeconds: 18_000, endTime: Date(timeIntervalSince1970: 2_000_000))
        let prevSnap = makeSnapshot(key: "k", window: "5h", percent: 12, remainingSeconds: 300, endTime: Date(timeIntervalSince1970: 1_820_000))
        let slot = makeSlot(uuid: "u", displayName: "MiniMax", shortName: "MX", snapshots: [snap])
        let prev = makeSlot(uuid: "u", displayName: "MiniMax", shortName: "MX", snapshots: [prevSnap])
        let instance = makeInstance(uuid: "u")

        let result = runDetect(
            oldSlots: [prev], newSlots: [slot], instances: [instance], lastFired: [:]
        )

        XCTAssertEqual(result.count, 1)
        let detected = result["u"]
        XCTAssertNotNil(detected)
        XCTAssertEqual(detected?.instanceUUID, "u")
        XCTAssertEqual(detected?.instanceDisplayName, "MiniMax")
        XCTAssertEqual(detected?.rolledMetrics.count, 1)
        XCTAssertEqual(detected?.rolledMetrics.first?.metricKey, "k")
        XCTAssertEqual(detected?.rolledMetrics.first?.window, "5h")
        XCTAssertEqual(detected?.rolledMetrics.first?.newPercent, 12)
    }

    /// Old snapshot had no `remaining` (first refresh for that metric).
    /// Skip rather than guess — the user shouldn't get a notification on
    /// the very first refresh.
    func testOldRemainingNilDoesNotTrigger() {
        let snap = makeSnapshot(key: "k", window: "5h", remainingSeconds: 18_000)
        let prevSnap = makeSnapshot(key: "k", window: "5h", remainingSeconds: nil)
        let slot = makeSlot(uuid: "u", snapshots: [snap])
        let prev = makeSlot(uuid: "u", snapshots: [prevSnap])
        let instance = makeInstance(uuid: "u")

        let result = runDetect(
            oldSlots: [prev], newSlots: [slot], instances: [instance], lastFired: [:]
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// New snapshot has no `remaining` (supplier stopped reporting it).
    /// Indeterminate — skip.
    func testNewRemainingNilDoesNotTrigger() {
        let snap = makeSnapshot(key: "k", window: "5h", remainingSeconds: nil)
        let prevSnap = makeSnapshot(key: "k", window: "5h", remainingSeconds: 18_000)
        let slot = makeSlot(uuid: "u", snapshots: [snap])
        let prev = makeSlot(uuid: "u", snapshots: [prevSnap])
        let instance = makeInstance(uuid: "u")

        let result = runDetect(
            oldSlots: [prev], newSlots: [slot], instances: [instance], lastFired: [:]
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// Jump below the threshold (here 30 s) — likely just refresh noise.
    func testSmallJumpBelowThresholdDoesNotTrigger() {
        let snap = makeSnapshot(key: "k", window: "5h", remainingSeconds: 10_030)
        let prevSnap = makeSnapshot(key: "k", window: "5h", remainingSeconds: 10_000)
        let slot = makeSlot(uuid: "u", snapshots: [snap])
        let prev = makeSlot(uuid: "u", snapshots: [prevSnap])
        let instance = makeInstance(uuid: "u")

        let result = runDetect(
            oldSlots: [prev], newSlots: [slot], instances: [instance], lastFired: [:]
        )
        XCTAssertTrue(result.isEmpty, "30s jump must not trigger; threshold is 60s")
    }

    // MARK: - Multi-metric aggregation

    /// 5h rolled, weekly didn't. Only the rolled metric shows up in the
    /// notification's rolledMetrics list.
    func testMultiMetricOnlyRolledMetricIsReported() {
        let fiveHourNew = makeSnapshot(key: "k1", window: "5h", percent: 18, remainingSeconds: 18_000)
        let weeklyNew = makeSnapshot(key: "k2", window: "weekly", percent: 32, remainingSeconds: 200_000)
        let fiveHourOld = makeSnapshot(key: "k1", window: "5h", percent: 18, remainingSeconds: 200)
        let weeklyOld = makeSnapshot(key: "k2", window: "weekly", percent: 32, remainingSeconds: 250_000)
        let slot = makeSlot(uuid: "u", snapshots: [fiveHourNew, weeklyNew])
        let prev = makeSlot(uuid: "u", snapshots: [fiveHourOld, weeklyOld])
        let instance = makeInstance(uuid: "u")

        let result = runDetect(
            oldSlots: [prev], newSlots: [slot], instances: [instance], lastFired: [:]
        )

        XCTAssertEqual(result.count, 1)
        let rolled = result["u"]?.rolledMetrics ?? []
        XCTAssertEqual(rolled.count, 1, "Only 5h rolled; weekly should be omitted")
        XCTAssertEqual(rolled.first?.window, "5h")
        XCTAssertEqual(rolled.first?.newPercent, 18)
    }

    /// Both 5h and weekly rolled in the same refresh. The notification
    /// payload should list both (merged into a single per-instance notification).
    func testMultiMetricBothRolledReportsBoth() {
        let fiveHourNew = makeSnapshot(key: "k1", window: "5h", percent: 18, remainingSeconds: 18_000)
        let weeklyNew = makeSnapshot(key: "k2", window: "weekly", percent: 32, remainingSeconds: 600_000)
        let fiveHourOld = makeSnapshot(key: "k1", window: "5h", percent: 18, remainingSeconds: 200)
        let weeklyOld = makeSnapshot(key: "k2", window: "weekly", percent: 32, remainingSeconds: 200_000)
        let slot = makeSlot(uuid: "u", snapshots: [fiveHourNew, weeklyNew])
        let prev = makeSlot(uuid: "u", snapshots: [fiveHourOld, weeklyOld])
        let instance = makeInstance(uuid: "u")

        let result = runDetect(
            oldSlots: [prev], newSlots: [slot], instances: [instance], lastFired: [:]
        )

        let rolled = result["u"]?.rolledMetrics ?? []
        XCTAssertEqual(rolled.count, 2)
        let windows = Set(rolled.compactMap(\.window))
        XCTAssertEqual(windows, ["5h", "weekly"])
    }

    /// Two separate instances both rolled in the same refresh — the result
    /// dict should have one entry per instance.
    func testMultipleInstancesEachReportedIndependently() {
        let snap1 = makeSnapshot(key: "k", window: "5h", remainingSeconds: 18_000)
        let snap2 = makeSnapshot(key: "k", window: "5h", remainingSeconds: 18_000)
        let prev1 = makeSnapshot(key: "k", window: "5h", remainingSeconds: 300)
        let prev2 = makeSnapshot(key: "k", window: "5h", remainingSeconds: 300)
        let s1 = makeSlot(uuid: "u1", displayName: "Inst1", shortName: "I1", snapshots: [snap1])
        let s2 = makeSlot(uuid: "u2", displayName: "Inst2", shortName: "I2", snapshots: [snap2])
        let p1 = makeSlot(uuid: "u1", displayName: "Inst1", shortName: "I1", snapshots: [prev1])
        let p2 = makeSlot(uuid: "u2", displayName: "Inst2", shortName: "I2", snapshots: [prev2])
        let i1 = makeInstance(uuid: "u1")
        let i2 = makeInstance(uuid: "u2")

        let result = runDetect(
            oldSlots: [p1, p2], newSlots: [s1, s2], instances: [i1, i2], lastFired: [:]
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result["u1"]?.instanceDisplayName, "Inst1")
        XCTAssertEqual(result["u2"]?.instanceDisplayName, "Inst2")
    }

    // MARK: - Dedup table

    /// Same cycle reported again (`newEnd <= lastFired`): dedup table
    /// wins, no detection. Simulates the "two refreshes within the same
    /// 5h window, both see the post-rollover state" case — the rollover
    /// signal itself DOES fire (remaining jumped forward), but the dedup
    /// table says we already notified for this end time, so we skip.
    func testDedupSameCycleSkipped() {
        let cycleEnd = Date(timeIntervalSince1970: 5_000_000)
        let prevSnap = makeSnapshot(key: "k", window: "5h", remainingSeconds: 300)
        let snap = makeSnapshot(key: "k", window: "5h", percent: 5, remainingSeconds: 18_000, endTime: cycleEnd)
        let prev = makeSlot(uuid: "u", snapshots: [prevSnap])
        let slot = makeSlot(uuid: "u", snapshots: [snap])
        let instance = makeInstance(uuid: "u")
        let lastFired: [String: Date] = ["u:k": cycleEnd]  // equal to newEnd → dedup wins

        let result = runDetect(
            oldSlots: [prev], newSlots: [slot], instances: [instance], lastFired: lastFired
        )
        XCTAssertTrue(result.isEmpty, "Same-cycle re-detection must be suppressed by dedup table")
    }

    /// `newEnd > lastFired`: new cycle is in flight, detection fires.
    func testDedupNewCycleAdvancesTriggers() {
        let newEnd = Date(timeIntervalSince1970: 5_000_000)
        let snap = makeSnapshot(key: "k", window: "5h", remainingSeconds: 18_000, endTime: newEnd)
        let prevSnap = makeSnapshot(key: "k", window: "5h", remainingSeconds: 300)
        let slot = makeSlot(uuid: "u", snapshots: [snap])
        let prev = makeSlot(uuid: "u", snapshots: [prevSnap])
        let instance = makeInstance(uuid: "u")
        let lastFired: [String: Date] = ["u:k": Date(timeIntervalSince1970: 4_000_000)]

        let result = runDetect(
            oldSlots: [prev], newSlots: [slot], instances: [instance], lastFired: lastFired
        )
        XCTAssertEqual(result.count, 1, "New cycle advance must trigger after dedup")
    }

    // MARK: - Edge cases

    /// `instance.enabled == false`: paused instance — must NOT fire even
    /// if its cycle clearly rolled over.
    func testDisabledInstanceDoesNotTrigger() {
        let snap = makeSnapshot(key: "k", window: "5h", remainingSeconds: 18_000)
        let prevSnap = makeSnapshot(key: "k", window: "5h", remainingSeconds: 300)
        let slot = makeSlot(uuid: "u", snapshots: [snap])
        let prev = makeSlot(uuid: "u", snapshots: [prevSnap])
        let instance = makeInstance(uuid: "u", enabled: false)

        let result = runDetect(
            oldSlots: [prev], newSlots: [slot], instances: [instance], lastFired: [:]
        )
        XCTAssertTrue(result.isEmpty, "Disabled instance must not trigger notifications")
    }

    /// `window == nil` (e.g. DeepSeek balance) has no cycle to roll over.
    /// The detector's outer loop filters these out via
    /// `where newSnap.window != nil`, so even with a big remaining-jump
    /// on a balance metric, no detection.
    func testWindowNilSnapshotDoesNotTrigger() {
        // Simulate a balance-style snapshot where window is nil. A
        // artificial remainingSeconds jump must NOT produce detection.
        let snap = makeSnapshot(key: "balance", window: nil, remainingSeconds: 100)
        let prevSnap = makeSnapshot(key: "balance", window: nil, remainingSeconds: 10_000)
        let slot = makeSlot(uuid: "u", snapshots: [snap])
        let prev = makeSlot(uuid: "u", snapshots: [prevSnap])
        let instance = makeInstance(uuid: "u")

        let result = runDetect(
            oldSlots: [prev], newSlots: [slot], instances: [instance], lastFired: [:]
        )
        XCTAssertTrue(result.isEmpty, "window==nil snapshots must never trigger")
    }

    // MARK: - Dynamic threshold

    /// The threshold must scale with `refreshIntervalSeconds` so that a
    /// user-configured 30 s refresh interval doesn't shrink the noise
    /// floor to the point where routine refresh jitter triggers a false
    /// rollover. With interval = 30 s, threshold = max(60, 60) = 60 s —
    /// a 50 s jump stays below the floor, a 70 s jump fires.
    func testThresholdScalesWithRefreshInterval() {
        let snap = makeSnapshot(key: "k", window: "5h", remainingSeconds: 18_050)  // +50
        let prevSnap = makeSnapshot(key: "k", window: "5h", remainingSeconds: 18_000)
        let slot = makeSlot(uuid: "u", snapshots: [snap])
        let prev = makeSlot(uuid: "u", snapshots: [prevSnap])
        let instance = makeInstance(uuid: "u")

        // 50 s jump with 30 s refresh interval → threshold 60 s → must NOT trigger.
        let below = runDetect(
            oldSlots: [prev], newSlots: [slot], instances: [instance],
            lastFired: [:], refreshIntervalSeconds: 30
        )
        XCTAssertTrue(below.isEmpty, "50 s jump with 30 s interval (threshold 60 s) must not trigger")

        // 70 s jump with 30 s refresh interval → 70 > 60 → must trigger.
        let snapAbove = makeSnapshot(key: "k", window: "5h", remainingSeconds: 18_070)
        let slotAbove = makeSlot(uuid: "u", snapshots: [snapAbove])
        let above = runDetect(
            oldSlots: [prev], newSlots: [slotAbove], instances: [instance],
            lastFired: [:], refreshIntervalSeconds: 30
        )
        XCTAssertEqual(above.count, 1, "70 s jump with 30 s interval (threshold 60 s) must trigger")
    }
}