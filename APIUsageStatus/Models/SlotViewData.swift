import Foundation

// MARK: - ColorState

enum ColorState: Equatable {
    case normal       // Safe zone
    case warning      // Above warning threshold
    case critical     // Above critical threshold
    case disabled     // Instance disabled → dimmed #D6D0A0
    case unavailable  // Balance is_available = false → dimmed #D6D0A0
    case loading      // First refresh not yet completed → dimmed #D6D0A0
    case error        // Refresh failed → dimmed #D6D0A0
}

// MARK: - InstanceType

enum InstanceType: Equatable {
    case quota(
        percent: Double,
        usageValue: String,
        limitValue: String,
        cycleRemainingSeconds: Int?
    )
    case balance(
        amount: String,            // topped_up_balance (primary display amount)
        totalBalance: String,      // total_balance (for display breakdown)
        grantedBalance: String,    // granted_balance (for display breakdown)
        isAvailable: Bool,
        currency: String? = nil
    )

    var isQuota: Bool {
        if case .quota = self { return true }
        return false
    }

    var isBalance: Bool {
        if case .balance = self { return true }
        return false
    }
}

// MARK: - WeeklyQuota

/// Weekly-cycle quota for a quota instance. `isUnlimited` is true when the
/// API reports the weekly window is not active for the user's plan.
struct WeeklyQuota: Equatable {
    /// Usage percent in the weekly window (0-100). 0 = unused, 100 = exhausted.
    let percent: Double
    /// Remaining percent in the weekly window (0-100). 100 = unused, 0 = exhausted.
    /// This is a percentage, not a raw quota count — the MiniMax API does not
    /// expose absolute weekly counts, only the remaining percent.
    let remaining: Double
    /// True when the user's plan does not enforce a weekly limit
    /// (`current_weekly_status != 1` in the MiniMax response).
    let isUnlimited: Bool

    /// Build a `WeeklyQuota` from a parsed supplier response. Returns nil
    /// (and the caller should suppress the weekly bar) when any of the three
    /// expected fields is missing — we never invent a default for a field
    /// the API did not provide.
    ///
    /// The MiniMax parser stores weekly data under "<model>:weekly_*" keys.
    /// `weekly_status == 1` means the weekly window is active. Any other
    /// value (e.g. 3) means the user's plan does not enforce a weekly limit.
    static func from(response: SupplierResponse, dimension: String) -> WeeklyQuota? {
        guard
            let statusString = response.value(forDimension: "\(dimension):weekly_status"),
            let status = Int(statusString),
            let percentString = response.value(forDimension: "\(dimension):weekly_percent"),
            let remainingString = response.value(forDimension: "\(dimension):weekly_remaining")
        else {
            return nil
        }
        return WeeklyQuota(
            percent: Self.parsePercent(percentString),
            remaining: Self.parsePercent(remainingString),
            isUnlimited: status != 1
        )
    }

    private static func parsePercent(_ value: String) -> Double {
        let cleaned = value.replacingOccurrences(of: "%", with: "").trimmed
        return Double(cleaned) ?? 0.0
    }
}

// MARK: - SlotViewData

struct SlotViewData: Identifiable, Equatable {
    let uuid: String
    let displayName: String
    let shortName: String
    let sortOrder: Int
    let provider: String

    var id: String { uuid }

    // Balance-specific fields for usage panel
    var todayUsage: String?
    var dailyAverages: [AvgDailyPeriod: Decimal]?

    // TODO: Remove after confirming weekly feature is stable on all user plans.
    // Temporary diagnostic: keys looked up in rawData for weekly.
    var weeklyDebug: String?

    // MARK: - Runtime metric snapshots

    /// Runtime snapshots derived from `MetricConfig` + supplier response on
    /// every refresh. The first snapshot drives `instanceType`, `dimension`,
    /// `colorState` and (post-Task 8) `weekly`.
    var metricSnapshots: [MetricSnapshot]

    // MARK: - Computed (from metricSnapshots)

    /// Preserved `InstanceType` from the balance path init. When non-nil,
    /// `instanceType` returns this instead of deriving from snapshots.
    private let balanceInstanceType: InstanceType?

    var instanceType: InstanceType {
        if let balance = balanceInstanceType { return balance }
        guard let first = metricSnapshots.first else {
            return .quota(percent: 0, usageValue: "", limitValue: "", cycleRemainingSeconds: nil)
        }
        return .quota(
            percent: first.percent,
            usageValue: first.displayUsage,
            limitValue: first.displayLimit,
            cycleRemainingSeconds: first.cycleRemainingSeconds
        )
    }

    /// Worst color state across all metric snapshots. Priority:
    /// critical > warning > error > unavailable > disabled > loading > normal.
    var colorState: ColorState {
        let states = metricSnapshots.map(\.colorState)
        guard !states.isEmpty else { return .loading }
        if states.contains(.critical) { return .critical }
        if states.contains(.warning) { return .warning }
        if states.contains(.error) { return .error }
        if states.contains(.unavailable) { return .unavailable }
        if states.contains(.disabled) { return .disabled }
        if states.contains(.loading) { return .loading }
        return .normal
    }

    /// The dimension string from the source `Instance` (e.g. "5h", "weekly",
    /// "monthly" for OpenCode; "premium_interactions" for Copilot). The UI
    /// layer reads this to pick the right per-window label.
    var dimension: String {
        metricSnapshots.first?.key ?? ""
    }

    var weekly: WeeklyQuota? {
        guard let s = metricSnapshots.first(where: { $0.window == "weekly" }) else {
            return nil
        }
        return WeeklyQuota(
            percent: s.percent,
            remaining: max(0, 100 - s.percent),
            isUnlimited: s.isUnlimited
        )
    }

    // MARK: - Init

    /// `instanceType`, `colorState`, `dimension` and `weekly` are kept as
    /// init parameters so existing call sites compile unchanged. When
    /// `metricSnapshots` is non-empty the passed-in values are ignored
    /// (the computed properties derive from `metricSnapshots`).
    /// When `metricSnapshots` is empty, a single synthetic snapshot is
    /// constructed from the legacy params.
    init(
        uuid: String,
        displayName: String,
        shortName: String,
        instanceType: InstanceType = .quota(percent: 0, usageValue: "", limitValue: "", cycleRemainingSeconds: nil),
        sortOrder: Int,
        colorState: ColorState = .loading,
        provider: String,
        dimension: String = "",
        metricSnapshots: [MetricSnapshot] = [],
        todayUsage: String? = nil,
        dailyAverages: [AvgDailyPeriod: Decimal]? = nil,
        weekly: WeeklyQuota? = nil,
        weeklyDebug: String? = nil
    ) {
        self.uuid = uuid
        self.displayName = displayName
        self.shortName = shortName
        self.sortOrder = sortOrder
        self.provider = provider
        self.todayUsage = todayUsage
        self.dailyAverages = dailyAverages
        self.weeklyDebug = weeklyDebug

        // Balance path: preserve the full InstanceType so the menu bar and
        // usage panel render balance content (amount/currency) instead of
        // deriving a fake .quota from the synthetic MetricSnapshot.
        if case .balance = instanceType {
            self.balanceInstanceType = instanceType
        } else {
            self.balanceInstanceType = nil
        }

        if !metricSnapshots.isEmpty {
            self.metricSnapshots = metricSnapshots
        } else {
            let snapshotPercent: Double
            let displayUsage: String
            let displayLimit: String
            let cycleRemaining: Int?
            let snapshotColor: ColorState

            switch instanceType {
            case .quota(let p, let u, let l, let c):
                snapshotPercent = p
                displayUsage = u
                displayLimit = l
                cycleRemaining = c
                snapshotColor = colorState
            case .balance(let amount, _, _, let isAvailable, _):
                snapshotPercent = 0
                displayUsage = amount
                displayLimit = ""
                cycleRemaining = nil
                snapshotColor = isAvailable ? colorState : .unavailable
            }

            self.metricSnapshots = [MetricSnapshot(
                key: dimension,
                group: nil,
                window: nil,
                percent: snapshotPercent,
                displayUsage: displayUsage,
                displayLimit: displayLimit,
                cycleRemainingSeconds: cycleRemaining,
                colorState: snapshotColor,
                configIndex: 0
            )]
        }
    }
}