import Foundation

// MARK: - DailyUsageEntry

struct DailyUsageEntry: Codable, Equatable {
    let date: String     // "YYYY-MM-DD"
    let usage: String    // Decimal value as string for precision

    init(date: String, usage: String) {
        self.date = date
        self.usage = usage
    }
}

// MARK: - BalanceSnapshot

struct BalanceSnapshot: Codable, Equatable {
    var latestToppedUp: String
    var latestToppedUpTs: Int64
    var lastTopupDate: String?
    var todayDate: String
    var todayUsage: String
    var history: [DailyUsageEntry]

    enum CodingKeys: String, CodingKey {
        case latestToppedUp = "latest_topped_up"
        case latestToppedUpTs = "latest_topped_up_ts"
        case lastTopupDate = "last_topup_date"
        case todayDate = "today_date"
        case todayUsage = "today_usage"
        case history
    }

    init(
        latestToppedUp: String,
        latestToppedUpTs: Int64 = Int64(Date().timeIntervalSince1970),
        lastTopupDate: String? = nil,
        todayDate: String,
        todayUsage: String = "0",
        history: [DailyUsageEntry] = []
    ) {
        self.latestToppedUp = latestToppedUp
        self.latestToppedUpTs = latestToppedUpTs
        self.lastTopupDate = lastTopupDate
        self.todayDate = todayDate
        self.todayUsage = todayUsage
        self.history = history
    }

    static func createBaseline(toppedUp: String) -> BalanceSnapshot {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())
        return BalanceSnapshot(
            latestToppedUp: toppedUp,
            latestToppedUpTs: Int64(Date().timeIntervalSince1970),
            lastTopupDate: today,
            todayDate: today,
            todayUsage: "0",
            history: []
        )
    }
}

// MARK: - BalanceUpdate

struct BalanceUpdate {
    let snapshot: BalanceSnapshot
    let dailyAverages: [AvgDailyPeriod: Decimal]
}