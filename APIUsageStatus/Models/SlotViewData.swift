import Foundation

// MARK: - ColorState

enum ColorState: Equatable {
    case normal       // 安全区
    case warning      // 超过警告阈值
    case critical     // 超过严重阈值
    case disabled     // 实例已禁用 → 置灰色 #D6D0A0
    case unavailable  // 余额 is_available = false → 置灰色 #D6D0A0
    case loading      // 首次刷新尚未完成 → 置灰色 #D6D0A0
    case error        // 刷新失败 → 置灰色 #D6D0A0
}

// MARK: - InstanceType

enum InstanceType: Equatable {
    case quota(
        percent: Double,
        usageValue: String,
        limitValue: String,
        nextRefreshMinutes: Int,
        cycleRemainingDays: Int?
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

// MARK: - SlotViewData

struct SlotViewData: Identifiable, Equatable {
    let uuid: String
    let displayName: String
    let shortName: String
    let instanceType: InstanceType
    let sortOrder: Int
    let colorState: ColorState

    var id: String { uuid }

    // Balance-specific fields for usage panel
    var todayUsage: String?
    var dailyAverages: [AvgDailyPeriod: Decimal]?

    init(
        uuid: String,
        displayName: String,
        shortName: String,
        instanceType: InstanceType,
        sortOrder: Int,
        colorState: ColorState,
        todayUsage: String? = nil,
        dailyAverages: [AvgDailyPeriod: Decimal]? = nil
    ) {
        self.uuid = uuid
        self.displayName = displayName
        self.shortName = shortName
        self.instanceType = instanceType
        self.sortOrder = sortOrder
        self.colorState = colorState
        self.todayUsage = todayUsage
        self.dailyAverages = dailyAverages
    }
}