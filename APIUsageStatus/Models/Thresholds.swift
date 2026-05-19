import Foundation

enum AvgDailyPeriod: String, Codable, CaseIterable {
    case currentWeek = "current_week"
    case currentMonth = "current_month"
    case last7Days = "last_7_days"
    case last30Days = "last_30_days"
}

enum Thresholds: Codable, Equatable {
    case quota(warningPercent: Int, criticalPercent: Int)
    case balance(
        warning: Decimal,
        critical: Decimal,
        avgDailyPeriods: [AvgDailyPeriod],
        historyRetentionDays: Int
    )

    enum CodingKeys: String, CodingKey {
        case usageWarningPercent = "usage_warning_percent"
        case usageCriticalPercent = "usage_critical_percent"
        case balanceWarning = "balance_warning"
        case balanceCritical = "balance_critical"
        case avgDailyPeriods = "avg_daily_periods"
        case historyRetentionDays = "history_retention_days"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.usageWarningPercent) {
            let warningPercent = try container.decode(Int.self, forKey: .usageWarningPercent)
            let criticalPercent = try container.decode(Int.self, forKey: .usageCriticalPercent)
            self = .quota(warningPercent: warningPercent, criticalPercent: criticalPercent)
        } else {
            let warning = try container.decode(Decimal.self, forKey: .balanceWarning)
            let critical = try container.decode(Decimal.self, forKey: .balanceCritical)
            let avgDailyPeriods = try container.decodeIfPresent([AvgDailyPeriod].self, forKey: .avgDailyPeriods) ?? []
            let historyRetentionDays = try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? 0
            self = .balance(
                warning: warning,
                critical: critical,
                avgDailyPeriods: avgDailyPeriods,
                historyRetentionDays: historyRetentionDays
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .quota(let warningPercent, let criticalPercent):
            try container.encode(warningPercent, forKey: .usageWarningPercent)
            try container.encode(criticalPercent, forKey: .usageCriticalPercent)
        case .balance(let warning, let critical, let avgDailyPeriods, let historyRetentionDays):
            try container.encode(warning, forKey: .balanceWarning)
            try container.encode(critical, forKey: .balanceCritical)
            try container.encode(avgDailyPeriods, forKey: .avgDailyPeriods)
            try container.encode(historyRetentionDays, forKey: .historyRetentionDays)
        }
    }

    static var defaultQuota: Thresholds {
        .quota(warningPercent: 80, criticalPercent: 95)
    }

    static var defaultBalance: Thresholds {
        .balance(
            warning: Decimal(string: "10.00")!,
            critical: Decimal(string: "2.00")!,
            avgDailyPeriods: [],
            historyRetentionDays: 0
        )
    }
}