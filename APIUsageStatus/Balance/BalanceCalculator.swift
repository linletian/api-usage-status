import Foundation

// MARK: - BalanceCalculator

enum BalanceCalculator {
    /// Calculates the average daily usage for a given period from history entries.
    static func average(for period: AvgDailyPeriod, from history: [DailyUsageEntry]) -> Decimal {
        let today = Date()
        let calendar = Calendar.current

        var startDate: Date
        var divisor: Int

        switch period {
        case .currentWeek:
            startDate = today.startOfWeek
            divisor = max(1, today.daysSince(startDate) + 1)
        case .currentMonth:
            let components = calendar.dateComponents([.year, .month], from: today)
            startDate = calendar.date(from: components) ?? today
            divisor = max(1, today.daysSince(startDate) + 1)
        case .last7Days:
            startDate = calendar.date(byAdding: .day, value: -6, to: today.startOfDay)!
            divisor = 7
        case .last30Days:
            startDate = calendar.date(byAdding: .day, value: -29, to: today.startOfDay)!
            divisor = 30
        }

        let filteredHistory = history.filter { entry in
            guard let entryDate = parseDate(entry.date) else { return false }
            return entryDate >= startDate && entryDate <= today
        }

        var total = Decimal(0)
        for entry in filteredHistory {
            if let value = Decimal(string: entry.usage) {
                total = total.plus(value)
            }
        }

        return total.divided(by: Decimal(divisor))
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    /// Updates a balance snapshot based on a new API response.
    /// Implements the algorithm from PRD §3.7.
    static func update(snapshot: BalanceSnapshot?, currentToppedUp: String) -> BalanceSnapshot {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())
        let timestamp = Int64(Date().timeIntervalSince1970)

        // Case 1: No existing snapshot — create baseline
        guard var snapshot = snapshot else {
            return BalanceSnapshot.createBaseline(toppedUp: currentToppedUp)
        }

        // Case 2: Day changed — archive previous day, reset
        if snapshot.todayDate != today {
            var newSnapshot = snapshot
            // Archive yesterday's usage
            let entry = DailyUsageEntry(date: snapshot.todayDate, usage: snapshot.todayUsage)
            newSnapshot.history.insert(entry, at: 0)
            newSnapshot.todayDate = today
            newSnapshot.todayUsage = "0"
            newSnapshot.latestToppedUp = currentToppedUp
            newSnapshot.latestToppedUpTs = timestamp
            return newSnapshot
        }

        // Case 3: Same day — calculate consumption
        let prev = Decimal(string: snapshot.latestToppedUp) ?? Decimal(0)
        let curr = Decimal(string: currentToppedUp) ?? Decimal(0)

        if curr > prev {
            // Recharge: update baseline, no consumption counted
            snapshot.latestToppedUp = currentToppedUp
            snapshot.latestToppedUpTs = timestamp
            snapshot.lastTopupDate = today
        } else if curr < prev {
            // Normal consumption
            let diff = prev.minus(curr)
            let prevUsage = Decimal(string: snapshot.todayUsage) ?? Decimal(0)
            snapshot.todayUsage = String(describing: prevUsage.plus(diff))
            snapshot.latestToppedUp = currentToppedUp
            snapshot.latestToppedUpTs = timestamp
        }
        // If equal: no change

        return snapshot
    }

    /// Prunes history to retain only the specified number of most recent days.
    static func pruneHistory(_ history: [DailyUsageEntry], retainDays: Int) -> [DailyUsageEntry] {
        guard retainDays > 0, history.count > retainDays else { return history }
        return Array(history.prefix(retainDays))
    }
}