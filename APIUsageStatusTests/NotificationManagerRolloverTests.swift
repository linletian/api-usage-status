import XCTest
import UserNotifications
@testable import APIUsageStatus

/// Orchestration tests for `NotificationManager.evaluateRollover(...)`.
///
/// The detection logic itself is covered exhaustively in
/// `LimitRolloverDetectorTests`. These tests focus on the **side-effect
/// boundaries** that the detector can't see:
///   - The two gates (`notificationsEnabled`, `isPermissionGranted`).
///   - Notification content (title, body, userInfo).
///   - The dedupe state — calling `evaluateRollover` twice with the
///     same data must schedule only one notification, but a strictly
///     later `cycleEndTime` must release the dedupe.
///
/// Tests inject a `StubNotificationScheduler` (via the
/// `NotificationScheduling` protocol seam) to observe scheduling
/// without going through the real `UNUserNotificationCenter`.
@MainActor
final class NotificationManagerRolloverTests: XCTestCase {

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

    private func settings(notificationsEnabled: Bool = true) -> GlobalSettings {
        var s = GlobalSettings.default
        s.notificationsEnabled = notificationsEnabled
        return s
    }

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
        displayName: String = "Test",
        shortName: String = "T",
        enabled: Bool = true
    ) -> Instance {
        Instance(
            uuid: uuid,
            provider: "test",
            dimension: "test",
            displayName: displayName,
            shortName: shortName,
            apiKeyRef: "key",
            enabled: enabled,
            sortOrder: 0,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )
    }

    /// Build a (oldSlot, newSlot) pair representing a single rollover
    /// for one metric (default: 5h window).
    private func singleRolloverFixtures(
        uuid: String = "u1",
        displayName: String = "MiniMax",
        shortName: String = "MX",
        enabled: Bool = true
    ) -> (old: SlotViewData, new: SlotViewData, instance: Instance) {
        let newEnd = Date(timeIntervalSince1970: 5_000_000)
        let oldEnd = Date(timeIntervalSince1970: 4_820_000)
        let oldSnap = makeSnapshot(key: "k", window: "5h", percent: 12, remainingSeconds: 300, endTime: oldEnd)
        let newSnap = makeSnapshot(key: "k", window: "5h", percent: 12, remainingSeconds: 18_000, endTime: newEnd)
        return (
            old: makeSlot(uuid: uuid, displayName: displayName, shortName: shortName, snapshots: [oldSnap]),
            new: makeSlot(uuid: uuid, displayName: displayName, shortName: shortName, snapshots: [newSnap]),
            instance: makeInstance(uuid: uuid, displayName: displayName, shortName: shortName, enabled: enabled)
        )
    }

    // MARK: - Gates

    /// `notificationsEnabled == false` must suppress the entire evaluateRollover
    /// path, even when the underlying detector would have detected a rollover.
    func testNotificationsDisabledSkipsScheduling() {
        let f = singleRolloverFixtures()
        manager.evaluateRollover(
            oldSlots: [f.old],
            newSlots: [f.new],
            instances: [f.instance],
            settings: settings(notificationsEnabled: false)
        )
        XCTAssertEqual(stub.addedRequests.count, 0, "Disabled notifications must not schedule")
    }

    /// `isPermissionGranted == false` must also suppress scheduling, since
    /// `UNUserNotificationCenter.add` would silently fail anyway.
    func testPermissionNotGrantedSkipsScheduling() {
        manager._setPermissionGrantedForTesting(false)
        let f = singleRolloverFixtures()
        manager.evaluateRollover(
            oldSlots: [f.old],
            newSlots: [f.new],
            instances: [f.instance],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 0, "Permission not granted must skip scheduling")
    }

    /// Disabled (`enabled == false`) instance: even if its cycle clearly
    /// rolled, the user paused it — no notification.
    func testDisabledInstanceDoesNotFire() {
        let f = singleRolloverFixtures(enabled: false)
        manager.evaluateRollover(
            oldSlots: [f.old],
            newSlots: [f.new],
            instances: [f.instance],
            settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 0, "Disabled instance must not fire")
    }

    // MARK: - Content

    /// Basic happy path: one rollover → one scheduled notification, title
    /// contains the instance display name, body lists the rolled metric.
    func testSingleRolloverFiresOneNotificationWithCorrectContent() {
        let f = singleRolloverFixtures(displayName: "MiniMax")
        manager.evaluateRollover(
            oldSlots: [f.old],
            newSlots: [f.new],
            instances: [f.instance],
            settings: settings()
        )

        XCTAssertEqual(stub.addedRequests.count, 1)
        let content = stub.addedRequests[0].content
        XCTAssertTrue(content.title.contains("MiniMax"), "Title must include display name; got: \(content.title)")
        XCTAssertTrue(content.title.contains("Limit Refreshed"), "Title must signal limit refresh; got: \(content.title)")
        XCTAssertTrue(content.body.contains("5h"), "Body must name the rolled window; got: \(content.body)")
        XCTAssertTrue(content.body.contains("12% used"), "Body must include the new percent with 'used'; got: \(content.body)")
    }

    /// userInfo is the routing payload for the click handler. Both the
    /// `instance_uuid` and a `kind` tag must be present so the future
    /// click handler can distinguish rollover notifications from
    /// threshold alerts.
    func testUserInfoContainsInstanceUUIDAndKind() {
        let f = singleRolloverFixtures(uuid: "abc-123")
        manager.evaluateRollover(
            oldSlots: [f.old],
            newSlots: [f.new],
            instances: [f.instance],
            settings: settings()
        )

        XCTAssertEqual(stub.addedRequests.count, 1)
        let userInfo = stub.addedRequests[0].content.userInfo
        XCTAssertEqual(userInfo["instance_uuid"] as? String, "abc-123")
        XCTAssertEqual(userInfo["kind"] as? String, "limit_refresh")
    }

    /// Multi-metric rollover: 5h + weekly both rolled in the same refresh.
    /// One notification, body lists both metrics separated by " / ".
    func testMultiMetricRolloverMergesIntoOneNotification() {
        let old5h = makeSnapshot(key: "k1", window: "5h", percent: 18, remainingSeconds: 200)
        let oldWeek = makeSnapshot(key: "k2", window: "weekly", percent: 32, remainingSeconds: 200_000)
        let new5h = makeSnapshot(key: "k1", window: "5h", percent: 18, remainingSeconds: 18_000)
        let newWeek = makeSnapshot(key: "k2", window: "weekly", percent: 32, remainingSeconds: 600_000)
        let oldSlot = makeSlot(uuid: "u1", displayName: "MiniMax", snapshots: [old5h, oldWeek])
        let newSlot = makeSlot(uuid: "u1", displayName: "MiniMax", snapshots: [new5h, newWeek])
        let instance = makeInstance(uuid: "u1", displayName: "MiniMax")

        manager.evaluateRollover(
            oldSlots: [oldSlot],
            newSlots: [newSlot],
            instances: [instance],
            settings: settings()
        )

        XCTAssertEqual(stub.addedRequests.count, 1, "Multi-metric rollover must collapse to one notification")
        let body = stub.addedRequests[0].content.body
        XCTAssertTrue(body.contains("5h"))
        XCTAssertTrue(body.contains("weekly"))
        XCTAssertTrue(body.contains("18%"))
        XCTAssertTrue(body.contains("32%"))
        XCTAssertTrue(body.contains(" / "), "Multiple rolled metrics must be separated; got: \(body)")
    }

    // MARK: - Dedupe state

    /// Calling evaluateRollover twice with the SAME data: the second call
    /// must not schedule anything because the dedupe table (updated in the
    /// first call's `defer` block) now records the new cycle's end time.
    func testDedupSameCyclePreventsSecondSchedule() {
        let f = singleRolloverFixtures()

        manager.evaluateRollover(
            oldSlots: [f.old], newSlots: [f.new], instances: [f.instance], settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1, "First call schedules")

        // Second call with identical data — dedupe should kick in because
        // lastFiredCycleEndTime["u1:k"] now equals f.new's cycleEndTime.
        manager.evaluateRollover(
            oldSlots: [f.old], newSlots: [f.new], instances: [f.instance], settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1, "Second call (same cycle) must be deduplicated")
    }

    /// Two distinct cycles: first call schedules; second call with a
    /// strictly later `cycleEndTime` (i.e. the next rollover) must
    /// release the dedupe and schedule again.
    func testDedupReleasesAfterNewCycle() {
        let f1 = singleRolloverFixtures()

        manager.evaluateRollover(
            oldSlots: [f1.old], newSlots: [f1.new], instances: [f1.instance], settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 1)

        // Build a "next cycle" rollover: new cycleEndTime far in the future,
        // and old remaining very small (window just rolled again).
        let nextNewEnd = Date(timeIntervalSince1970: 9_000_000)
        let oldSnap = makeSnapshot(key: "k", window: "5h", percent: 5, remainingSeconds: 300, endTime: f1.new.metricSnapshots[0].cycleEndTime)
        let newSnap = makeSnapshot(key: "k", window: "5h", percent: 5, remainingSeconds: 18_000, endTime: nextNewEnd)
        let oldSlot = makeSlot(uuid: "u1", displayName: "MiniMax", snapshots: [oldSnap])
        let newSlot = makeSlot(uuid: "u1", displayName: "MiniMax", snapshots: [newSnap])
        let instance = makeInstance(uuid: "u1", displayName: "MiniMax")

        manager.evaluateRollover(
            oldSlots: [oldSlot], newSlots: [newSlot], instances: [instance], settings: settings()
        )
        XCTAssertEqual(stub.addedRequests.count, 2, "New cycle (later end time) must release dedupe")
    }
}