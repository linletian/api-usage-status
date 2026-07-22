import Foundation
import UserNotifications

// MARK: - NotificationScheduling

/// Minimal seam around `UNUserNotificationCenter.add(_:withCompletionHandler:)`
/// so `NotificationManager` can be unit-tested with a stub scheduler. The
/// default implementation is the system `UNUserNotificationCenter.current()`.
protocol NotificationScheduling: AnyObject {
    func add(
        _ request: UNNotificationRequest,
        withCompletionHandler completionHandler: ((Error?) -> Void)?
    )
}

extension UNUserNotificationCenter: NotificationScheduling {}

// MARK: - NotificationManager

/// Evaluates instance thresholds and triggers macOS system notifications
/// when critical thresholds are exceeded.
///
/// Must run on @MainActor because `UNUserNotificationCenter` delegate
/// methods are required to be on the main thread.
@MainActor
final class NotificationManager: NSObject {
    private let openDetailPanel: (String) -> Void
    private let scheduler: NotificationScheduling
    private let logger = AppLogger(category: "notification")

    /// Tracks whether the user has granted notification authorization.
    /// Defaults to `false` and is updated after `requestPermission()` or
    /// `fetchCurrentPermissionStatus()` completes. The setter is private:
    /// production code flips it through `requestPermission` /
    /// `fetchCurrentPermissionStatus` only. Tests flip it via
    /// `_setPermissionGrantedForTesting` (DEBUG-only), which keeps the
    /// public surface honest about who is allowed to mutate auth state.
    private(set) var isPermissionGranted: Bool = false

    #if DEBUG
    /// Test-only escape hatch for `isPermissionGranted`. Production
    /// code MUST go through `requestPermission` / `fetchCurrentPermissionStatus`
    /// — flipping the flag here bypasses the system prompt entirely and
    /// is silently no-op'd out of release builds.
    func _setPermissionGrantedForTesting(_ value: Bool) {
        isPermissionGranted = value
    }
    #endif

    /// Dedupes limit-cycle rollover notifications across consecutive
    /// refreshes: once we fire for `(instanceUUID, metricKey)` at a given
    /// `cycleEndTime`, we don't fire again until the supplier reports a
    /// strictly later `cycleEndTime`. v1 keeps this in memory only —
    /// losing it across app restarts is harmless because the first
    /// refresh after launch has no previous slot data to compare
    /// against, so it never fires anyway.
    private var lastFiredCycleEndTime: [String: Date] = [:]

    /// - Parameter openDetailPanel: Closure invoked when the user clicks a notification.
    /// - Parameter scheduler: Sink for `UNNotificationRequest`s. Defaults to the
    ///   system `UNUserNotificationCenter`; tests inject a stub to observe
    ///   scheduled requests without going through the real notification center.
    init(
        openDetailPanel: @escaping (String) -> Void,
        scheduler: NotificationScheduling = UNUserNotificationCenter.current()
    ) {
        self.openDetailPanel = openDetailPanel
        self.scheduler = scheduler
        super.init()
    }

    // MARK: - Permission

    /// Queries the current notification authorization status and updates
    /// `isPermissionGranted` without prompting the user.
    ///
    /// Uses the async `notificationSettings()` API (macOS 13+) so callers can
    /// `await` the result and avoid race windows against the first refresh.
    func fetchCurrentPermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let granted = settings.authorizationStatus == .authorized
        isPermissionGranted = granted
        logger.info("Current notification permission status: \(granted)")
    }

    /// Requests notification authorization from the user and updates
    /// `isPermissionGranted` with the result.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                if let error = error {
                    self?.logger.error("Notification permission error: \(error.localizedDescription)")
                    self?.isPermissionGranted = false
                } else {
                    self?.isPermissionGranted = granted
                    self?.logger.info("Notification permission granted: \(granted)")
                }
            }
        }
    }

    // MARK: - Threshold Evaluation

    /// Evaluates all instances against their configured thresholds and
    /// schedules notifications for those in critical state.
    func evaluateThresholds(
        instances: [Instance],
        slotData: [SlotViewData],
        settings: GlobalSettings
    ) {
        guard settings.notificationsEnabled else {
            logger.debug("Notifications disabled, skipping threshold evaluation")
            return
        }

        guard isPermissionGranted else {
            logger.debug("Notification permission not granted, skipping threshold evaluation")
            return
        }

        for slot in slotData {
            guard let instance = instances.first(where: { $0.uuid == slot.uuid }) else { continue }
            guard instance.enabled else { continue }

            // For multi-metric quota instances, evaluate each metric snapshot
            // independently so a critical weekly window triggers a notification
            // even when the 5h window is below threshold.
            if instance.isQuotaType, !slot.metricSnapshots.isEmpty {
                for snapshot in slot.metricSnapshots {
                    evaluateQuota(instance: instance, percent: snapshot.percent)
                }
            } else {
                switch slot.instanceType {
                case .quota(let percent, _, _, _):
                    evaluateQuota(instance: instance, percent: percent)
                case .balance(let amount, _, _, let isAvailable, _):
                    evaluateBalance(instance: instance, amount: amount, isAvailable: isAvailable)
                }
            }
        }
    }

    private func evaluateQuota(instance: Instance, percent: Double) {
        guard case .quota(_, let criticalPercent) = instance.thresholds else { return }
        guard percent >= Double(criticalPercent) else { return }

        let displayName = instance.displayName.isEmpty ? instance.shortName : instance.displayName
        let content = makeNotificationContent(
            title: "⚠️ \(displayName) Usage Critical",
            body: "Current \(String(format: "%.1f", percent))%, critical line \(criticalPercent)%",
            uuid: instance.uuid
        )
        scheduleNotification(content: content)
    }

    private func evaluateBalance(instance: Instance, amount: String, isAvailable: Bool) {
        guard isAvailable else { return }
        guard case .balance(_, let critical, _, _) = instance.thresholds else { return }
        guard let balanceDecimal = Decimal(string: amount), balanceDecimal <= critical else { return }

        let displayName = instance.displayName.isEmpty ? instance.shortName : instance.displayName
        let symbol = instance.currency?.currencySymbol ?? "¥"
        let content = makeNotificationContent(
            title: "⚠️ \(displayName) Balance Low",
            body: "Current \(symbol)\(amount), critical line \(symbol)\(critical)",
            uuid: instance.uuid
        )
        scheduleNotification(content: content)
    }

    // MARK: - Rollover Evaluation

    /// Compares the previous refresh's slot data with the just-completed
    /// refresh and fires one macOS notification per instance that had at
    /// least one metric window roll over to a new cycle. Multiple rolled
    /// metrics on the same instance are merged into a single notification
    /// (per design choice — fewer notification-center entries).
    ///
    /// Detection is delegated to `LimitRolloverDetector`, a pure function
    /// over `(oldSlots, newSlots, instances, lastFired)`. This method
    /// owns the side effects: dedupe state update + notification scheduling.
    ///
    /// Gated on `settings.notificationsEnabled` and `isPermissionGranted`
    /// to mirror `evaluateThresholds`.
    func evaluateRollover(
        oldSlots: [SlotViewData],
        newSlots: [SlotViewData],
        instances: [Instance],
        settings: GlobalSettings
    ) {
        guard settings.notificationsEnabled else {
            logger.debug("Notifications disabled, skipping rollover evaluation")
            return
        }
        guard isPermissionGranted else {
            logger.debug("Notification permission not granted, skipping rollover evaluation")
            return
        }

        let detected = LimitRolloverDetector.detect(
            oldSlots: oldSlots,
            newSlots: newSlots,
            instances: instances,
            lastFired: lastFiredCycleEndTime,
            // Derive the detection threshold from the user's configured
            // refresh interval (in seconds) so a future lower bound on
            // refreshIntervalMinutes can't shrink the safe buffer below
            // the noise floor of a single refresh tick.
            refreshIntervalSeconds: settings.refreshIntervalMinutes * 60
        )

        // Update dedupe state for every metric we fire on, regardless of
        // whether `scheduleNotification` later fails to post (e.g. system
        // throttling). Using `defer` keeps the bookkeeping next to the
        // detection result — a fire-and-dedup pair that must stay in sync
        // even if `scheduleNotification` itself throws synchronously.
        //
        // **Tradeoff — accepted**: if `UNUserNotificationCenter.add` fails
        // for transient reasons (system throttling, momentary auth
        // glitch), the dedupe update still happens. That means the
        // notification is *permanently lost* for the current cycle — the
        // next refresh will see `newEnd <= lastFired` and skip. We chose
        // this over the alternative (retry next refresh) because: (a)
        // UNNotificationCenter.add almost never fails in practice; (b)
        // retrying a throttled notification is itself the kind of pattern
        // that triggers *more* throttling. If lost notifications become a
        // user-visible problem, the next iteration can move the dedupe
        // update into the success callback and add a one-retry budget.
        defer {
            for (_, info) in detected {
                for metric in info.rolledMetrics {
                    let key = "\(info.instanceUUID):\(metric.metricKey)"
                    if let end = metric.cycleEndTime {
                        lastFiredCycleEndTime[key] = end
                    }
                }
            }
        }

        for (_, info) in detected {
            let displayName = info.instanceDisplayName.isEmpty
                ? info.instanceShortName
                : info.instanceDisplayName
            let bodyParts = info.rolledMetrics.map { metric -> String in
                let label = metric.window ?? metric.metricKey
                let pct = String(format: "%.0f", metric.newPercent)
                return "\(label): \(pct)% used"
            }
            let content = makeNotificationContent(
                title: "🔄 \(displayName) Limit Refreshed",
                body: bodyParts.joined(separator: " / "),
                uuid: info.instanceUUID
            )
            // Tag the kind so the click handler can route rollover
            // notifications differently from threshold alerts in the future.
            // Today `openDetailPanel(uuid)` is fine for both — opens the
            // panel focused on the instance.
            content.userInfo = [
                "instance_uuid": info.instanceUUID,
                "kind": "limit_refresh"
            ]
            scheduleNotification(content: content)
        }
    }

    // MARK: - Notification Scheduling

    private func makeNotificationContent(
        title: String,
        body: String,
        uuid: String
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["instance_uuid": uuid]
        return content
    }

    private func scheduleNotification(content: UNMutableNotificationContent) {
        guard isPermissionGranted else {
            logger.debug("Skipping notification scheduling: permission not granted")
            return
        }

        let uuid = content.userInfo["instance_uuid"] as? String ?? "unknown"
        let identifier = "\(uuid)-\(Date().timeIntervalSince1970)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        scheduler.add(request) { [weak self] error in
            Task { @MainActor [weak self] in
                if let error = error {
                    self?.logger.error("Failed to schedule notification: \(error.localizedDescription)")
                } else {
                    self?.logger.info("Scheduled notification: \(content.title)")
                }
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {

    /// Allows notifications to be presented while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handles the user clicking a notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let uuid = userInfo["instance_uuid"] as? String {
            openDetailPanel(uuid)
        }
        completionHandler()
    }
}
