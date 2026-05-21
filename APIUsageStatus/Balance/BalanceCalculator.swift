import Foundation

// MARK: - BalanceCalculator

/// Pure function module for balance tracking calculations.
/// Stateless, no Actor dependencies.
enum BalanceCalculator {

    // MARK: - Main Update

    /// Updates a balance snapshot based on a new API response.
    /// Implements the algorithm from PRD §3.7.
    ///
    /// - Parameters:
    ///   - snapshot: The existing snapshot (nil for first refresh)
    ///   - currentToppedUp: Current `topped_up_balance` from API (string for precision)
    ///   - retentionDays: History retention setting (0 = unlimited)
    /// - Returns: `BalanceUpdate` containing the new snapshot and daily averages
    static func update(
        snapshot: BalanceSnapshot?,
        currentToppedUp: String,
        retentionDays: Int = 0
    ) -> BalanceUpdate {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: now)
        let timestamp = Int64(now.timeIntervalSince1970)

        // Case 1: No existing snapshot — create baseline
        guard var snapshot = snapshot else {
            let baseline = BalanceSnapshot.createBaseline(toppedUp: currentToppedUp)
            let averages = calculateDailyAverages(
                snapshot: baseline,
                periods: AvgDailyPeriod.allCases
            )
            return BalanceUpdate(snapshot: baseline, dailyAverages: averages)
        }

        // Case 2: Day changed — archive previous day, reset
        if snapshot.todayDate != today {
            // Archive yesterday's usage
            let entry = DailyUsageEntry(date: snapshot.todayDate, usage: snapshot.todayUsage)
            snapshot.history.insert(entry, at: 0)

            // Trim history if needed
            if retentionDays > 0 {
                snapshot.history = trimHistory(snapshot.history, retainDays: retentionDays)
            }

            snapshot.todayDate = today
            snapshot.todayUsage = "0"
            // NOTE: Keep latestToppedUp / latestToppedUpTs unchanged on day change
            // so overnight consumption can be captured by the consumption logic below.
        }

        // Case 3: Calculate consumption (same day or after day-change reset)
        let prev = Decimal(string: snapshot.latestToppedUp) ?? Decimal(0)
        let curr = Decimal(string: currentToppedUp) ?? Decimal(0)

        if curr.isGreater(than: prev) {
            // Recharge: update baseline, no consumption counted
            snapshot.latestToppedUp = currentToppedUp
            snapshot.latestToppedUpTs = timestamp
            snapshot.lastTopupDate = today
        } else if curr.isLess(than: prev) {
            // Normal consumption
            let diff = prev.minus(curr)
            let prevUsage = Decimal(string: snapshot.todayUsage) ?? Decimal(0)
            let newUsage = prevUsage.plus(diff)
            snapshot.todayUsage = newUsage.formatted(decimalPlaces: 2)
            snapshot.latestToppedUp = currentToppedUp
            snapshot.latestToppedUpTs = timestamp
        }
        // If equal: no change

        // Trim history if retention is configured
        if retentionDays > 0 {
            snapshot.history = trimHistory(snapshot.history, retainDays: retentionDays)
        }

        let averages = calculateDailyAverages(
            snapshot: snapshot,
            periods: AvgDailyPeriod.allCases
        )
        return BalanceUpdate(snapshot: snapshot, dailyAverages: averages)
    }

    // MARK: - Daily Averages

    /// Calculates daily averages for the requested periods from a snapshot.
    static func calculateDailyAverages(
        snapshot: BalanceSnapshot,
        periods: [AvgDailyPeriod]
    ) -> [AvgDailyPeriod: Decimal] {
        var result: [AvgDailyPeriod: Decimal] = [:]

        for period in periods {
            let avg = average(for: period, snapshot: snapshot)
            result[period] = avg
        }

        return result
    }

    /// Calculates the average daily usage for a given period from a snapshot.
    /// Includes today's usage if today falls within the period.
    private static func average(for period: AvgDailyPeriod, snapshot: BalanceSnapshot) -> Decimal {
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

        // Sum historical entries within the period
        var total = Decimal(0)
        for entry in snapshot.history {
            guard let entryDate = parseDate(entry.date) else { continue }
            if entryDate >= startDate && entryDate <= today {
                if let value = Decimal(string: entry.usage) {
                    total = total.plus(value)
                }
            }
        }

        // Include today if today falls within the period
        if let todayDate = parseDate(snapshot.todayDate),
           todayDate >= startDate && todayDate <= today {
            if let todayUsage = Decimal(string: snapshot.todayUsage), !todayUsage.isZero {
                total = total.plus(todayUsage)
            }
        }

        return total.divided(by: Decimal(divisor))
    }

    // MARK: - History Trimming

    /// Trims history to retain only the specified number of most recent days.
    /// - Parameter retainDays: 0 means unlimited (no trimming)
    static func trimHistory(_ history: [DailyUsageEntry], retainDays: Int) -> [DailyUsageEntry] {
        guard retainDays > 0, history.count > retainDays else { return history }
        return Array(history.prefix(retainDays))
    }

    // MARK: - Helpers

    private static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}
