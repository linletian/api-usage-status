import Foundation
import UserNotifications

// MARK: - NotificationManager

/// Evaluates instance thresholds and triggers macOS system notifications
/// when critical thresholds are exceeded.
///
/// Must run on @MainActor because `UNUserNotificationCenter` delegate
/// methods are required to be on the main thread.
@MainActor
final class NotificationManager: NSObject {
    private let openDetailPanel: (String) -> Void
    private let logger = AppLogger(category: "notification")

    /// Tracks whether the user has granted notification authorization.
    /// Defaults to `false` and is updated after `requestPermission()` or
    /// `fetchCurrentPermissionStatus()` completes.
    private(set) var isPermissionGranted: Bool = false

    /// - Parameter openDetailPanel: Closure invoked when the user clicks a notification.
    init(openDetailPanel: @escaping (String) -> Void) {
        self.openDetailPanel = openDetailPanel
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

        UNUserNotificationCenter.current().add(request) { [weak self] error in
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
